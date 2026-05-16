import Foundation
import MagicSwitchCore
import Network

struct PeerEndpoint: Equatable {
  let name: String
  let host: String
  let port: Int
}

final class PeerService: NSObject, PeerControlling {
  private let commandTimeoutSeconds: TimeInterval = 120
  private let queue = DispatchQueue(label: "com.fouad.magicswitch.peer")
  private let logger = Logger.shared
  private var listener: NWListener?
  private var netService: NetService?
  private var browser: NetServiceBrowser?
  private var resolvingServices: [NetService] = []
  private var peersByName: [String: PeerEndpoint] = [:]
  private let localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  private var commandHandler: ((SwitchCommand) async -> OperationReport)?

  var peerDescription: String {
    let snapshot = peerSnapshot()
    if let peer = selectedPeer(from: snapshot.peers, targetPeerName: snapshot.targetPeerName) {
      let prefix = snapshot.targetPeerName == nil ? "Auto" : "Target"
      return "\(prefix): \(peer.name) (\(peer.host):\(peer.port))"
    }

    if snapshot.peers.count > 1 {
      return "Choose a target Mac"
    }

    return "No peer discovered"
  }

  var selectedTargetPeerName: String? {
    AppConfig.loadConfiguration().targetPeerName
  }

  func start(commandHandler: @escaping (SwitchCommand) async -> OperationReport) {
    self.commandHandler = commandHandler
    startListener()
    startBrowser()
  }

  func availablePeers() -> [PeerEndpoint] {
    peerSnapshot().peers
  }

  func setTargetPeerName(_ targetPeerName: String?) throws {
    try AppConfig.saveTargetPeerName(targetPeerName)
  }

  func send(_ command: SwitchCommand) async -> OperationReport {
    let snapshot = peerSnapshot()
    guard let peer = selectedPeer(from: snapshot.peers, targetPeerName: snapshot.targetPeerName) else {
      if snapshot.peers.count > 1 {
        return OperationReport(ok: false, message: "Multiple peers discovered. Choose a target Mac.")
      }
      return OperationReport(ok: false, message: "No peer discovered")
    }

    return await send(command, to: peer)
  }

  private func peerSnapshot() -> (peers: [PeerEndpoint], targetPeerName: String?) {
    let peers = queue.sync {
      peersByName.values.sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    }

    return (peers, AppConfig.loadConfiguration().targetPeerName)
  }

  private func selectedPeer(from peers: [PeerEndpoint], targetPeerName: String?) -> PeerEndpoint? {
    if let targetPeerName {
      return peers.first { $0.name == targetPeerName }
    }

    return peers.count == 1 ? peers[0] : nil
  }

  private func startListener() {
    do {
      listener = try NWListener(using: .tcp)
    } catch {
      logger.log("Failed to create listener: \(error)")
      return
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleIncoming(connection)
    }

    listener?.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        if let port = self.listener?.port?.rawValue {
          self.publish(port: Int(port))
          self.logger.log("Peer listener ready on port \(port)")
        }
      case .failed(let error):
        self.logger.log("Peer listener failed: \(error)")
      default:
        break
      }
    }

    listener?.start(queue: queue)
  }

  private func publish(port: Int) {
    netService = NetService(
      domain: AppConfig.serviceDomain,
      type: AppConfig.serviceType,
      name: localName,
      port: Int32(port)
    )
    netService?.delegate = self
    netService?.publish()
  }

  private func startBrowser() {
    let browser = NetServiceBrowser()
    browser.delegate = self
    browser.searchForServices(ofType: AppConfig.serviceType, inDomain: AppConfig.serviceDomain)
    self.browser = browser
  }

  private func handleIncoming(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
      guard let self else {
        connection.cancel()
        return
      }

      if let error {
        self.logger.log("Incoming receive failed: \(error)")
        connection.cancel()
        return
      }

      guard let data, let envelope = try? CommandCodec.decodeEnvelope(data) else {
        self.sendReport(OperationReport(ok: false, message: "Invalid command"), on: connection)
        return
      }

      self.logger.log("Incoming command: \(envelope.command.rawValue)")
      Task {
        let report = await self.commandHandler?(envelope.command)
          ?? OperationReport(ok: false, message: "No command handler")
        self.sendReport(report, on: connection)
      }
    }
  }

  private func sendReport(_ report: OperationReport, on connection: NWConnection) {
    let data = (try? CommandCodec.encode(report)) ?? Data()
    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func send(_ command: SwitchCommand, to peer: PeerEndpoint) async -> OperationReport {
    await withCheckedContinuation { continuation in
      let connection = NWConnection(
        host: NWEndpoint.Host(peer.host),
        port: NWEndpoint.Port(integerLiteral: UInt16(peer.port)),
        using: .tcp
      )

      var finished = false
      let finish: (OperationReport) -> Void = { report in
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation.resume(returning: report)
      }

      connection.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          do {
            let data = try CommandCodec.encode(CommandEnvelope(command: command))
            connection.send(content: data, completion: .contentProcessed { error in
              if let error {
                finish(OperationReport(ok: false, message: "Send failed: \(error)"))
                return
              }
              connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error {
                  finish(OperationReport(ok: false, message: "Receive failed: \(error)"))
                  return
                }
                guard let data, let report = try? CommandCodec.decodeReport(data) else {
                  finish(OperationReport(ok: false, message: "Invalid peer response"))
                  return
                }
                finish(report)
              }
            })
          } catch {
            finish(OperationReport(ok: false, message: "Encode failed: \(error)"))
          }
        case .failed(let error):
          finish(OperationReport(ok: false, message: "Connection failed: \(error)"))
        default:
          self?.logger.log("Peer connection state: \(state)")
        }
      }

      queue.asyncAfter(deadline: .now() + commandTimeoutSeconds) {
        finish(OperationReport(ok: false, message: "Peer command timed out"))
      }

      connection.start(queue: queue)
    }
  }
}

extension PeerService: NetServiceBrowserDelegate {
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard service.name != localName else { return }
    resolvingServices.append(service)
    service.delegate = self
    service.resolve(withTimeout: 5)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    queue.async {
      self.peersByName[service.name] = nil
      self.logger.log("Peer removed: \(service.name)")
    }
  }
}

extension PeerService: NetServiceDelegate {
  func netServiceDidPublish(_ sender: NetService) {
    logger.log("Published Bonjour service as \(sender.name)")
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    logger.log("Bonjour publish failed: \(errorDict)")
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard sender.name != localName else { return }
    let host = sender.hostName ?? sender.name
    let endpoint = PeerEndpoint(name: sender.name, host: host, port: sender.port)
    queue.async {
      self.peersByName[endpoint.name] = endpoint
      self.logger.log("Peer resolved: \(endpoint.name) \(endpoint.host):\(endpoint.port)")
    }
  }
}

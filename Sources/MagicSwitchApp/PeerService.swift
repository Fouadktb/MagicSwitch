import Foundation
import MagicSwitchCore
import Network
import Darwin

struct PeerEndpoint: Equatable {
  let name: String
  let host: String
  let hosts: [String]
  let port: Int
}

final class PeerService: NSObject, PeerControlling {
  private let commandTimeoutSeconds: TimeInterval = 150
  private let socketTimeoutSeconds: TimeInterval = 8
  private let preferredPort: UInt16 = 58423
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
      listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: preferredPort)!)
    } catch {
      logger.log("Failed to create listener on preferred port \(preferredPort): \(error)")
      do {
        listener = try NWListener(using: .tcp)
      } catch {
        logger.log("Failed to create listener: \(error)")
        return
      }
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
    let hosts = peer.hosts.isEmpty ? [peer.host] : peer.hosts
    let ports = uniquePorts([peer.port, Int(preferredPort)])
    var failures: [String] = []

    for host in hosts {
      for port in ports {
        let report = await send(command, host: host, port: port)
        if report.ok || !isConnectionFailure(report) {
          return report
        }
        failures.append("\(host):\(port): \(report.message)")
      }
    }

    return OperationReport(
      ok: false,
      message: "Cannot reach \(peer.name). Check MagicSwitch in System Settings > Privacy & Security > Local Network. Details: \(failures.joined(separator: "; "))"
    )
  }

  private func send(_ command: SwitchCommand, host: String, port: Int) async -> OperationReport {
    let networkReport = await sendWithNetwork(command, host: host, port: port)
    guard isConnectionFailure(networkReport) else {
      return networkReport
    }

    logger.log("NWConnection failed on \(host):\(port): \(networkReport.message); trying socket fallback")
    return sendWithSocket(command, host: host, port: port)
  }

  private func sendWithNetwork(_ command: SwitchCommand, host: String, port: Int) async -> OperationReport {
    await withCheckedContinuation { continuation in
      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(integerLiteral: UInt16(port)),
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
        case .waiting(let error):
          self?.logger.log("Peer connection waiting on \(host):\(port): \(error)")
          finish(OperationReport(ok: false, message: "Connection waiting: \(error)"))
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

  private func sendWithSocket(_ command: SwitchCommand, host: String, port: Int) -> OperationReport {
    let payload: Data
    do {
      payload = try CommandCodec.encode(CommandEnvelope(command: command))
    } catch {
      return OperationReport(ok: false, message: "Encode failed: \(error)")
    }

    var hints = addrinfo(
      ai_flags: AI_NUMERICSERV,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )

    var results: UnsafeMutablePointer<addrinfo>?
    let lookupStatus = getaddrinfo(host, String(port), &hints, &results)
    guard lookupStatus == 0, let results else {
      return OperationReport(ok: false, message: "Socket lookup failed: \(String(cString: gai_strerror(lookupStatus)))")
    }
    defer { freeaddrinfo(results) }

    var cursor: UnsafeMutablePointer<addrinfo>? = results
    var failures: [String] = []

    while let address = cursor {
      let report = sendWithSocket(payload, address: address)
      if report.ok || !isConnectionFailure(report) {
        return report
      }
      failures.append(report.message)
      cursor = address.pointee.ai_next
    }

    return OperationReport(ok: false, message: failures.joined(separator: "; "))
  }

  private func sendWithSocket(_ payload: Data, address: UnsafeMutablePointer<addrinfo>) -> OperationReport {
    let descriptor = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
    guard descriptor >= 0 else {
      return OperationReport(ok: false, message: "Socket create failed: \(posixMessage(errno))")
    }
    defer { close(descriptor) }

    guard configureSocket(descriptor) else {
      return OperationReport(ok: false, message: "Socket configure failed: \(posixMessage(errno))")
    }

    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      return OperationReport(ok: false, message: "Socket nonblocking failed: \(posixMessage(errno))")
    }

    let connectResult = Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen)
    if connectResult != 0 && errno != EINPROGRESS {
      return OperationReport(ok: false, message: "Socket connect failed: \(posixMessage(errno))")
    }

    if connectResult != 0 {
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let pollResult = poll(&pollDescriptor, 1, Int32(socketTimeoutSeconds * 1000))
      guard pollResult > 0 else {
        return OperationReport(ok: false, message: pollResult == 0 ? "Socket connect timed out" : "Socket connect poll failed: \(posixMessage(errno))")
      }

      var socketError: Int32 = 0
      var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
        return OperationReport(ok: false, message: "Socket connect check failed: \(posixMessage(errno))")
      }
      guard socketError == 0 else {
        return OperationReport(ok: false, message: "Socket connect failed: \(posixMessage(socketError))")
      }
    }

    _ = fcntl(descriptor, F_SETFL, flags)

    guard writePayload(payload, to: descriptor) else {
      return OperationReport(ok: false, message: "Socket send failed: \(posixMessage(errno))")
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while response.count < 65_536 {
      let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if received > 0 {
        response.append(buffer, count: received)
        if response.contains(0x0A) {
          break
        }
      } else if received == 0 {
        break
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        break
      } else {
        return OperationReport(ok: false, message: "Socket receive failed: \(posixMessage(errno))")
      }
    }

    guard !response.isEmpty, let report = try? CommandCodec.decodeReport(response) else {
      return OperationReport(ok: false, message: "Invalid socket response")
    }
    return report
  }

  private func configureSocket(_ descriptor: Int32) -> Bool {
    var timeout = timeval(tv_sec: Int(socketTimeoutSeconds), tv_usec: 0)
    let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0 else {
      return false
    }
    return setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
  }

  private func writePayload(_ payload: Data, to descriptor: Int32) -> Bool {
    payload.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        return false
      }

      var bytesSent = 0
      while bytesSent < payload.count {
        let sent = Darwin.send(descriptor, baseAddress.advanced(by: bytesSent), payload.count - bytesSent, 0)
        if sent <= 0 {
          return false
        }
        bytesSent += sent
      }
      return true
    }
  }

  private func posixMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
  }

  private func isConnectionFailure(_ report: OperationReport) -> Bool {
    report.message.hasPrefix("Connection failed:")
      || report.message.hasPrefix("Connection waiting:")
      || report.message == "Peer command timed out"
      || report.message.hasPrefix("Send failed:")
      || report.message.hasPrefix("Receive failed:")
      || report.message == "Invalid peer response"
      || report.message.hasPrefix("Socket lookup failed:")
      || report.message.hasPrefix("Socket create failed:")
      || report.message.hasPrefix("Socket configure failed:")
      || report.message.hasPrefix("Socket nonblocking failed:")
      || report.message.hasPrefix("Socket connect failed:")
      || report.message == "Socket connect timed out"
      || report.message.hasPrefix("Socket connect poll failed:")
      || report.message.hasPrefix("Socket connect check failed:")
      || report.message.hasPrefix("Socket send failed:")
      || report.message.hasPrefix("Socket receive failed:")
      || report.message == "Invalid socket response"
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
    let fallbackHost = sender.hostName ?? sender.name
    let hosts = uniqueHosts(numericIPv4Hosts(from: sender.addresses) + [fallbackHost])
    let endpoint = PeerEndpoint(name: sender.name, host: hosts.first ?? fallbackHost, hosts: hosts, port: sender.port)
    queue.async {
      self.peersByName[endpoint.name] = endpoint
      self.logger.log("Peer resolved: \(endpoint.name) \(endpoint.hosts.joined(separator: ",")):\(endpoint.port)")
    }
  }

  private func numericIPv4Hosts(from addresses: [Data]?) -> [String] {
    guard let addresses else { return [] }

    return addresses.compactMap { data in
      var storage = sockaddr_storage()
      guard data.count <= MemoryLayout<sockaddr_storage>.size else {
        return nil
      }

      _ = withUnsafeMutableBytes(of: &storage) { buffer in
        data.copyBytes(to: buffer)
      }

      guard Int32(storage.ss_family) == AF_INET else {
        return nil
      }

      return withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketAddress in
          var address = socketAddress.pointee.sin_addr
          var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
          guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
          }
          return String(cString: buffer)
        }
      }
    }
  }

  private func uniqueHosts(_ hosts: [String]) -> [String] {
    var seen = Set<String>()
    return hosts.filter { host in
      seen.insert(host).inserted
    }
  }

  private func uniquePorts(_ ports: [Int]) -> [Int] {
    var seen = Set<Int>()
    return ports.filter { port in
      seen.insert(port).inserted
    }
  }
}

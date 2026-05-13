import Foundation

public enum SwitchCommand: String, Codable, Sendable {
  case health = "HEALTH"
  case releaseAll = "RELEASE_ALL"
  case takeAll = "TAKE_ALL"
  case status = "STATUS"
}

public struct OperationReport: Codable, Equatable, Sendable {
  public let ok: Bool
  public let message: String
  public let snapshots: [DeviceSnapshot]

  public init(ok: Bool, message: String, snapshots: [DeviceSnapshot] = []) {
    self.ok = ok
    self.message = message
    self.snapshots = snapshots
  }
}

public enum SwitchOutcome: Equatable, Sendable {
  case switched(OperationReport)
  case failed(String)

  public var ok: Bool {
    if case .switched = self { return true }
    return false
  }
}

public protocol LocalBluetoothManaging {
  func releaseAll() async -> OperationReport
  func takeAll() async -> OperationReport
  func status() async -> OperationReport
}

public protocol PeerControlling {
  func send(_ command: SwitchCommand) async -> OperationReport
}

public struct SwitchCoordinator {
  private let bluetooth: LocalBluetoothManaging
  private let peer: PeerControlling?

  public init(bluetooth: LocalBluetoothManaging, peer: PeerControlling?) {
    self.bluetooth = bluetooth
    self.peer = peer
  }

  public func switchToThisMac() async -> SwitchOutcome {
    if let peer {
      let releaseReport = await peer.send(.releaseAll)
      guard releaseReport.ok else {
        return .failed("Peer release failed: \(releaseReport.message)")
      }
    }

    let takeReport = await bluetooth.takeAll()
    guard takeReport.ok else {
      return .failed(takeReport.message)
    }

    return .switched(takeReport)
  }

  public func switchToPeer() async -> SwitchOutcome {
    guard let peer else {
      return .failed("No peer discovered")
    }

    let releaseReport = await bluetooth.releaseAll()
    guard releaseReport.ok else {
      return .failed("Local release failed: \(releaseReport.message)")
    }

    let peerTakeReport = await peer.send(.takeAll)
    guard peerTakeReport.ok else {
      return .failed("Peer take failed: \(peerTakeReport.message)")
    }

    return .switched(peerTakeReport)
  }
}

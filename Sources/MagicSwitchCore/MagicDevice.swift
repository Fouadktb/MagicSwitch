import Foundation

public struct MagicDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: String { address }
  public let name: String
  public let address: String

  public init(name: String, address: String) {
    self.name = name
    self.address = address
  }
}

public enum MagicDeviceStatus: String, Codable, Sendable {
  case unavailable
  case unpaired
  case pairedDisconnected
  case pairedConnected
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
  public let device: MagicDevice
  public let status: MagicDeviceStatus
  public let detail: String

  public init(device: MagicDevice, status: MagicDeviceStatus, detail: String = "") {
    self.device = device
    self.status = status
    self.detail = detail
  }
}

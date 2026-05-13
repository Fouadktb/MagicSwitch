import Foundation

public enum AppConfig {
  public static let appName = "MagicSwitch"
  public static let serviceType = "_magicswitch._tcp."
  public static let serviceDomain = "local."

  public static var configURL: URL {
    if let override = ProcessInfo.processInfo.environment["MAGICSWITCH_CONFIG"],
       !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/MagicSwitch", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  public static func loadConfiguration() -> ConfigurationLoadResult {
    let url = configURL
    let directory = url.deletingLastPathComponent()

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      if !FileManager.default.fileExists(atPath: url.path) {
        try sampleConfiguration.write(to: url, atomically: true, encoding: .utf8)
        return ConfigurationLoadResult(
          devices: [],
          url: url,
          message: "Created config at \(url.path)"
        )
      }

      let data = try Data(contentsOf: url)
      let configuration = try JSONDecoder().decode(MagicSwitchConfiguration.self, from: data)
      let devices = configuration.devices.compactMap(normalizedDevice)

      return ConfigurationLoadResult(
        devices: devices,
        url: url,
        message: devices.isEmpty ? "No valid devices in \(url.path)" : "Loaded \(devices.count) device(s)"
      )
    } catch {
      return ConfigurationLoadResult(
        devices: [],
        url: url,
        message: "Failed to load config: \(error.localizedDescription)"
      )
    }
  }

  public static func saveConfiguration(devices: [MagicDevice]) throws {
    let url = configURL
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var seenAddresses = Set<String>()
    let normalizedDevices = devices.compactMap(normalizedDevice).filter { device in
      seenAddresses.insert(device.address).inserted
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let data = try encoder.encode(MagicSwitchConfiguration(devices: normalizedDevices))
    try data.write(to: url, options: .atomic)
  }

  public static func canonicalBluetoothAddress(_ rawAddress: String) -> String? {
    let address = rawAddress
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
      .replacingOccurrences(of: "-", with: ":")

    guard isBluetoothAddress(address) else {
      return nil
    }

    return address
  }

  private static func normalizedDevice(_ device: MagicDevice) -> MagicDevice? {
    guard let address = canonicalBluetoothAddress(device.address) else {
      return nil
    }

    let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return MagicDevice(name: name.isEmpty ? address : name, address: address)
  }

  private static func isBluetoothAddress(_ address: String) -> Bool {
    let parts = address.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else {
      return false
    }

    return parts.allSatisfy { part in
      part.count == 2 && UInt8(part, radix: 16) != nil
    }
  }

  private static let sampleConfiguration = """
  {
    "devices": [
      {
        "name": "Magic Keyboard",
        "address": "replace-with-keyboard-address"
      },
      {
        "name": "Magic Trackpad",
        "address": "replace-with-trackpad-address"
      }
    ]
  }
  """
}

public struct MagicSwitchConfiguration: Codable, Equatable, Sendable {
  public var devices: [MagicDevice]

  public init(devices: [MagicDevice]) {
    self.devices = devices
  }
}

public struct ConfigurationLoadResult: Equatable, Sendable {
  public let devices: [MagicDevice]
  public let url: URL
  public let message: String

  public init(devices: [MagicDevice], url: URL, message: String) {
    self.devices = devices
    self.url = url
    self.message = message
  }
}

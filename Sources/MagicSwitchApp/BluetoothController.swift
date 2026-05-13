import Foundation
import IOBluetooth
import MagicSwitchCore

final class BluetoothController: @unchecked Sendable, LocalBluetoothManaging {
  private var configuration: ConfigurationLoadResult
  private let queue = DispatchQueue(label: "com.fouad.magicswitch.bluetooth", qos: .userInitiated)
  private let logger = Logger.shared

  var configURL: URL {
    AppConfig.configURL
  }

  var hasConfiguredDevices: Bool {
    queue.sync {
      !configuration.devices.isEmpty
    }
  }

  init(configuration: ConfigurationLoadResult = AppConfig.loadConfiguration()) {
    self.configuration = configuration
    logger.log(configuration.message)
  }

  func reloadConfiguration() {
    queue.sync {
      let configuration = AppConfig.loadConfiguration()
      self.configuration = configuration
      self.logger.log(configuration.message)
    }
  }

  func saveConfiguredDevices(_ devices: [MagicDevice]) throws {
    try AppConfig.saveConfiguration(devices: devices)
    reloadConfiguration()
  }

  func status() async -> OperationReport {
    await run {
      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let snapshots = devices.map { self.snapshot(for: $0) }
      return OperationReport(ok: true, message: self.summarize(snapshots), snapshots: snapshots)
    }
  }

  func releaseAll() async -> OperationReport {
    await run {
      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      self.logger.log("Release requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.release(device)
        self.waitForReleased(device, seconds: 6)
        snapshots.append(self.snapshot(for: device))
      }

      let ok = snapshots.allSatisfy { $0.status != .pairedConnected }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Released local devices" : "Some devices are still connected",
        snapshots: snapshots
      )
      self.logger.log(report.message)
      return report
    }
  }

  func takeAll() async -> OperationReport {
    await run {
      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      self.logger.log("Take requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.take(device)
        snapshots.append(self.snapshot(for: device))
      }

      let ok = snapshots.allSatisfy { $0.status == .pairedConnected }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Devices connected to this Mac" : "Not all devices connected",
        snapshots: snapshots
      )
      self.logger.log(report.message)
      return report
    }
  }

  private func run(_ body: @escaping () -> OperationReport) async -> OperationReport {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: body())
      }
    }
  }

  private func snapshot(for magicDevice: MagicDevice) -> DeviceSnapshot {
    guard let device = IOBluetoothDevice(addressString: magicDevice.address) else {
      return DeviceSnapshot(device: magicDevice, status: .unavailable, detail: "No IOBluetoothDevice")
    }

    let status: MagicDeviceStatus
    if device.isConnected() {
      status = .pairedConnected
    } else if device.isPaired() {
      status = .pairedDisconnected
    } else {
      status = .unpaired
    }

    return DeviceSnapshot(
      device: magicDevice,
      status: status,
      detail: "rssi=\(device.rssi())"
    )
  }

  private func release(_ magicDevice: MagicDevice) {
    guard let device = IOBluetoothDevice(addressString: magicDevice.address) else {
      logger.log("\(magicDevice.name): unavailable during release")
      return
    }

    if device.isConnected() {
      let closeResult = device.closeConnection()
      logger.log("\(magicDevice.name): closeConnection -> \(closeResult)")
      Thread.sleep(forTimeInterval: 0.6)
    }

    let removeSelector = Selector(("remove"))
    if device.responds(to: removeSelector) {
      _ = device.perform(removeSelector)
      logger.log("\(magicDevice.name): remove pairing requested")
    } else {
      logger.log("\(magicDevice.name): remove selector unavailable")
    }
  }

  private func take(_ magicDevice: MagicDevice) {
    guard let device = IOBluetoothDevice(addressString: magicDevice.address) else {
      logger.log("\(magicDevice.name): unavailable during take")
      return
    }

    pair(device, named: magicDevice.name)

    for attempt in 1...4 {
      if device.isConnected() {
        logger.log("\(magicDevice.name): connected before attempt \(attempt)")
        return
      }

      let result = device.openConnection(
        nil,
        withPageTimeout: BluetoothHCIPageTimeout(0x0800),
        authenticationRequired: false
      )
      logger.log("\(magicDevice.name): openConnection attempt \(attempt) -> \(result)")

      if device.isConnected() {
        return
      }

      Thread.sleep(forTimeInterval: 1.5)
    }
  }

  private func pair(_ device: IOBluetoothDevice, named name: String) {
    guard let pair = IOBluetoothDevicePair(device: device) else {
      logger.log("\(name): failed to create pair object")
      return
    }

    let result = pair.start()
    logger.log("\(name): pair start -> \(result)")

    for _ in 0..<20 {
      if device.isPaired() || device.isConnected() {
        logger.log("\(name): pair observed as complete")
        Thread.sleep(forTimeInterval: 0.6)
        return
      }
      Thread.sleep(forTimeInterval: 0.5)
    }

    logger.log("\(name): pair wait timed out")
  }

  private func waitForReleased(_ magicDevice: MagicDevice, seconds: Int) {
    for _ in 0..<(seconds * 2) {
      let snapshot = snapshot(for: magicDevice)
      if snapshot.status != .pairedConnected {
        return
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
  }

  private func summarize(_ snapshots: [DeviceSnapshot]) -> String {
    snapshots
      .map { "\($0.device.name): \($0.status.rawValue)" }
      .joined(separator: ", ")
  }
}

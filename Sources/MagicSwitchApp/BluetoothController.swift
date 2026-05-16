import Foundation
import IOBluetooth
import MagicSwitchCore

final class BluetoothController: @unchecked Sendable, LocalBluetoothManaging {
  private var configuration: ConfigurationLoadResult
  private let queue = DispatchQueue(label: "com.fouad.magicswitch.bluetooth", qos: .userInitiated)
  private let logger = Logger.shared
  private let operationLock = NSLock()
  private var activeOperation: String?

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

  func saveTargetPeerName(_ targetPeerName: String?) throws {
    try AppConfig.saveTargetPeerName(targetPeerName)
    reloadConfiguration()
  }

  func status() async -> OperationReport {
    return await run {
      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let snapshots = devices.map { self.snapshot(for: $0) }
      return OperationReport(ok: true, message: self.summarize(snapshots), snapshots: snapshots)
    }
  }

  func releaseAll() async -> OperationReport {
    guard beginOperation("Release") else {
      return busyReport()
    }

    return await run {
      defer { self.endOperation("Release") }

      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
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
      self.logger.log("\(report.message) in \(self.formatDuration(since: startedAt))")
      return report
    }
  }

  func takeAll() async -> OperationReport {
    guard beginOperation("Take") else {
      return busyReport()
    }

    return await run {
      defer { self.endOperation("Take") }

      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
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
      self.logger.log("\(report.message) in \(self.formatDuration(since: startedAt))")
      return report
    }
  }

  func repairAll() async -> OperationReport {
    guard beginOperation("Repair") else {
      return busyReport()
    }

    return await run {
      defer { self.endOperation("Repair") }

      let devices = self.configuration.devices
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
      self.logger.log("Repair requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.take(device, forceRepair: true)
        snapshots.append(self.snapshot(for: device))
      }

      let ok = snapshots.allSatisfy { $0.status == .pairedConnected }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Devices repaired on this Mac" : "Repair could not connect all devices",
        snapshots: snapshots
      )
      self.logger.log("\(report.message) in \(self.formatDuration(since: startedAt))")
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

    release(device, named: magicDevice.name)
  }

  private func take(_ magicDevice: MagicDevice, forceRepair: Bool = false) {
    guard var device = IOBluetoothDevice(addressString: magicDevice.address) else {
      logger.log("\(magicDevice.name): unavailable during take")
      return
    }

    if forceRepair || device.isConnected() {
      let reason = forceRepair ? "repair requested" : "already connected; refreshing stale connection"
      logger.log("\(magicDevice.name): \(reason)")
      release(device, named: magicDevice.name)
      Thread.sleep(forTimeInterval: 1.2)
      guard let refreshedDevice = IOBluetoothDevice(addressString: magicDevice.address) else {
        logger.log("\(magicDevice.name): unavailable after refresh")
        return
      }
      device = refreshedDevice
    }

    pair(device, named: magicDevice.name)

    if connect(device, named: magicDevice.name, attempts: 1...3) {
      return
    }

    logger.log("\(magicDevice.name): stale pairing recovery")
    release(device, named: magicDevice.name)
    Thread.sleep(forTimeInterval: 2.0)

    guard let recoveredDevice = IOBluetoothDevice(addressString: magicDevice.address) else {
      logger.log("\(magicDevice.name): unavailable after stale pairing recovery")
      return
    }

    pair(recoveredDevice, named: magicDevice.name)
    _ = connect(recoveredDevice, named: magicDevice.name, attempts: 4...6)
  }

  private func connect(_ device: IOBluetoothDevice, named name: String, attempts: ClosedRange<Int>) -> Bool {
    for attempt in attempts {
      if waitForConnected(device, seconds: 1) {
        logger.log("\(name): connected before attempt \(attempt)")
        return true
      }

      let result = device.openConnection(
        nil,
        withPageTimeout: BluetoothHCIPageTimeout(kDefaultPageTimeout.rawValue),
        authenticationRequired: false
      )
      logger.log("\(name): openConnection attempt \(attempt) -> \(formatIOReturn(result))")

      if waitForConnected(device, seconds: 3) {
        return true
      }

      Thread.sleep(forTimeInterval: 1.5)
    }

    return false
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

  private func waitForConnected(_ device: IOBluetoothDevice, seconds: Int) -> Bool {
    for _ in 0..<(seconds * 4) {
      if device.isConnected() {
        return true
      }
      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  private func release(_ device: IOBluetoothDevice, named name: String) {
    if device.isConnected() {
      let closeResult = device.closeConnection()
      logger.log("\(name): closeConnection -> \(formatIOReturn(closeResult))")
      Thread.sleep(forTimeInterval: 0.6)
    }

    let removeSelector = Selector(("remove"))
    if device.responds(to: removeSelector) {
      _ = device.perform(removeSelector)
      logger.log("\(name): remove pairing requested")
    } else {
      logger.log("\(name): remove selector unavailable")
    }
  }

  private func beginOperation(_ name: String) -> Bool {
    operationLock.lock()
    defer { operationLock.unlock() }

    guard activeOperation == nil else {
      return false
    }

    activeOperation = name
    return true
  }

  private func endOperation(_ name: String) {
    operationLock.lock()
    if activeOperation == name {
      activeOperation = nil
    }
    operationLock.unlock()
  }

  private func busyReport() -> OperationReport {
    operationLock.lock()
    let operation = activeOperation ?? "Bluetooth operation"
    operationLock.unlock()

    let message = "\(operation) already in progress"
    logger.log(message)
    return OperationReport(ok: false, message: message)
  }

  private func summarize(_ snapshots: [DeviceSnapshot]) -> String {
    snapshots
      .map { "\($0.device.name): \($0.status.rawValue)" }
      .joined(separator: ", ")
  }

  private func formatIOReturn(_ result: IOReturn) -> String {
    "\(result) (0x\(String(format: "%08X", UInt32(bitPattern: result))))"
  }

  private func formatDuration(since startedAt: Date) -> String {
    String(format: "%.1fs", Date().timeIntervalSince(startedAt))
  }
}

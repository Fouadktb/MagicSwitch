import Foundation
import IOBluetooth
import MagicSwitchCore

final class BluetoothController: @unchecked Sendable, LocalBluetoothManaging {
  private let connectionAttempts = 2
  private let connectionPageTimeout = BluetoothHCIPageTimeout(0x0800)
  private let snapshotTimeoutNanoseconds: UInt64 = 1_500_000_000
  private let deviceLookupTimeoutSeconds: TimeInterval = 3
  private var configuration: ConfigurationLoadResult
  private let configurationLock = NSLock()
  private let queue = DispatchQueue(label: "com.fouad.magicswitch.bluetooth", qos: .userInitiated)
  private let logger = Logger.shared
  private let operationLock = NSLock()
  private var activeOperation: String?

  var configURL: URL {
    AppConfig.configURL
  }

  var hasConfiguredDevices: Bool {
    !configuredDevices().isEmpty
  }

  init(configuration: ConfigurationLoadResult = AppConfig.loadConfiguration()) {
    self.configuration = configuration
    logger.log(configuration.message)
  }

  func reloadConfiguration() {
    let configuration = AppConfig.loadConfiguration()
    configurationLock.lock()
    self.configuration = configuration
    configurationLock.unlock()
    logger.log(configuration.message)
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
    let devices = configuredDevices()
    guard !devices.isEmpty else {
      return OperationReport(ok: false, message: "No devices configured")
    }

    var snapshots: [DeviceSnapshot] = []
    for device in devices {
      snapshots.append(await snapshotWithTimeout(for: device))
    }

    return OperationReport(ok: true, message: summarize(snapshots), snapshots: snapshots)
  }

  func releaseAll() async -> OperationReport {
    guard beginOperation("Release") else {
      return busyReport()
    }

    return await run {
      defer { self.endOperation("Release") }

      let devices = self.configuredDevices()
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
      self.logger.log("Disconnect requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.disconnect(device)
        self.waitForReleased(device, seconds: 6)
        snapshots.append(self.snapshot(for: device))
      }

      let ok = snapshots.allSatisfy { $0.status != .pairedConnected }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Disconnected local devices" : "Some devices are still connected",
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

      let devices = self.configuredDevices()
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

      let devices = self.configuredDevices()
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
      self.logger.log("Repair requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.repair(device)
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

  func forgetAll() async -> OperationReport {
    guard beginOperation("Forget") else {
      return busyReport()
    }

    return await run {
      defer { self.endOperation("Forget") }

      let devices = self.configuredDevices()
      guard !devices.isEmpty else {
        return OperationReport(ok: false, message: "No devices configured")
      }

      let startedAt = Date()
      self.logger.log("Forget requested")
      var snapshots: [DeviceSnapshot] = []

      for device in devices {
        self.forget(device)
        self.waitForReleased(device, seconds: 6)
        snapshots.append(self.snapshot(for: device))
      }

      let ok = snapshots.allSatisfy { $0.status != .pairedConnected }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Forgot local pairings" : "Some devices are still connected",
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

  private func configuredDevices() -> [MagicDevice] {
    configurationLock.lock()
    let devices = configuration.devices
    configurationLock.unlock()
    return devices
  }

  private func snapshotWithTimeout(for magicDevice: MagicDevice) async -> DeviceSnapshot {
    await withCheckedContinuation { continuation in
      let lock = NSLock()
      var didResume = false

      let finish: (DeviceSnapshot) -> Void = { snapshot in
        lock.lock()
        guard !didResume else {
          lock.unlock()
          return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: snapshot)
      }

      DispatchQueue.global(qos: .utility).async {
        finish(self.snapshot(for: magicDevice))
      }

      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(snapshotTimeoutNanoseconds))) {
        finish(DeviceSnapshot(device: magicDevice, status: .unavailable, detail: "Status timed out"))
      }
    }
  }

  private func snapshot(for magicDevice: MagicDevice) -> DeviceSnapshot {
    guard let device = lookupDevice(magicDevice, context: "status", logTimeout: false) else {
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
      detail: ""
    )
  }

  private func release(_ magicDevice: MagicDevice) {
    disconnect(magicDevice)
  }

  private func disconnect(_ magicDevice: MagicDevice) {
    guard let device = lookupDevice(magicDevice, context: "disconnect") else {
      logger.log("\(magicDevice.name): unavailable during disconnect")
      return
    }

    disconnect(device, named: magicDevice.name)
  }

  private func forget(_ magicDevice: MagicDevice) {
    guard let device = lookupDevice(magicDevice, context: "forget") else {
      logger.log("\(magicDevice.name): unavailable during forget")
      return
    }

    forget(device, named: magicDevice.name)
  }

  private func repair(_ magicDevice: MagicDevice) {
    guard let device = lookupDevice(magicDevice, context: "repair") else {
      logger.log("\(magicDevice.name): unavailable during repair")
      return
    }

    if device.isConnected() {
      logger.log("\(magicDevice.name): refreshing existing connection")
      disconnect(device, named: magicDevice.name)
      Thread.sleep(forTimeInterval: 1.2)
    }

    guard pair(device, named: magicDevice.name) else {
      return
    }

    _ = connect(device, named: magicDevice.name, attempts: 1...connectionAttempts)
  }

  private func take(_ magicDevice: MagicDevice) {
    guard let device = lookupDevice(magicDevice, context: "take") else {
      logger.log("\(magicDevice.name): unavailable during take")
      return
    }

    if device.isConnected() {
      logger.log("\(magicDevice.name): already connected")
      return
    }

    guard pair(device, named: magicDevice.name) else {
      return
    }
    _ = connect(device, named: magicDevice.name, attempts: 1...connectionAttempts)
  }

  private func connect(_ device: IOBluetoothDevice, named name: String, attempts: ClosedRange<Int>) -> Bool {
    for attempt in attempts {
      if waitForConnected(device, seconds: 1) {
        logger.log("\(name): connected before attempt \(attempt)")
        return true
      }

      let result = device.openConnection(
        nil,
        withPageTimeout: connectionPageTimeout,
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

  private func pair(_ device: IOBluetoothDevice, named name: String) -> Bool {
    if device.isPaired() || device.isConnected() {
      logger.log("\(name): already paired")
      Thread.sleep(forTimeInterval: 0.3)
      return true
    }

    guard let pair = IOBluetoothDevicePair(device: device) else {
      logger.log("\(name): failed to create pair object")
      return false
    }

    let result = pair.start()
    logger.log("\(name): pair start -> \(formatIOReturn(result))")

    for _ in 0..<20 {
      if device.isPaired() || device.isConnected() {
        logger.log("\(name): pair observed as complete")
        Thread.sleep(forTimeInterval: 0.6)
        return true
      }
      Thread.sleep(forTimeInterval: 0.5)
    }

    logger.log("\(name): pair wait timed out")
    return false
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

  private func disconnect(_ device: IOBluetoothDevice, named name: String) {
    if device.isConnected() {
      let closeResult = device.closeConnection()
      logger.log("\(name): closeConnection -> \(formatIOReturn(closeResult))")
      Thread.sleep(forTimeInterval: 0.6)
    } else {
      logger.log("\(name): already disconnected")
    }
  }

  private func forget(_ device: IOBluetoothDevice, named name: String) {
    let removeSelector = Selector(("remove"))
    if device.responds(to: removeSelector) {
      _ = device.perform(removeSelector)
      logger.log("\(name): remove pairing requested")
    } else {
      logger.log("\(name): remove selector unavailable")
    }

    Thread.sleep(forTimeInterval: 0.8)

    if device.isConnected() {
      logger.log("\(name): still connected after remove; closing")
      disconnect(device, named: name)
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

  private func lookupDevice(_ magicDevice: MagicDevice, context: String, logTimeout: Bool = true) -> IOBluetoothDevice? {
    withTimeout(seconds: deviceLookupTimeoutSeconds, fallback: {
      if logTimeout {
        self.logger.log("\(magicDevice.name): device lookup timed out during \(context)")
      }
      return nil
    }) {
      IOBluetoothDevice(addressString: magicDevice.address)
    }
  }

  private func withTimeout<T>(seconds: TimeInterval, fallback: @escaping () -> T, _ body: @escaping () -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var completed = false
    var value: T?

    DispatchQueue.global(qos: .userInitiated).async {
      let output = body()
      lock.lock()
      if !completed {
        value = output
        completed = true
        lock.unlock()
        semaphore.signal()
      } else {
        lock.unlock()
      }
    }

    if semaphore.wait(timeout: .now() + seconds) == .timedOut {
      lock.lock()
      completed = true
      lock.unlock()
      return fallback()
    }

    return value ?? fallback()
  }
}

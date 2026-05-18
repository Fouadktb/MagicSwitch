import Foundation
import IOBluetooth
import MagicSwitchCore

final class BluetoothController: @unchecked Sendable, LocalBluetoothManaging {
  private let connectionAttempts = 2
  private let connectionPageTimeout = BluetoothHCIPageTimeout(0x0800)
  private let snapshotTimeoutNanoseconds: UInt64 = 10_000_000_000
  private let deviceLookupTimeoutSeconds: TimeInterval = 3
  private let bluetoothStateTimeoutSeconds: TimeInterval = 1
  private let bluetoothActionTimeoutSeconds: TimeInterval = 8
  private let systemProfilerTimeoutSeconds: TimeInterval = 6
  private let pairingRemovalSettleSeconds: TimeInterval = 2.5
  private let takeRetryLimit = 3
  private let takeRetryDelaySeconds: TimeInterval = 1.5
  private let takeStabilityDelaySeconds: TimeInterval = 6
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

      for pass in 1...self.takeRetryLimit {
        self.logger.log("Take pass \(pass) of \(self.takeRetryLimit)")

        for device in devices {
          let snapshot = self.snapshot(for: device)
          if snapshot.status == .pairedConnected {
            self.logger.log("\(device.name): already connected before take pass \(pass)")
          } else {
            self.take(device)
          }
        }

        Thread.sleep(forTimeInterval: self.takeRetryDelaySeconds)
        snapshots = devices.map { self.snapshot(for: $0) }

        guard snapshots.allSatisfy({ $0.status == .pairedConnected }) else {
          self.logger.log("Take pass \(pass) did not connect all devices")
          continue
        }

        Thread.sleep(forTimeInterval: self.takeStabilityDelaySeconds)
        snapshots = devices.map { self.snapshot(for: $0) }

        if snapshots.allSatisfy({ $0.status == .pairedConnected }) {
          let report = OperationReport(
            ok: true,
            message: "Devices connected to this Mac",
            snapshots: snapshots
          )
          self.logger.log("\(report.message) in \(self.formatDuration(since: startedAt))")
          return report
        }

        self.logger.log("Devices dropped during stability check after take pass \(pass)")
      }

      let report = OperationReport(
        ok: false,
        message: "Not all devices stayed connected",
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
      var removalResults: [Bool] = []

      for device in devices {
        removalResults.append(self.forget(device))
      }

      Thread.sleep(forTimeInterval: self.pairingRemovalSettleSeconds)

      for device in devices {
        snapshots.append(self.snapshot(for: device))
      }

      let ok = removalResults.allSatisfy { $0 }
      let report = OperationReport(
        ok: ok,
        message: ok ? "Requested local pairing removal" : "Some pairings could not be removed",
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
      if let snapshot = systemSnapshot(for: magicDevice) {
        return snapshot
      }
      return DeviceSnapshot(device: magicDevice, status: .unavailable, detail: "No IOBluetoothDevice")
    }

    if let isConnected = isConnected(device, named: magicDevice.name, context: "status", logTimeout: false) {
      if isConnected {
        return DeviceSnapshot(device: magicDevice, status: .pairedConnected, detail: "")
      }

      if let isPaired = isPaired(device, named: magicDevice.name, context: "status", logTimeout: false) {
        return DeviceSnapshot(
          device: magicDevice,
          status: isPaired ? .pairedDisconnected : .unpaired,
          detail: ""
        )
      }
    }

    if let snapshot = systemSnapshot(for: magicDevice) {
      return snapshot
    }

    return DeviceSnapshot(device: magicDevice, status: .unavailable, detail: "Bluetooth status timed out")
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

  private func forget(_ magicDevice: MagicDevice) -> Bool {
    guard let device = lookupDevice(magicDevice, context: "forget") else {
      logger.log("\(magicDevice.name): unavailable during forget")
      return false
    }

    return forget(device, named: magicDevice.name)
  }

  private func repair(_ magicDevice: MagicDevice) {
    guard let device = lookupDevice(magicDevice, context: "repair") else {
      logger.log("\(magicDevice.name): unavailable during repair")
      return
    }

    if isConnected(device, named: magicDevice.name, context: "repair") == true {
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
    if systemSnapshot(for: magicDevice)?.status == .pairedConnected {
      logger.log("\(magicDevice.name): already connected according to macOS")
      return
    }

    guard let device = lookupDevice(magicDevice, context: "take") else {
      logger.log("\(magicDevice.name): unavailable during take")
      return
    }

    if isConnected(device, named: magicDevice.name, context: "take") == true {
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

      let openResult: IOReturn? = bluetoothCall(
        "\(name): openConnection attempt \(attempt) timed out",
        timeout: bluetoothActionTimeoutSeconds
      ) {
        device.openConnection(
          nil,
          withPageTimeout: self.connectionPageTimeout,
          authenticationRequired: false
        )
      }
      guard let result = openResult else {
        return false
      }
      logger.log("\(name): openConnection attempt \(attempt) -> \(formatIOReturn(result))")

      if waitForConnected(device, seconds: 3) {
        return true
      }

      Thread.sleep(forTimeInterval: 1.5)
    }

    return false
  }

  private func pair(_ device: IOBluetoothDevice, named name: String) -> Bool {
    if isPaired(device, named: name, context: "pair") == true || isConnected(device, named: name, context: "pair") == true {
      logger.log("\(name): already paired")
      Thread.sleep(forTimeInterval: 0.3)
      return true
    }

    let pair = withTimeout(seconds: bluetoothActionTimeoutSeconds, fallback: {
      self.logger.log("\(name): pair object creation timed out")
      return nil as IOBluetoothDevicePair?
    }) {
      IOBluetoothDevicePair(device: device)
    }

    guard let pair else {
      logger.log("\(name): failed to create pair object")
      return false
    }

    guard let result: IOReturn = bluetoothCall(
      "\(name): pair start timed out",
      timeout: bluetoothActionTimeoutSeconds,
      pair.start
    ) else {
      return false
    }
    logger.log("\(name): pair start -> \(formatIOReturn(result))")

    for _ in 0..<20 {
      if isPaired(device, named: name, context: "pair wait", timeout: 0.5) == true
        || isConnected(device, named: name, context: "pair wait", timeout: 0.5) == true {
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
      if isConnected(device, named: "Device", context: "connect wait", timeout: 0.5, logTimeout: false) == true {
        return true
      }
      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  private func disconnect(_ device: IOBluetoothDevice, named name: String) {
    let connected = isConnected(device, named: name, context: "disconnect")
    if connected != false {
      closeConnection(device, named: name)
    } else {
      logger.log("\(name): already disconnected")
    }
  }

  private func forget(_ device: IOBluetoothDevice, named name: String) -> Bool {
    let removeSelector = Selector(("remove"))
    if device.responds(to: removeSelector) {
      _ = device.perform(removeSelector)
      logger.log("\(name): remove pairing requested")
      return true
    } else {
      logger.log("\(name): remove selector unavailable")
      return false
    }
  }

  private func closeConnection(_ device: IOBluetoothDevice, named name: String) {
    let closeResult = device.closeConnection()
    logger.log("\(name): closeConnection -> \(formatIOReturn(closeResult))")
    Thread.sleep(forTimeInterval: 0.6)
  }

  private func isConnected(
    _ device: IOBluetoothDevice,
    named name: String,
    context: String,
    timeout: TimeInterval? = nil,
    logTimeout: Bool = true
  ) -> Bool? {
    bluetoothCall(
      logTimeout ? "\(name): isConnected timed out during \(context)" : nil,
      timeout: timeout ?? bluetoothStateTimeoutSeconds
    ) {
      device.isConnected()
    }
  }

  private func isPaired(
    _ device: IOBluetoothDevice,
    named name: String,
    context: String,
    timeout: TimeInterval? = nil,
    logTimeout: Bool = true
  ) -> Bool? {
    bluetoothCall(
      logTimeout ? "\(name): isPaired timed out during \(context)" : nil,
      timeout: timeout ?? bluetoothStateTimeoutSeconds
    ) {
      device.isPaired()
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

  private func bluetoothCall<T>(_ timeoutMessage: String?, timeout: TimeInterval, _ body: @escaping () -> T) -> T? {
    withTimeout(seconds: timeout, fallback: {
      if let timeoutMessage {
        self.logger.log(timeoutMessage)
      }
      return nil
    }) {
      body()
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

private extension BluetoothController {
  struct SystemBluetoothSnapshot {
    let controllerIsOn: Bool?
    let connectedAddresses: Set<String>
    let knownAddresses: Set<String>
  }

  func systemSnapshot(for magicDevice: MagicDevice) -> DeviceSnapshot? {
    guard let systemSnapshot = loadSystemBluetoothSnapshot() else {
      return nil
    }

    if systemSnapshot.connectedAddresses.contains(magicDevice.address) {
      return DeviceSnapshot(device: magicDevice, status: .pairedConnected, detail: "Verified by macOS")
    }

    if systemSnapshot.knownAddresses.contains(magicDevice.address) {
      return DeviceSnapshot(device: magicDevice, status: .pairedDisconnected, detail: "Verified by macOS")
    }

    if systemSnapshot.controllerIsOn == false {
      return DeviceSnapshot(device: magicDevice, status: .unavailable, detail: "Bluetooth is off")
    }

    return DeviceSnapshot(device: magicDevice, status: .unpaired, detail: "Not listed by macOS")
  }

  func loadSystemBluetoothSnapshot() -> SystemBluetoothSnapshot? {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["-json", "SPBluetoothDataType"]
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      logger.log("system_profiler Bluetooth status failed: \(error.localizedDescription)")
      return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + systemProfilerTimeoutSeconds) == .timedOut {
      process.terminate()
      logger.log("system_profiler Bluetooth status timed out")
      return nil
    }

    guard process.terminationStatus == 0 else {
      logger.log("system_profiler Bluetooth status exited with \(process.terminationStatus)")
      return nil
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sections = root["SPBluetoothDataType"] as? [[String: Any]]
    else {
      logger.log("system_profiler Bluetooth status could not be parsed")
      return nil
    }

    var controllerIsOn: Bool?
    var connectedAddresses = Set<String>()
    var knownAddresses = Set<String>()

    for section in sections {
      if let controller = section["controller_properties"] as? [String: Any],
         let state = controller["controller_state"] as? String {
        controllerIsOn = state == "attrib_on"
      }

      let connected = addresses(in: section["device_connected"])
      connectedAddresses.formUnion(connected)
      knownAddresses.formUnion(connected)
      knownAddresses.formUnion(addresses(in: section["device_not_connected"]))
    }

    return SystemBluetoothSnapshot(
      controllerIsOn: controllerIsOn,
      connectedAddresses: connectedAddresses,
      knownAddresses: knownAddresses
    )
  }

  func addresses(in value: Any?) -> Set<String> {
    guard let devices = value as? [[String: Any]] else {
      return []
    }

    var addresses = Set<String>()
    for device in devices {
      for properties in device.values {
        guard
          let properties = properties as? [String: Any],
          let rawAddress = properties["device_address"] as? String,
          let address = AppConfig.canonicalBluetoothAddress(rawAddress)
        else {
          continue
        }
        addresses.insert(address)
      }
    }

    return addresses
  }
}

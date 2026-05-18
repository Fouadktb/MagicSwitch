import AppKit
import Foundation
import MagicSwitchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let bluetooth = BluetoothController()
  private let peerService = PeerService()
  private let logger = Logger.shared
  private var statusItem: NSStatusItem?
  private var deviceManager: DeviceManagerWindowController?
  private var lastMessage = "Starting..."
  private let userOperationLock = NSLock()
  private var userOperationInFlight = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusItem()
    peerService.start { [weak self] command in
      await self?.handle(command) ?? OperationReport(ok: false, message: "App delegate unavailable")
    }
    setMessage(bluetooth.hasConfiguredDevices ? "Ready" : "No devices configured")
    Task { await refreshStatus() }
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.title = ""
      button.image = statusBarImage(failed: false)
      button.imagePosition = .imageOnly
      button.target = self
      button.action = #selector(openMenu)
      button.toolTip = AppConfig.appName
    }
    statusItem = item
  }

  @objc private func openMenu() {
    let menu = NSMenu()

    let status = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)

    let peer = NSMenuItem(title: "Peer: \(peerService.peerDescription)", action: nil, keyEquivalent: "")
    peer.isEnabled = false
    menu.addItem(peer)

    menu.addItem(.separator())
    let actionsEnabled = !isUserOperationActive
    let switchItem = NSMenuItem(title: "Switch Devices", action: #selector(switchDevices), keyEquivalent: "s")
    switchItem.isEnabled = actionsEnabled
    menu.addItem(switchItem)

    let takeItem = NSMenuItem(title: "Take Devices to This Mac", action: #selector(takeDevicesToThisMac), keyEquivalent: "t")
    takeItem.isEnabled = actionsEnabled
    menu.addItem(takeItem)

    let releaseItem = NSMenuItem(title: "Disconnect Devices from This Mac", action: #selector(releaseLocalDevices), keyEquivalent: "r")
    releaseItem.isEnabled = actionsEnabled
    menu.addItem(releaseItem)

    let repairItem = NSMenuItem(title: "Repair Devices on This Mac", action: #selector(repairLocalDevices), keyEquivalent: "")
    repairItem.isEnabled = actionsEnabled
    menu.addItem(repairItem)

    let forgetItem = NSMenuItem(title: "Forget Pairings on This Mac...", action: #selector(forgetLocalDevices), keyEquivalent: "")
    forgetItem.isEnabled = actionsEnabled
    menu.addItem(forgetItem)

    menu.addItem(NSMenuItem(title: "Refresh Status", action: #selector(refreshStatusAction), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Manage Devices...", action: #selector(manageDevices), keyEquivalent: "m"))
    menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ","))
    menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l"))
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

    menu.items.forEach { $0.target = self }

    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  @objc private func switchDevices() {
    guard beginUserOperation(message: "Switching...") else { return }

    Task {
      defer { finishUserOperation() }

      setMessage(userMessage(for: await switchDevicesReport()))
    }
  }

  @objc private func takeDevicesToThisMac() {
    guard beginUserOperation(message: "Switching...") else { return }

    Task {
      defer { finishUserOperation() }

      setMessage(userMessage(for: await switchToThisMacReport()))
    }
  }

  @objc private func releaseLocalDevices() {
    guard beginUserOperation(message: "Disconnecting...") else { return }

    Task {
      defer { finishUserOperation() }

      let report = await bluetooth.releaseAll()
      setMessage(report.message)
    }
  }

  @objc private func forgetLocalDevices() {
    let alert = NSAlert()
    alert.messageText = "Forget pairings on this Mac?"
    alert.informativeText = "This removes the configured Bluetooth pairings from this Mac. Use it only when a normal disconnect or repair is not enough."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Forget Pairings")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    guard beginUserOperation(message: "Forgetting...") else { return }

    Task {
      defer { finishUserOperation() }

      let report = await bluetooth.forgetAll()
      setMessage(report.message)
    }
  }

  @objc private func repairLocalDevices() {
    guard beginUserOperation(message: "Repairing...") else { return }

    Task {
      defer { finishUserOperation() }

      let report = await bluetooth.repairAll()
      setMessage(report.message)
    }
  }

  @objc private func refreshStatusAction() {
    Task { await refreshStatus() }
  }

  private func refreshStatus() async {
    let report = await bluetooth.status()
    setMessage(report.message)
  }

  private func handle(_ command: SwitchCommand) async -> OperationReport {
    switch command {
    case .health:
      return OperationReport(ok: true, message: "OK")
    case .status:
      return await bluetooth.status()
    case .releaseAll:
      return await bluetooth.releaseAll()
    case .forgetAll:
      return await bluetooth.forgetAll()
    case .takeAll:
      return await bluetooth.takeAll()
    case .switchDevices:
      return await switchDevicesReport()
    case .switchToThisMac:
      return await switchToThisMacReport()
    case .switchToPeer:
      return await switchToPeerReport()
    }
  }

  private func switchDevicesReport() async -> OperationReport {
    let localStatus = await bluetooth.status()
    let allLocal = !localStatus.snapshots.isEmpty && localStatus.snapshots.allSatisfy { $0.status == .pairedConnected }
    return allLocal
      ? await switchToPeerReport()
      : await switchToThisMacReport()
  }

  private func switchToThisMacReport() async -> OperationReport {
    let coordinator = SwitchCoordinator(bluetooth: bluetooth, peer: peerService)
    return await report(for: coordinator.switchToThisMac())
  }

  private func switchToPeerReport() async -> OperationReport {
    let coordinator = SwitchCoordinator(bluetooth: bluetooth, peer: peerService)
    return await report(for: coordinator.switchToPeer())
  }

  private func report(for outcome: SwitchOutcome) -> OperationReport {
    switch outcome {
    case .switched(let report):
      return report
    case .failed(let message):
      return OperationReport(ok: false, message: message)
    }
  }

  private func userMessage(for report: OperationReport) -> String {
    report.ok ? report.message : "Failed: \(report.message)"
  }

  private func setMessage(_ message: String) {
    let update = {
      self.lastMessage = message
      self.logger.log(message)
      self.updateStatusBarIcon(failed: message.hasPrefix("Failed"))
    }

    if Thread.isMainThread {
      update()
    } else {
      DispatchQueue.main.async(execute: update)
    }
  }

  private var isUserOperationActive: Bool {
    userOperationLock.lock()
    let active = userOperationInFlight
    userOperationLock.unlock()
    return active
  }

  private func beginUserOperation(message: String) -> Bool {
    userOperationLock.lock()
    if userOperationInFlight {
      userOperationLock.unlock()
      setMessage("Already switching. Wait for the current operation.")
      return false
    }
    userOperationInFlight = true
    userOperationLock.unlock()

    setMessage(message)
    return true
  }

  private func finishUserOperation() {
    userOperationLock.lock()
    userOperationInFlight = false
    userOperationLock.unlock()
  }

  @objc private func openLog() {
    NSWorkspace.shared.open(logger.logURL)
  }

  @objc private func manageDevices() {
    if deviceManager == nil {
      deviceManager = DeviceManagerWindowController(bluetooth: bluetooth, peerService: peerService)
    }

    deviceManager?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openConfig() {
    NSWorkspace.shared.open(bluetooth.configURL)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func updateStatusBarIcon(failed: Bool) {
    guard let button = statusItem?.button else {
      return
    }

    button.title = ""
    button.image = statusBarImage(failed: failed)
    button.imagePosition = .imageOnly
    button.toolTip = failed ? "\(AppConfig.appName): \(lastMessage)" : AppConfig.appName
  }

  private func statusBarImage(failed: Bool) -> NSImage? {
    let symbolName = failed ? "exclamationmark.triangle" : "arrow.left.arrow.right"
    let description = failed ? "MagicSwitch failed" : "MagicSwitch"
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
      .withSymbolConfiguration(configuration)
    image?.isTemplate = true
    return image
  }
}

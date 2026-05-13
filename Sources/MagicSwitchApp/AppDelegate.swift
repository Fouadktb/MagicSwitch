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
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "MS"
    item.button?.target = self
    item.button?.action = #selector(openMenu)
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
    menu.addItem(NSMenuItem(title: "Switch Devices", action: #selector(switchDevices), keyEquivalent: "s"))
    menu.addItem(NSMenuItem(title: "Take Devices to This Mac", action: #selector(takeDevicesToThisMac), keyEquivalent: "t"))
    menu.addItem(NSMenuItem(title: "Release Devices from This Mac", action: #selector(releaseLocalDevices), keyEquivalent: "r"))
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
    setMessage("Switching...")
    Task {
      let localStatus = await bluetooth.status()
      let allLocal = !localStatus.snapshots.isEmpty && localStatus.snapshots.allSatisfy { $0.status == .pairedConnected }
      let coordinator = SwitchCoordinator(bluetooth: bluetooth, peer: peerService)
      let outcome = allLocal
        ? await coordinator.switchToPeer()
        : await coordinator.switchToThisMac()

      switch outcome {
      case .switched(let report):
        setMessage(report.message)
      case .failed(let message):
        setMessage("Failed: \(message)")
      }
    }
  }

  @objc private func takeDevicesToThisMac() {
    setMessage("Switching...")
    Task {
      let coordinator = SwitchCoordinator(bluetooth: bluetooth, peer: peerService)
      let outcome = await coordinator.switchToThisMac()

      switch outcome {
      case .switched(let report):
        setMessage(report.message)
      case .failed(let message):
        setMessage("Failed: \(message)")
      }
    }
  }

  @objc private func releaseLocalDevices() {
    setMessage("Releasing...")
    Task {
      let report = await bluetooth.releaseAll()
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
    case .takeAll:
      return await bluetooth.takeAll()
    }
  }

  private func setMessage(_ message: String) {
    let update = {
      self.lastMessage = message
      self.logger.log(message)
      self.statusItem?.button?.title = message.hasPrefix("Failed") ? "MS!" : "MS"
    }

    if Thread.isMainThread {
      update()
    } else {
      DispatchQueue.main.async(execute: update)
    }
  }

  @objc private func openLog() {
    NSWorkspace.shared.open(logger.logURL)
  }

  @objc private func manageDevices() {
    if deviceManager == nil {
      deviceManager = DeviceManagerWindowController(bluetooth: bluetooth)
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
}

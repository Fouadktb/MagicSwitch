import AppKit
import Foundation
import MagicSwitchCore

final class DeviceManagerWindowController: NSWindowController {
  private let bluetooth: BluetoothController
  private let scanner = BluetoothDeviceScanner()

  private let statusLabel = NSTextField(labelWithString: "")
  private let registeredStack = NSStackView()
  private let availableStack = NSStackView()
  private let scanButton = NSButton(title: "Scan", target: nil, action: nil)

  private var registeredDevices: [MagicDevice] = []
  private var availableDevices: [BluetoothDeviceCandidate] = []

  init(bluetooth: BluetoothController) {
    self.bluetooth = bluetooth

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MagicSwitch"
    window.isReleasedWhenClosed = false
    window.center()

    super.init(window: window)
    buildInterface()
    refreshDevices(scan: false)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    refreshDevices(scan: false)
  }

  deinit {
    scanner.stop()
  }

  private func buildInterface() {
    guard let window else {
      return
    }

    let contentView = NSView()
    window.contentView = contentView

    let rootStack = NSStackView()
    rootStack.orientation = .vertical
    rootStack.alignment = .leading
    rootStack.spacing = 18
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(rootStack)

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
      rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
      rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
    ])

    rootStack.addArrangedSubview(makeHeader())
    rootStack.addArrangedSubview(makeSection(title: "Registered Peripherals", stack: registeredStack))
    rootStack.addArrangedSubview(makeSection(title: "Available Peripherals", stack: availableStack))
  }

  private func makeHeader() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.stringValue = "Ready"
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail

    scanButton.target = self
    scanButton.action = #selector(scanDevices)
    scanButton.bezelStyle = .rounded

    row.addArrangedSubview(statusLabel)
    row.addArrangedSubview(makeSpacer())
    row.addArrangedSubview(scanButton)

    NSLayoutConstraint.activate([
      row.widthAnchor.constraint(equalToConstant: 576),
      statusLabel.heightAnchor.constraint(equalToConstant: 24),
    ])

    return row
  }

  private func makeSection(title: String, stack: NSStackView) -> NSView {
    let section = NSStackView()
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 8
    section.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .labelColor

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false

    section.addArrangedSubview(label)
    section.addArrangedSubview(stack)

    NSLayoutConstraint.activate([
      section.widthAnchor.constraint(equalToConstant: 576),
      stack.widthAnchor.constraint(equalToConstant: 576),
    ])

    return section
  }

  private func refreshDevices(scan: Bool) {
    let configuration = AppConfig.loadConfiguration()
    registeredDevices = configuration.devices

    if scan {
      statusLabel.stringValue = "Scanning..."
      scanButton.isEnabled = false
      scanner.scan { [weak self] devices in
        guard let self else { return }
        self.availableDevices = devices
        self.scanButton.isEnabled = true
        self.statusLabel.stringValue = "Found \(devices.count) device(s)"
        self.renderDevices()
      }
    } else {
      availableDevices = scanner.cachedDevices()
      statusLabel.stringValue = configuration.message
      renderDevices()
    }
  }

  private func renderDevices() {
    clear(stack: registeredStack)
    clear(stack: availableStack)

    if registeredDevices.isEmpty {
      registeredStack.addArrangedSubview(makeEmptyRow("No registered peripherals"))
    } else {
      for device in registeredDevices {
        registeredStack.addArrangedSubview(
          makeRow(
            title: device.name,
            detail: device.address,
            buttonTitle: "Remove",
            address: device.address,
            action: #selector(removeDevice)
          )
        )
      }
    }

    let registeredAddresses = Set(registeredDevices.map(\.address))
    let addableDevices = availableDevices.filter { !registeredAddresses.contains($0.address) }

    if addableDevices.isEmpty {
      availableStack.addArrangedSubview(makeEmptyRow("No available peripherals"))
    } else {
      for device in addableDevices {
        let detail = "\(device.address) · \(statusText(for: device.status)) · \(device.source)"
        availableStack.addArrangedSubview(
          makeRow(
            title: device.name,
            detail: detail,
            buttonTitle: "Add",
            address: device.address,
            action: #selector(addDevice)
          )
        )
      }
    }
  }

  private func makeRow(
    title: String,
    detail: String,
    buttonTitle: String,
    address: String,
    action: Selector
  ) -> NSView {
    let row = NSView()
    row.wantsLayer = true
    row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    row.layer?.borderColor = NSColor.separatorColor.cgColor
    row.layer?.borderWidth = 1
    row.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(stack)

    let textStack = NSStackView()
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail

    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingMiddle

    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(detailLabel)

    let button = DeviceActionButton(title: buttonTitle, target: self, action: action)
    button.address = address
    button.bezelStyle = .rounded
    button.controlSize = .small

    stack.addArrangedSubview(textStack)
    stack.addArrangedSubview(makeSpacer())
    stack.addArrangedSubview(button)

    NSLayoutConstraint.activate([
      row.widthAnchor.constraint(equalToConstant: 576),
      row.heightAnchor.constraint(equalToConstant: 48),
      stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
      detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
    ])

    return row
  }

  private func makeEmptyRow(_ title: String) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: title)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(label)

    NSLayoutConstraint.activate([
      row.widthAnchor.constraint(equalToConstant: 576),
      row.heightAnchor.constraint(equalToConstant: 34),
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])

    return row
  }

  private func makeSpacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
  }

  private func clear(stack: NSStackView) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func persistRegisteredDevices() {
    do {
      try bluetooth.saveConfiguredDevices(registeredDevices)
      statusLabel.stringValue = "Saved \(registeredDevices.count) device(s)"
      refreshDevices(scan: false)
    } catch {
      statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
    }
  }

  private func statusText(for status: MagicDeviceStatus) -> String {
    switch status {
    case .pairedConnected:
      return "Connected"
    case .pairedDisconnected:
      return "Paired"
    case .unpaired:
      return "Available"
    case .unavailable:
      return "Unavailable"
    }
  }

  @objc private func scanDevices() {
    refreshDevices(scan: true)
  }

  @objc private func addDevice(_ sender: DeviceActionButton) {
    guard let device = availableDevices.first(where: { $0.address == sender.address }) else {
      return
    }

    if !registeredDevices.contains(where: { $0.address == device.address }) {
      registeredDevices.append(device.magicDevice)
    }

    persistRegisteredDevices()
  }

  @objc private func removeDevice(_ sender: DeviceActionButton) {
    registeredDevices.removeAll { $0.address == sender.address }
    persistRegisteredDevices()
  }
}

private final class DeviceActionButton: NSButton {
  var address = ""
}

import Foundation
import IOBluetooth
import MagicSwitchCore

struct BluetoothDeviceCandidate: Equatable, Hashable {
  let name: String
  let address: String
  let status: MagicDeviceStatus
  let source: String
  let isLikelyInputDevice: Bool

  var magicDevice: MagicDevice {
    MagicDevice(name: name, address: address)
  }
}

final class BluetoothDeviceScanner: NSObject, IOBluetoothDeviceInquiryDelegate {
  private var devicesByAddress: [String: BluetoothDeviceCandidate] = [:]
  private var inquiry: IOBluetoothDeviceInquiry?
  private var completion: (([BluetoothDeviceCandidate]) -> Void)?
  private var isScanning = false

  func cachedDevices() -> [BluetoothDeviceCandidate] {
    var devicesByAddress: [String: BluetoothDeviceCandidate] = [:]

    for device in Self.pairedDevices() {
      Self.upsert(device, source: "Paired", into: &devicesByAddress)
    }

    for device in Self.recentDevices() {
      Self.upsert(device, source: "Recent", into: &devicesByAddress)
    }

    return Self.sorted(Array(devicesByAddress.values))
  }

  func scan(completion: @escaping ([BluetoothDeviceCandidate]) -> Void) {
    if isScanning {
      self.completion = completion
      return
    }

    devicesByAddress = Dictionary(
      uniqueKeysWithValues: cachedDevices().map { ($0.address, $0) }
    )
    self.completion = completion

    let inquiry = IOBluetoothDeviceInquiry(delegate: self)
    inquiry?.inquiryLength = 5
    inquiry?.updateNewDeviceNames = true
    inquiry?.clearFoundDevices()
    self.inquiry = inquiry
    isScanning = true

    let result = inquiry?.start() ?? kIOReturnError
    guard result == kIOReturnSuccess else {
      finishScan()
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
      self?.finishScan()
    }
  }

  func stop() {
    _ = inquiry?.stop()
    finishScan()
  }

  func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let device else { return }
      Self.upsert(device, source: "Nearby", into: &self.devicesByAddress)
    }
  }

  func deviceInquiryDeviceNameUpdated(
    _ sender: IOBluetoothDeviceInquiry!,
    device: IOBluetoothDevice!,
    devicesRemaining: UInt32
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let device else { return }
      Self.upsert(device, source: "Nearby", into: &self.devicesByAddress)
    }
  }

  func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
    DispatchQueue.main.async { [weak self] in
      self?.finishScan()
    }
  }

  private func finishScan() {
    guard isScanning else {
      return
    }

    isScanning = false
    inquiry?.delegate = nil
    inquiry = nil

    let devices = Self.sorted(Array(devicesByAddress.values))
    completion?(devices)
    completion = nil
  }

  private static func pairedDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
  }

  private static func recentDevices() -> [IOBluetoothDevice] {
    (IOBluetoothDevice.recentDevices(0) as? [IOBluetoothDevice]) ?? []
  }

  private static func upsert(
    _ device: IOBluetoothDevice,
    source: String,
    into devicesByAddress: inout [String: BluetoothDeviceCandidate]
  ) {
    guard let address = AppConfig.canonicalBluetoothAddress(device.addressString) else {
      return
    }

    let name = normalizedName(for: device, address: address)
    let status = status(for: device)
    let existing = devicesByAddress[address]
    let sources = mergedSources(existing?.source, source)

    devicesByAddress[address] = BluetoothDeviceCandidate(
      name: name,
      address: address,
      status: status,
      source: sources,
      isLikelyInputDevice: isLikelyInputDevice(name: name)
    )
  }

  private static func normalizedName(for device: IOBluetoothDevice, address: String) -> String {
    let rawName = device.name ?? device.nameOrAddress ?? address
    let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonicalNameAddress = AppConfig.canonicalBluetoothAddress(normalized)

    if normalized.isEmpty || canonicalNameAddress == address {
      return "Bluetooth Device"
    }

    return normalized
  }

  private static func status(for device: IOBluetoothDevice) -> MagicDeviceStatus {
    if device.isConnected() {
      return .pairedConnected
    }

    if device.isPaired() {
      return .pairedDisconnected
    }

    return .unpaired
  }

  private static func mergedSources(_ existing: String?, _ next: String) -> String {
    var parts = existing?.components(separatedBy: ", ") ?? []
    if !parts.contains(next) {
      parts.append(next)
    }
    return parts.joined(separator: ", ")
  }

  private static func isLikelyInputDevice(name: String) -> Bool {
    let lowercased = name.lowercased()
    return lowercased.contains("magic")
      || lowercased.contains("keyboard")
      || lowercased.contains("trackpad")
      || lowercased.contains("mouse")
  }

  private static func sorted(_ devices: [BluetoothDeviceCandidate]) -> [BluetoothDeviceCandidate] {
    devices.sorted { lhs, rhs in
      if lhs.isLikelyInputDevice != rhs.isLikelyInputDevice {
        return lhs.isLikelyInputDevice && !rhs.isLikelyInputDevice
      }

      if lhs.status != rhs.status {
        return statusSortValue(lhs.status) > statusSortValue(rhs.status)
      }

      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static func statusSortValue(_ status: MagicDeviceStatus) -> Int {
    switch status {
    case .pairedConnected:
      return 3
    case .pairedDisconnected:
      return 2
    case .unpaired:
      return 1
    case .unavailable:
      return 0
    }
  }
}

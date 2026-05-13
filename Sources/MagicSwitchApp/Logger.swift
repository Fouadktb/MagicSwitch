import Foundation

final class Logger: @unchecked Sendable {
  static let shared = Logger()

  let logURL: URL
  private let queue = DispatchQueue(label: "com.fouad.magicswitch.logger")

  private init() {
    let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/MagicSwitch", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    logURL = logsDirectory.appendingPathComponent("MagicSwitch.log")
  }

  func log(_ message: String) {
    let line = "[\(Self.timestamp())] \(message)\n"
    queue.async {
      if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: self.logURL.path) {
          if let handle = try? FileHandle(forWritingTo: self.logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
          }
        } else {
          try? data.write(to: self.logURL)
        }
      }
    }
  }

  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }
}

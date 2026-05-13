import Foundation

public struct CommandEnvelope: Codable, Equatable, Sendable {
  public let command: SwitchCommand

  public init(command: SwitchCommand) {
    self.command = command
  }
}

public enum CommandCodec {
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  public static func encode(_ envelope: CommandEnvelope) throws -> Data {
    var data = try encoder.encode(envelope)
    data.append(0x0A)
    return data
  }

  public static func decodeEnvelope(_ data: Data) throws -> CommandEnvelope {
    return try decoder.decode(CommandEnvelope.self, from: trim(data))
  }

  public static func encode(_ report: OperationReport) throws -> Data {
    var data = try encoder.encode(report)
    data.append(0x0A)
    return data
  }

  public static func decodeReport(_ data: Data) throws -> OperationReport {
    return try decoder.decode(OperationReport.self, from: trim(data))
  }

  private static func trim(_ data: Data) -> Data {
    guard let newline = data.firstIndex(of: 0x0A) else {
      return data
    }
    return data[..<newline]
  }
}

/// A small value that a tool gives with the end of its run, for example the
/// exit code of a command.
///
/// On the wire it is the plain JSON value: an int is a number, a string is a
/// string, a bool is a boolean, and an object is an object.
public enum OperationValue: Sendable, Equatable {
    /// A whole number, for example an exit code.
    case int(Int)

    /// A text.
    case string(String)

    /// A flag.
    case bool(Bool)

    /// A JSON object, with a value for each key.
    case object([String: OperationValue])
}

extension OperationValue: Codable {
    /// Decodes the plain JSON value. A JSON boolean is a `.bool`, a JSON
    /// whole number is an `.int`, a JSON string is a `.string`, and a JSON
    /// object is an `.object`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` for a null, an array, or a number that is
    ///   not a whole number.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            self = .object(try container.decode([String: OperationValue].self))
        }
    }

    /// Encodes the plain JSON value.
    ///
    /// - Parameter encoder: The encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .bool(let flag): try container.encode(flag)
        case .object(let fields): try container.encode(fields)
        }
    }
}

/// How a call ended: its outcome, and the value that the tool gave with it.
///
/// A ``ToolCallWitness`` gets it at the end of each call.
public struct OperationResult: Sendable, Equatable, Codable {
    /// How the call ended.
    public let outcome: OperationOutcome

    /// The value that the tool gave with the end of the call, or `nil` for
    /// none.
    public let value: OperationValue?

    /// Makes a result.
    ///
    /// - Parameters:
    ///   - outcome: How the call ended.
    ///   - value: The value that the tool gave, or `nil` for none.
    public init(outcome: OperationOutcome, value: OperationValue? = nil) {
        self.outcome = outcome
        self.value = value
    }
}

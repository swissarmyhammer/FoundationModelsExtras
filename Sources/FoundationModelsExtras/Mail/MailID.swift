import ULID

/// The correlation id of one ``Mail``.
///
/// Each output event of a session carries the ids of the mail that started
/// it, thus a caller can wait for the events of one mail. A `MailID` is a
/// different type from ``SignalID``: you cannot use one in place of the other.
///
/// The encoded form is the ULID string, one value, not an object.
public struct MailID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The ULID of the id.
    public let value: ULID

    /// Makes a new id with a new ULID.
    public init() {
        value = ULID()
    }

    /// Makes an id from a ULID that you have.
    ///
    /// - Parameter value: The ULID of the id.
    public init(_ value: ULID) {
        self.value = value
    }

    /// The ULID string of the id.
    public var description: String { value.ulidString }

    /// Decodes the id from one ULID string.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(ULID.self)
    }

    /// Encodes the id as one ULID string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

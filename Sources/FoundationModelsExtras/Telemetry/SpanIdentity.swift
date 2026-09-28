import Tracing

/// The W3C trace id, span id and trace flags of one span: the fields of a W3C
/// `traceparent` value.
///
/// The generic tracing API gives no ids on a span. A tracer gives them only
/// when it injects the span context into a carrier. An OpenTelemetry tracer
/// injects a W3C `traceparent` value, `<version>-<trace id>-<span id>-<flags>`.
/// This type reads the ids from that value, and writes that value again.
///
/// This type is the one copy of the `traceparent` format in the family. A
/// tracer, a test tracer or a transport that reads or writes a `traceparent`
/// value uses this type and ``traceparentField`` and ``tracestateField``.
///
/// ```swift
/// let fields = SpanIdentity.injectedFields(of: span.context, by: tracer)
/// if let identity = SpanIdentity(traceparent: fields[SpanIdentity.traceparentField] ?? "") {
///     logger.info("call", metadata: ["trace.id": "\(identity.traceID)"])
/// }
/// ```
public struct SpanIdentity: Equatable, Sendable {
    /// The carrier key of the W3C `traceparent` value.
    public static let traceparentField = ExtrasTelemetry.TraceContextField.traceparent

    /// The carrier key of the W3C `tracestate` value.
    public static let tracestateField = ExtrasTelemetry.TraceContextField.tracestate

    /// The trace flags of a sampled trace: the sampled bit is set.
    public static let sampledFlags = "01"

    /// The count of hexadecimal digits of a W3C trace id.
    public static let traceIDLength = 32

    /// The count of hexadecimal digits of a W3C span id.
    public static let spanIDLength = 16

    /// The version that ``traceparent`` writes: version `00` of the format.
    private static let writtenVersion = "00"

    /// The separator of the fields of a `traceparent` value.
    private static let fieldSeparator: Character = "-"

    /// The version that the W3C format forbids.
    private static let forbiddenVersion = "ff"

    /// The digits that a field may hold. The W3C format allows lowercase
    /// hexadecimal digits only.
    private static let lowercaseHexDigits = Set("0123456789abcdef")

    /// The digit of an id that is not valid when each digit is this digit.
    private static let zeroDigit: Character = "0"

    /// The count of hexadecimal digits of the version field.
    private static let versionLength = 2

    /// The count of hexadecimal digits of the trace flags field.
    private static let flagsLength = 2

    /// The fields of a `traceparent` value, in their order.
    private enum Field: Int, CaseIterable {
        /// The version of the format.
        case version

        /// The trace id.
        case traceID

        /// The id of the span, which the W3C format calls the parent id.
        case spanID

        /// The trace flags.
        case flags

        /// The count of hexadecimal digits of the field.
        var length: Int {
            switch self {
            case .version: SpanIdentity.versionLength
            case .traceID: SpanIdentity.traceIDLength
            case .spanID: SpanIdentity.spanIDLength
            case .flags: SpanIdentity.flagsLength
            }
        }
    }

    /// The trace id: 32 lowercase hexadecimal digits, not all zeros.
    public let traceID: String

    /// The span id: 16 lowercase hexadecimal digits, not all zeros.
    public let spanID: String

    /// The trace flags: 2 lowercase hexadecimal digits. The low bit is the
    /// sampled flag.
    public let traceFlags: String

    /// The W3C `traceparent` value of this identity, in the format of version
    /// `00`: `00-<trace id>-<span id>-<trace flags>`.
    public var traceparent: String {
        Self.traceparent(traceID: traceID, spanID: spanID, traceFlags: traceFlags)
    }

    /// Makes the identity of a span from its ids.
    ///
    /// - Parameters:
    ///   - traceID: The trace id: 32 lowercase hexadecimal digits.
    ///   - spanID: The span id: 16 lowercase hexadecimal digits.
    ///   - traceFlags: The trace flags: 2 lowercase hexadecimal digits. The
    ///     default is ``sampledFlags``.
    /// - Returns: `nil` when a value does not have the W3C format, or when an
    ///   id is all zeros.
    public init?(traceID: String, spanID: String, traceFlags: String = sampledFlags) {
        self.init(traceparent: Self.traceparent(traceID: traceID, spanID: spanID, traceFlags: traceFlags))
    }

    /// Reads the ids of the span of `context` from the `traceparent` value
    /// that `tracer` injects.
    ///
    /// - Parameters:
    ///   - context: The context of the span.
    ///   - tracer: The tracer that made the span.
    /// - Returns: `nil` when the tracer injects no valid `traceparent` value.
    public init?(context: ServiceContext, tracer: any Tracer) {
        guard let traceparent = Self.injectedFields(of: context, by: tracer)[Self.traceparentField] else {
            return nil
        }
        self.init(traceparent: traceparent)
    }

    /// Reads the ids from a W3C `traceparent` value.
    ///
    /// - Parameter traceparent: The value, in the format of version `00`: four
    ///   fields of lowercase hexadecimal digits.
    /// - Returns: `nil` when the value does not have that format, when the
    ///   version is `ff`, or when an id is all zeros.
    public init?(traceparent: String) {
        let fields = traceparent
            .split(separator: Self.fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == Field.allCases.count,
              zip(Field.allCases, fields).allSatisfy({ Self.isValid($0, $1) })
        else {
            return nil
        }
        let traceID = fields[Field.traceID.rawValue]
        let spanID = fields[Field.spanID.rawValue]
        guard fields[Field.version.rawValue] != Self.forbiddenVersion,
              !Self.isAllZeros(traceID),
              !Self.isAllZeros(spanID)
        else {
            return nil
        }
        self.traceID = traceID
        self.spanID = spanID
        traceFlags = fields[Field.flags.rawValue]
    }

    /// Gives each value that `tracer` injects for `context`, under its key.
    ///
    /// - Parameters:
    ///   - context: The context that holds the span context.
    ///   - tracer: The tracer that injects the values.
    /// - Returns: The injected values, keyed by their carrier keys. An
    ///   OpenTelemetry tracer gives ``traceparentField`` and, when the trace
    ///   has vendor data, ``tracestateField``.
    public static func injectedFields(of context: ServiceContext, by tracer: any Tracer) -> [String: String] {
        var carrier: [String: String] = [:]
        tracer.inject(context, into: &carrier, using: DictionaryInjector())
        return carrier
    }

    /// Writes the fields of a `traceparent` value of version `00`.
    ///
    /// - Parameters:
    ///   - traceID: The trace id.
    ///   - spanID: The span id.
    ///   - traceFlags: The trace flags.
    /// - Returns: `00-<traceID>-<spanID>-<traceFlags>`, with no check of the
    ///   fields.
    private static func traceparent(traceID: String, spanID: String, traceFlags: String) -> String {
        [writtenVersion, traceID, spanID, traceFlags].joined(separator: String(fieldSeparator))
    }

    /// Whether `text` has the length of `field` and holds only lowercase
    /// hexadecimal digits.
    ///
    /// - Parameters:
    ///   - field: The field.
    ///   - text: The text of the field.
    /// - Returns: Whether the text is valid for the field.
    private static func isValid(_ field: Field, _ text: String) -> Bool {
        text.count == field.length && text.allSatisfy(lowercaseHexDigits.contains)
    }

    /// Whether each digit of `id` is zero.
    ///
    /// - Parameter id: The id.
    /// - Returns: Whether the id is all zeros.
    private static func isAllZeros(_ id: String) -> Bool {
        id.allSatisfy { $0 == zeroDigit }
    }
}

/// Writes each injected value into a dictionary.
private struct DictionaryInjector: Injector {
    /// Writes `value` under `key`.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - key: The key.
    ///   - carrier: The dictionary.
    func inject(_ value: String, forKey key: String, into carrier: inout [String: String]) {
        carrier[key] = value
    }
}

import FoundationModelsExtras
import InMemoryTracing
import Tracing

/// A tracer that records its spans in memory, and injects and extracts the
/// span context as W3C `traceparent` and `tracestate` values, as an
/// OpenTelemetry tracer does.
///
/// An `InMemoryTracer` injects and extracts only its own trace-id and span-id
/// keys. Thus with it, ``SpanIdentity`` finds no ids, the "enter" record of
/// ``TracedCall`` has no `trace.id` and no `span.id`, and no test can prove
/// that a `traceparent` value goes across a process boundary. This tracer
/// keeps the spans in an `InMemoryTracer`, and it gives that tracer ids in the
/// W3C format: 32 and 16 random lowercase hexadecimal digits.
///
/// - `inject` writes `traceparent` as `00-<trace id>-<span id>-<flags>`, and
///   `tracestate` when the context has one. The flags are the flags of the
///   context, or ``SpanIdentity/sampledFlags``.
/// - `extract` reads `traceparent` and `tracestate`. It puts the remote span
///   context, the flags and the `tracestate` value into the context, so that
///   the next span that starts in that context is a child in the same trace.
///   It ignores a `traceparent` value that the W3C format does not allow, and
///   then it also ignores `tracestate`. It ignores a `tracestate` value that
///   the W3C format does not allow.
///
/// ``TelemetryCapture`` binds this tracer by default.
///
/// ```swift
/// let tracer = W3CInMemoryTracer()
/// try await tracer.withSpan("client.request") { span in
///     let meta = tracer.injectedFields(of: span.context)
///     try await server.handle(request, meta: meta)
/// }
/// ```
public struct W3CInMemoryTracer: Tracer {
    /// The count of bits of one hexadecimal digit.
    private static let bitsPerHexDigit = 4

    /// The radix of hexadecimal digits.
    private static let hexRadix = 16

    /// The count of hexadecimal digits of one random 64-bit part of an id.
    private static let hexDigitsPerPart = UInt64.bitWidth / bitsPerHexDigit

    /// The digit that fills a part of an id up to its length.
    private static let paddingDigit: Character = "0"

    /// The in-memory tracer that makes and keeps the spans.
    public let inMemoryTracer: InMemoryTracer

    /// Makes a tracer with no spans, whose ids have the W3C format.
    public init() {
        inMemoryTracer = InMemoryTracer(idGenerator: .init(
            nextTraceID: { Self.randomID(digitCount: SpanIdentity.traceIDLength) },
            nextSpanID: { Self.randomID(digitCount: SpanIdentity.spanIDLength) }
        ))
    }

    /// The spans that ended, in the order of their end.
    public var finishedSpans: [FinishedInMemorySpan] {
        inMemoryTracer.finishedSpans
    }

    /// The spans that started and did not end yet.
    public var activeSpans: [InMemorySpan] {
        inMemoryTracer.activeSpans
    }

    /// Starts a span in the in-memory tracer.
    ///
    /// The span is a child of the span context of `context`, local or remote.
    /// When `context` has no span context, the span starts a new trace.
    ///
    /// - Parameters:
    ///   - operationName: The name of the span.
    ///   - context: The parent context.
    ///   - kind: The kind of the span.
    ///   - instant: The start time.
    ///   - function: The function that starts the span.
    ///   - fileID: The file that starts the span.
    ///   - line: The line that starts the span.
    /// - Returns: The span.
    public func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> InMemorySpan {
        inMemoryTracer.startSpan(
            operationName,
            context: context(),
            ofKind: kind,
            at: instant(),
            function: function,
            file: fileID,
            line: line
        )
    }

    /// Gives the active span that `context` names.
    ///
    /// - Parameter context: The context of the span.
    /// - Returns: The span, or `nil` when no active span has that context.
    public func activeSpan(identifiedBy context: ServiceContext) -> InMemorySpan? {
        inMemoryTracer.activeSpan(identifiedBy: context)
    }

    /// Records a request to flush the spans in the in-memory tracer.
    public func forceFlush() {
        inMemoryTracer.forceFlush()
    }

    /// Writes the span context of `context` into `carrier` as a W3C
    /// `traceparent` value, and the `tracestate` value of `context` when it
    /// has one.
    ///
    /// The tracer writes nothing when `context` has no span context, or when
    /// its ids do not have the W3C format.
    ///
    /// - Parameters:
    ///   - context: The context that holds the span context.
    ///   - carrier: The carrier.
    ///   - injector: The writer of the carrier.
    public func inject<Carrier, Inject: Injector>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let spanContext = context.inMemorySpanContext,
              let identity = SpanIdentity(
                  traceID: spanContext.traceID,
                  spanID: spanContext.spanID,
                  traceFlags: context.w3cTraceFlags ?? SpanIdentity.sampledFlags
              )
        else {
            return
        }
        injector.inject(identity.traceparent, forKey: SpanIdentity.traceparentField, into: &carrier)
        if let traceState = context.w3cTraceState {
            injector.inject(traceState, forKey: SpanIdentity.tracestateField, into: &carrier)
        }
    }

    /// Reads a remote span context from the W3C `traceparent` and
    /// `tracestate` values of `carrier` into `context`.
    ///
    /// The tracer changes nothing when `carrier` has no `traceparent` value,
    /// or when that value does not have the W3C format. Else it replaces the
    /// span context, the trace flags and the `tracestate` value of `context`.
    /// The `tracestate` value becomes `nil` when the carrier has none, or when
    /// it does not have the W3C format.
    ///
    /// - Parameters:
    ///   - carrier: The carrier.
    ///   - context: The context to fill.
    ///   - extractor: The reader of the carrier.
    public func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let traceparent = extractor.extract(key: SpanIdentity.traceparentField, from: carrier),
              let identity = SpanIdentity(traceparent: traceparent)
        else {
            return
        }
        context.inMemorySpanContext = InMemorySpanContext(
            traceID: identity.traceID,
            spanID: identity.spanID,
            parentSpanID: nil
        )
        context.w3cTraceFlags = identity.traceFlags
        context.w3cTraceState = extractor
            .extract(key: SpanIdentity.tracestateField, from: carrier)
            .flatMap { TraceStateFormat.allows($0) ? $0 : nil }
    }

    /// Gives the fields that this tracer injects for `context`, for example
    /// the `_meta` of an outgoing ACP or MCP request.
    ///
    /// - Parameter context: The context that holds the span context.
    /// - Returns: The `traceparent` value, and the `tracestate` value when
    ///   the context has one, keyed by ``SpanIdentity/traceparentField`` and
    ///   ``SpanIdentity/tracestateField``. Empty when the context has no span
    ///   context in the W3C format.
    public func injectedFields(of context: ServiceContext) -> [String: String] {
        SpanIdentity.injectedFields(of: context, by: self)
    }

    /// Extracts a remote span context from `fields`, for example the `_meta`
    /// of an incoming ACP or MCP request.
    ///
    /// - Parameter fields: The fields, keyed by
    ///   ``SpanIdentity/traceparentField`` and
    ///   ``SpanIdentity/tracestateField``.
    /// - Returns: A top-level context with the remote span context, or a
    ///   top-level context with no span context when the fields hold no
    ///   valid `traceparent` value.
    public func extractedContext(from fields: [String: String]) -> ServiceContext {
        var context = ServiceContext.topLevel
        extract(fields, into: &context, using: DictionaryExtractor())
        return context
    }

    /// Gives a random id of lowercase hexadecimal digits that is not all
    /// zeros.
    ///
    /// - Parameter digitCount: The count of digits. A multiple of
    ///   ``hexDigitsPerPart``.
    /// - Returns: The id.
    private static func randomID(digitCount: Int) -> String {
        (0 ..< digitCount / hexDigitsPerPart)
            .map { _ in hexDigits(of: UInt64.random(in: 1 ... .max)) }
            .joined()
    }

    /// Gives `part` as lowercase hexadecimal digits, with leading zeros.
    ///
    /// - Parameter part: The part of an id.
    /// - Returns: ``hexDigitsPerPart`` digits.
    private static func hexDigits(of part: UInt64) -> String {
        let digits = String(part, radix: hexRadix)
        return String(repeating: paddingDigit, count: hexDigitsPerPart - digits.count) + digits
    }
}

extension ServiceContext {
    /// The W3C trace flags of the remote span context that a
    /// ``W3CInMemoryTracer`` extracted, or `nil` when it extracted none.
    ///
    /// A child span keeps the value, because it copies the context of its
    /// parent. The tracer injects these flags, or
    /// ``SpanIdentity/sampledFlags`` when the value is `nil`.
    public var w3cTraceFlags: String? {
        get { self[W3CTraceFlagsKey.self] }
        set { self[W3CTraceFlagsKey.self] = newValue }
    }

    /// The W3C `tracestate` value of the remote span context that a
    /// ``W3CInMemoryTracer`` extracted, or `nil` when it extracted none.
    ///
    /// A child span keeps the value, because it copies the context of its
    /// parent. The tracer injects the value with no change.
    public var w3cTraceState: String? {
        get { self[W3CTraceStateKey.self] }
        set { self[W3CTraceStateKey.self] = newValue }
    }
}

/// The context key of the W3C trace flags.
private enum W3CTraceFlagsKey: ServiceContextKey {
    /// The trace flags: 2 lowercase hexadecimal digits.
    typealias Value = String
}

/// The context key of the W3C `tracestate` value.
private enum W3CTraceStateKey: ServiceContextKey {
    /// The `tracestate` value, as the carrier gave it.
    typealias Value = String
}

/// Reads each extracted value from a dictionary.
private struct DictionaryExtractor: Extractor {
    /// Reads the value under `key`.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - carrier: The dictionary.
    /// - Returns: The value, or `nil` when the dictionary has no such key.
    func extract(key: String, from carrier: [String: String]) -> String? {
        carrier[key]
    }
}

/// The W3C format of a `tracestate` value: a list of up to 32 members,
/// `key=value`, with commas between them and optional spaces or tabs around
/// each member.
///
/// A key is a simple key, or a multi-tenant key `<tenant id>@<system id>`.
/// Each part of a key holds lowercase letters, digits, `_`, `-`, `*` and `/`.
/// A value holds printable ASCII characters other than `,` and `=`. A space at
/// the end of a value is white space around the member.
private enum TraceStateFormat {
    /// The separator of the members of the list.
    private static let memberSeparator: Character = ","

    /// The separator of the key and the value of a member.
    private static let keyValueSeparator: Character = "="

    /// The separator of the tenant id and the system id of a multi-tenant
    /// key.
    private static let tenantSeparator: Character = "@"

    /// The characters of the optional white space around a member.
    private static let optionalWhiteSpace: Set<Character> = [" ", "\t"]

    /// The largest count of members that are not empty.
    private static let memberLimit = 32

    /// The largest count of characters of a simple key.
    private static let simpleKeyLimit = 256

    /// The largest count of characters of the tenant id of a multi-tenant key.
    private static let tenantIDLimit = 241

    /// The largest count of characters of the system id of a multi-tenant key.
    private static let systemIDLimit = 14

    /// The largest count of characters of a value.
    private static let valueLimit = 256

    /// The lowercase letters.
    private static let lowercaseLetters = Set("abcdefghijklmnopqrstuvwxyz")

    /// The decimal digits.
    private static let decimalDigits = Set("0123456789")

    /// The characters that a part of a key may hold.
    private static let keyCharacters = lowercaseLetters.union(decimalDigits).union("_-*/")

    /// The first character of a simple key and of a system id.
    private static let letterStart = lowercaseLetters

    /// The first character of a tenant id.
    private static let tenantStart = lowercaseLetters.union(decimalDigits)

    /// The lowest character that a value may hold: the space.
    private static let lowestValueScalar: Unicode.Scalar = " "

    /// The highest character that a value may hold: the tilde.
    private static let highestValueScalar: Unicode.Scalar = "~"

    /// Whether the W3C format allows `traceState`.
    ///
    /// - Parameter traceState: The `tracestate` value.
    /// - Returns: Whether the value holds 1 to 32 members that are not empty,
    ///   and each member is valid.
    static func allows(_ traceState: String) -> Bool {
        let members = traceState
            .split(separator: memberSeparator, omittingEmptySubsequences: false)
            .map(withoutOptionalWhiteSpace)
            .filter { !$0.isEmpty }
        return (1 ... memberLimit).contains(members.count) && members.allSatisfy(isValidMember)
    }

    /// Removes the optional white space before and after one member.
    ///
    /// - Parameter member: One member of the list, as the split gives it.
    /// - Returns: The member with no space or tab at its start or its end.
    private static func withoutOptionalWhiteSpace(_ member: Substring) -> Substring {
        let head = member.drop(while: optionalWhiteSpace.contains)
        guard let last = head.lastIndex(where: { !optionalWhiteSpace.contains($0) }) else {
            return head[head.endIndex...]
        }
        return head[...last]
    }

    /// Whether `member` is `key=value`, with a valid key and a valid value.
    ///
    /// - Parameter member: One member of the list, with no white space around
    ///   it.
    /// - Returns: Whether the member is valid.
    private static func isValidMember(_ member: Substring) -> Bool {
        guard let separator = member.firstIndex(of: keyValueSeparator) else {
            return false
        }
        return isValidKey(member[..<separator]) && isValidValue(member[member.index(after: separator)...])
    }

    /// Whether `key` is a valid simple key or multi-tenant key.
    ///
    /// - Parameter key: The key of a member.
    /// - Returns: Whether the key is valid.
    private static func isValidKey(_ key: Substring) -> Bool {
        guard let separator = key.firstIndex(of: tenantSeparator) else {
            return isValidKeyPart(key, start: letterStart, limit: simpleKeyLimit)
        }
        return isValidKeyPart(key[..<separator], start: tenantStart, limit: tenantIDLimit)
            && isValidKeyPart(key[key.index(after: separator)...], start: letterStart, limit: systemIDLimit)
    }

    /// Whether `part` is a valid part of a key.
    ///
    /// - Parameters:
    ///   - part: The simple key, the tenant id or the system id.
    ///   - start: The characters that the part may start with.
    ///   - limit: The largest count of characters of the part.
    /// - Returns: Whether the part has 1 to `limit` characters, starts with
    ///   a character of `start`, and holds key characters only.
    private static func isValidKeyPart(_ part: Substring, start: Set<Character>, limit: Int) -> Bool {
        guard let first = part.first, part.count <= limit else {
            return false
        }
        return start.contains(first) && part.allSatisfy(keyCharacters.contains)
    }

    /// Whether `value` is a valid value of a member.
    ///
    /// The value does not end with a space, because
    /// ``withoutOptionalWhiteSpace(_:)`` removed each space at the end of the
    /// member.
    ///
    /// - Parameter value: The value of a member.
    /// - Returns: Whether the value has 1 to 256 printable ASCII characters
    ///   other than `,` and `=`.
    private static func isValidValue(_ value: Substring) -> Bool {
        let scalars = value.unicodeScalars
        return !scalars.isEmpty && scalars.count <= valueLimit && scalars.allSatisfy(isValueScalar)
    }

    /// Whether a value may hold `scalar`.
    ///
    /// - Parameter scalar: One character of a value.
    /// - Returns: Whether the character is printable ASCII, and not `,` or
    ///   `=`.
    private static func isValueScalar(_ scalar: Unicode.Scalar) -> Bool {
        (lowestValueScalar ... highestValueScalar).contains(scalar)
            && Character(scalar) != memberSeparator
            && Character(scalar) != keyValueSeparator
    }
}

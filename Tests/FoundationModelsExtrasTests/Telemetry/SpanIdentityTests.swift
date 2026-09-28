import FoundationModelsExtras
import InMemoryTracing
import Testing
import Tracing

/// ``SpanIdentity`` reads the trace id, the span id and the trace flags from a
/// W3C `traceparent` value, writes the same value again, and refuses a value
/// that the W3C format does not allow.
@Suite("SpanIdentity: the ids of a W3C traceparent value")
struct SpanIdentityTests {
    @Test("a valid traceparent gives its trace id, its span id and its trace flags")
    func aValidTraceparentGivesItsIds() throws {
        let identity = try #require(SpanIdentity(traceparent: TraceparentSamples.valid))

        #expect(identity.traceID == TraceparentSamples.traceID)
        #expect(identity.spanID == TraceparentSamples.spanID)
        #expect(identity.traceFlags == TraceparentSamples.notSampledFlags)
    }

    @Test("the traceparent of an identity is the value that it was read from")
    func theTraceparentOfAnIdentityIsItsValue() throws {
        let identity = try #require(SpanIdentity(traceparent: TraceparentSamples.valid))

        #expect(identity.traceparent == TraceparentSamples.valid)
    }

    @Test("an identity made from ids writes the version 00 format, with the sampled flag by default")
    func anIdentityFromIdsWritesTheVersion00Format() throws {
        let identity = try #require(SpanIdentity(traceID: TraceparentSamples.traceID, spanID: TraceparentSamples.spanID))

        #expect(identity.traceFlags == SpanIdentity.sampledFlags)
        #expect(identity.traceparent == "00-\(TraceparentSamples.traceID)-\(TraceparentSamples.spanID)-01")
    }

    @Test("an identity made from ids that the W3C format does not allow is nil")
    func anIdentityFromInvalidIdsIsNil() {
        #expect(SpanIdentity(traceID: TraceparentSamples.traceID.uppercased(), spanID: TraceparentSamples.spanID) == nil)
        #expect(SpanIdentity(traceID: TraceparentSamples.traceID, spanID: TraceparentSamples.spanID, traceFlags: "0") == nil)
    }

    @Test("the carrier keys are the W3C field names")
    func theCarrierKeysAreTheW3CFieldNames() {
        #expect(SpanIdentity.traceparentField == "traceparent")
        #expect(SpanIdentity.tracestateField == "tracestate")
    }

    @Test("the injected fields of a tracer are the keys and values that it injects")
    func theInjectedFieldsAreTheInjectedValues() {
        let tracer = InMemoryTracer()
        var fields: [String: String] = [:]
        tracer.withSpan(TraceparentSamples.spanName) { span in
            fields = SpanIdentity.injectedFields(of: span.context, by: tracer)
        }

        #expect(fields == tracer.performedContextInjections.first?.values)
        #expect(fields.count == Self.inMemoryFieldCount)
    }

    @Test("a tracer that injects no traceparent gives no identity")
    func aTracerWithNoTraceparentGivesNoIdentity() {
        let tracer = InMemoryTracer()
        tracer.withSpan(TraceparentSamples.spanName) { span in
            #expect(SpanIdentity(context: span.context, tracer: tracer) == nil)
        }
    }

    @Test("a traceparent that the W3C format does not allow gives no ids", arguments: TraceparentSamples.invalid)
    func anInvalidTraceparentGivesNoIds(traceparent: String) {
        #expect(SpanIdentity(traceparent: traceparent) == nil)
    }

    /// The count of fields that an in-memory tracer injects: its trace id and
    /// its span id.
    private static let inMemoryFieldCount = 2
}

/// The `traceparent` values of the telemetry tests.
enum TraceparentSamples {
    /// The name of each span that a sample test opens.
    static let spanName = "probe.span"

    /// A trace id in the W3C format.
    static let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

    /// A span id in the W3C format.
    static let spanID = "00f067aa0ba902b7"

    /// The trace flags of a trace that is not sampled.
    static let notSampledFlags = "00"

    /// A valid `traceparent` value with ``traceID``, ``spanID`` and
    /// ``notSampledFlags``.
    static let valid = "00-\(traceID)-\(spanID)-\(notSampledFlags)"

    /// The `traceparent` values that the W3C format does not allow.
    static let invalid = [
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01",
        "00-\(traceID)-\(spanID)",
        "00-\(traceID)-\(spanID)-01-00",
        "00-\(traceID.dropLast())-\(spanID)-01",
        "00-\(traceID)-\(spanID)0-01",
        "00-00000000000000000000000000000000-\(spanID)-01",
        "00-\(traceID)-0000000000000000-01",
        "ff-\(traceID)-\(spanID)-01",
        "00-\(traceID)-\(spanID.dropLast())g-01",
        "",
    ]
}

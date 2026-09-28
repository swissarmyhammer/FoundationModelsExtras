import FoundationModelsExtras
import InMemoryTracing
import TelemetryTestSupport
import Testing
import Tracing

/// ``W3CInMemoryTracer`` records its spans like an `InMemoryTracer`, injects
/// the span context as W3C `traceparent` and `tracestate` values, and extracts
/// those values into a remote span context.
@Suite("W3CInMemoryTracer: records spans and injects and extracts W3C trace context")
struct W3CInMemoryTracerTests {
    /// The name of each child span that a test opens.
    private static let childSpanName = "probe.child"

    /// A `tracestate` value with two list members.
    private static let traceState = "vendor1=opaque1,vendor2@tenant=opaque-2"

    /// The largest count of list members that a `tracestate` value may hold.
    private static let traceStateMemberLimit = 32

    /// The largest count of characters of a simple `tracestate` key.
    private static let traceStateKeyLimit = 256

    /// The largest count of characters of a `tracestate` value.
    private static let traceStateValueLimit = 256

    /// A `tracestate` value with `count` list members.
    ///
    /// - Parameter count: The count of members.
    /// - Returns: The members `key0=value` to `key<count - 1>=value`.
    private static func traceState(memberCount count: Int) -> String {
        (0 ..< count).map { "key\($0)=value" }.joined(separator: ",")
    }

    @Test("inject writes a version 00 traceparent with the ids of the span and the sampled flag, and no tracestate")
    func injectWritesTheTraceparentFormat() throws {
        let tracer = W3CInMemoryTracer()
        let fields = Self.injectedFields(ofSpanOf: tracer)

        let span = try #require(tracer.finishedSpans.first)
        #expect(fields == [SpanIdentity.traceparentField: "00-\(span.traceID)-\(span.spanID)-01"])
        let identity = try #require(SpanIdentity(traceparent: fields[SpanIdentity.traceparentField] ?? ""))
        #expect(identity.traceID == span.traceID)
        #expect(identity.spanID == span.spanID)
    }

    @Test("each root span starts a new trace, with ids in the W3C format")
    func eachRootSpanStartsANewTrace() throws {
        let tracer = W3CInMemoryTracer()
        _ = Self.injectedFields(ofSpanOf: tracer)
        _ = Self.injectedFields(ofSpanOf: tracer)

        let spans = tracer.finishedSpans
        #expect(spans.count == 2)
        #expect(Set(spans.map(\.traceID)).count == spans.count)
        for span in spans {
            #expect(SpanIdentity(traceID: span.traceID, spanID: span.spanID) != nil)
            #expect(span.parentSpanID == nil)
        }
    }

    @Test("inject then extract gives the same trace id, and a span in the extracted context is a child of the injected span")
    func injectThenExtractGivesAChildSpan() throws {
        let tracer = W3CInMemoryTracer()
        let fields = Self.injectedFields(ofSpanOf: tracer)
        let parent = try #require(tracer.finishedSpans.first)

        let extracted = tracer.extractedContext(from: fields)
        #expect(extracted.inMemorySpanContext?.traceID == parent.traceID)
        let child = try Self.childSpan(in: extracted, of: tracer)

        #expect(child.traceID == parent.traceID)
        #expect(child.parentSpanID == parent.spanID)
        #expect(child.spanID != parent.spanID)
    }

    @Test("tracestate and the trace flags go through an extract and an inject with no change")
    func traceStateGoesThroughWithNoChange() throws {
        let tracer = W3CInMemoryTracer()
        let incoming = [
            SpanIdentity.traceparentField: TraceparentSamples.valid,
            SpanIdentity.tracestateField: Self.traceState,
        ]

        let extracted = tracer.extractedContext(from: incoming)
        #expect(extracted.w3cTraceState == Self.traceState)
        #expect(extracted.w3cTraceFlags == TraceparentSamples.notSampledFlags)
        var outgoing: [String: String] = [:]
        tracer.withSpan(Self.childSpanName, context: extracted) { span in
            outgoing = tracer.injectedFields(of: span.context)
        }

        let child = try #require(tracer.finishedSpans.first)
        #expect(outgoing == [
            SpanIdentity.traceparentField: "00-\(TraceparentSamples.traceID)-\(child.spanID)-\(TraceparentSamples.notSampledFlags)",
            SpanIdentity.tracestateField: Self.traceState,
        ])
        #expect(child.parentSpanID == TraceparentSamples.spanID)
    }

    @Test("a traceparent that the W3C format does not allow gives no remote context, and the next span starts a new trace", arguments: TraceparentSamples.invalid)
    func anInvalidTraceparentGivesNoRemoteContext(traceparent: String) throws {
        let tracer = W3CInMemoryTracer()
        let extracted = tracer.extractedContext(from: [
            SpanIdentity.traceparentField: traceparent,
            SpanIdentity.tracestateField: Self.traceState,
        ])

        #expect(extracted.inMemorySpanContext == nil)
        #expect(extracted.w3cTraceState == nil)
        #expect(extracted.w3cTraceFlags == nil)
        let span = try Self.childSpan(in: extracted, of: tracer)
        #expect(span.parentSpanID == nil)
        #expect(span.traceID != TraceparentSamples.traceID)
    }

    @Test("a carrier with no traceparent gives no remote context")
    func aCarrierWithNoTraceparentGivesNoRemoteContext() {
        let tracer = W3CInMemoryTracer()
        let extracted = tracer.extractedContext(from: [SpanIdentity.tracestateField: Self.traceState])

        #expect(extracted.inMemorySpanContext == nil)
        #expect(extracted.w3cTraceState == nil)
    }

    @Test(
        "a tracestate that the W3C format allows is kept as it is",
        arguments: [
            "a=1",
            "vendor@tenant=value-with spaces",
            " a=1 , ,b=2\t",
            "k_-*/=\u{21}\u{7E}",
            "0tenant@system=value",
            traceState(memberCount: traceStateMemberLimit),
            "\(String(repeating: "k", count: traceStateKeyLimit))=value",
            "key=\(String(repeating: "v", count: traceStateValueLimit))",
        ]
    )
    func aValidTraceStateIsKept(traceState: String) {
        let extracted = W3CInMemoryTracer().extractedContext(from: [
            SpanIdentity.traceparentField: TraceparentSamples.valid,
            SpanIdentity.tracestateField: traceState,
        ])

        #expect(extracted.w3cTraceState == traceState)
    }

    @Test(
        "a tracestate that the W3C format does not allow is dropped, and the traceparent is kept",
        arguments: [
            "",
            " , ",
            "novalue",
            "=value",
            "key=",
            "Key=value",
            "key=a=b",
            "key=a\u{7F}",
            "key=caf\u{E9}",
            "@key=value",
            "tenant@=value",
            "key=value,1key=value",
            "\(String(repeating: "k", count: traceStateKeyLimit + 1))=value",
            "key=\(String(repeating: "v", count: traceStateValueLimit + 1))",
            traceState(memberCount: traceStateMemberLimit + 1),
        ]
    )
    func anInvalidTraceStateIsDropped(traceState: String) {
        let extracted = W3CInMemoryTracer().extractedContext(from: [
            SpanIdentity.traceparentField: TraceparentSamples.valid,
            SpanIdentity.tracestateField: traceState,
        ])

        #expect(extracted.inMemorySpanContext?.spanID == TraceparentSamples.spanID)
        #expect(extracted.w3cTraceState == nil)
    }

    @Test("a context whose span ids do not have the W3C format gives no fields")
    func aContextWithNonW3CIdsGivesNoFields() {
        var context = ServiceContext.topLevel
        context.inMemorySpanContext = InMemorySpanContext(traceID: "trace-1", spanID: "span-1", parentSpanID: nil)

        #expect(W3CInMemoryTracer().injectedFields(of: context) == [:])
        #expect(W3CInMemoryTracer().injectedFields(of: .topLevel) == [:])
    }

    @Test("the tracer gives the spans of its in-memory tracer")
    func theTracerGivesTheSpansOfItsInMemoryTracer() throws {
        let tracer = W3CInMemoryTracer()
        let span = tracer.startSpan(TraceparentSamples.spanName, context: .topLevel)

        #expect(tracer.activeSpans.map(\.spanContext) == [span.spanContext])
        #expect(tracer.activeSpan(identifiedBy: span.context)?.spanContext == span.spanContext)
        span.end()
        #expect(tracer.activeSpans.isEmpty)
        #expect(tracer.finishedSpans.map(\.spanContext) == [span.spanContext])
        #expect(tracer.inMemoryTracer.finishedSpans.map(\.spanContext) == [span.spanContext])
        tracer.forceFlush()
        #expect(tracer.inMemoryTracer.numberOfForceFlushes == 1)
    }

    @Test("TelemetryCapture binds a W3C tracer, so the global tracer injects a traceparent")
    func theCaptureBindsAW3CTracer() async throws {
        let fields = try await TelemetryCapture.run(forbidding: []) { context in
            let fields = Self.injectedFields(ofSpanOf: InstrumentationSystem.tracer, injectingWith: context.tracer)
            #expect(context.spans.count == 1)
            return fields
        }

        #expect(SpanIdentity(traceparent: fields[SpanIdentity.traceparentField] ?? "") != nil)
    }

    /// Opens and ends one root span, and gives the fields that `tracer`
    /// injects for it.
    ///
    /// - Parameter tracer: The tracer of the span.
    /// - Returns: The injected fields.
    private static func injectedFields(ofSpanOf tracer: W3CInMemoryTracer) -> [String: String] {
        injectedFields(ofSpanOf: tracer, injectingWith: tracer)
    }

    /// Opens and ends one root span with `spanTracer`, and gives the fields
    /// that `tracer` injects for it.
    ///
    /// - Parameters:
    ///   - spanTracer: The tracer that opens the span.
    ///   - tracer: The tracer that injects the span context.
    /// - Returns: The injected fields.
    private static func injectedFields(ofSpanOf spanTracer: any Tracer, injectingWith tracer: W3CInMemoryTracer) -> [String: String] {
        var fields: [String: String] = [:]
        spanTracer.withSpan(TraceparentSamples.spanName, context: .topLevel) { span in
            fields = tracer.injectedFields(of: span.context)
        }
        return fields
    }

    /// Opens and ends one span in `context`, and gives the finished span.
    ///
    /// - Parameters:
    ///   - context: The parent context of the span.
    ///   - tracer: The tracer of the span.
    /// - Returns: The finished span.
    /// - Throws: An error when the tracer recorded no span of that name.
    private static func childSpan(in context: ServiceContext, of tracer: W3CInMemoryTracer) throws -> FinishedInMemorySpan {
        tracer.withSpan(childSpanName, context: context) { _ in }
        return try #require(tracer.finishedSpans.last { $0.operationName == childSpanName })
    }
}

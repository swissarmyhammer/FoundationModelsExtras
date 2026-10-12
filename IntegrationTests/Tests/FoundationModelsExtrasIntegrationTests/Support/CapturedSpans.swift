import InMemoryTracing
import Testing

/// The queries that a test makes on the spans of one `TelemetryCapture`.
///
/// The load telemetry test and the embed telemetry test both find spans by
/// name and by parent, thus the queries are in this one place.
enum CapturedSpans {
    /// The number of spans with one name that one call of the code under test
    /// opens, when that code opens the span one time.
    static let oneSpanOfEachName = 1

    /// Gives the one span of `spans` that has the name `name`.
    ///
    /// - Parameters:
    ///   - name: The name of the span.
    ///   - spans: The spans of one capture.
    /// - Returns: The span with that name.
    /// - Throws: When `spans` holds no span with that name.
    static func onlySpan(named name: String, in spans: [FinishedInMemorySpan]) throws -> FinishedInMemorySpan {
        let named = spans.filter { $0.operationName == name }
        #expect(named.count == oneSpanOfEachName, "spans named \(name)")
        return try #require(named.first)
    }

    /// Gives the spans of `spans` with the name `name` whose parent is
    /// `parent`.
    ///
    /// - Parameters:
    ///   - name: The name of the child spans.
    ///   - parent: The parent span.
    ///   - spans: The spans of one capture.
    /// - Returns: The child spans, in the order of `spans`: the order of
    ///   their end.
    static func children(
        named name: String, of parent: FinishedInMemorySpan, in spans: [FinishedInMemorySpan]
    ) -> [FinishedInMemorySpan] {
        spans.filter { $0.operationName == name && $0.parentSpanID == parent.spanID }
    }
}

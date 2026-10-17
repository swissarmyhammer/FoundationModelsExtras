import InMemoryTracing
import Testing
import Tracing

/// The queries that a test makes on the spans of one `TelemetryCapture`.
///
/// The load telemetry test, the embed telemetry test and the generate
/// telemetry test all find spans by name and by parent, thus the queries are
/// in this one place.
enum CapturedSpans {
    /// The number of spans with one name that one call of the code under test
    /// opens, when that code opens the span one time.
    static let oneSpanOfEachName = 1

    /// Gives the spans of `spans` that have the name `name`.
    ///
    /// - Parameters:
    ///   - name: The name of the spans.
    ///   - spans: The spans of one capture.
    /// - Returns: The spans with that name, in the order of `spans`: the
    ///   order of their end.
    static func spans(named name: String, in spans: [FinishedInMemorySpan]) -> [FinishedInMemorySpan] {
        spans.filter { $0.operationName == name }
    }

    /// Gives the one span of `spans` that has the name `name`.
    ///
    /// - Parameters:
    ///   - name: The name of the span.
    ///   - spans: The spans of one capture.
    /// - Returns: The span with that name.
    /// - Throws: When `spans` holds no span with that name.
    static func onlySpan(named name: String, in spans: [FinishedInMemorySpan]) throws -> FinishedInMemorySpan {
        let named = Self.spans(named: name, in: spans)
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
        Self.spans(named: name, in: spans).filter { $0.parentSpanID == parent.spanID }
    }
}

extension SpanAttribute {
    /// The value of a 64-bit integer attribute, or `nil` for each other kind
    /// of attribute.
    var integerValue: Int64? {
        guard case .int64(let value) = self else { return nil }
        return value
    }
}

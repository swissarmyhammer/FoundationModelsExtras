@testable import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport
import Testing

/// The shared timer of a model operation: the helper runs the operation,
/// records its duration with the outcome of the operation, and gives back
/// the value or the error of the operation.
@Suite("Model metrics: the duration timer of a model operation records its outcome")
struct ModelMetricsTests {
    /// The model of each operation.
    private static let ref: ModelRef = "org/timed"

    /// The name of the timer of each operation. No production metric has
    /// this name.
    private static let timerLabel = "FoundationModelsExtrasTests.timed"

    /// The value that a successful operation gives.
    private static let value = 7

    /// The count of durations of one operation.
    private static let oneOperation = 1

    /// Runs one operation through the shared timer in a new capture.
    ///
    /// - Parameter operation: The operation.
    /// - Returns: The capture, and the result of the operation.
    /// - Throws: The error of the capture.
    private static func captureOneOperation(
        _ operation: @escaping () throws -> Int
    ) async throws -> (context: TelemetryCapture.Context, result: Result<Int, any Error>) {
        try await TelemetryCapture.run(forbidding: []) { context in
            let start = ContinuousClock.now
            do {
                let value = try await ExtrasTelemetry.timeModelOperation(
                    on: timerLabel, dimensions: ExtrasTelemetry.modelDimensions(of: ref), since: start
                ) { try operation() }
                return (context, .success(value))
            } catch {
                return (context, .failure(error))
            }
        }
    }

    /// Gives the durations of the timer of ``ref`` with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the operation recorded into.
    ///   - outcome: How the operation ended.
    /// - Returns: The duration of each operation in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    private static func durations(in metrics: TestMetrics, outcome: ModelOperationOutcome) throws -> [Int64] {
        try metrics.expectTimer(timerLabel, ModelMetricDimensions.model(ref, outcome: outcome)).values
    }

    @Test("a successful operation gives its value")
    func aSuccessfulOperationGivesItsValue() async throws {
        let (_, result) = try await Self.captureOneOperation { Self.value }

        #expect(try result.get() == Self.value)
    }

    @Test("a successful operation records one duration with the outcome succeeded")
    func aSuccessfulOperationRecordsOneSucceededDuration() async throws {
        let (context, _) = try await Self.captureOneOperation { Self.value }

        #expect(try Self.durations(in: context.metricsFactory, outcome: .succeeded).count == Self.oneOperation)
    }

    @Test("a failed operation gives its error")
    func aFailedOperationGivesItsError() async throws {
        let (_, result) = try await Self.captureOneOperation { throw FakeModelRunError() }

        #expect(throws: FakeModelRunError.self) { try result.get() }
    }

    @Test("a failed operation records one duration with the outcome failed")
    func aFailedOperationRecordsOneFailedDuration() async throws {
        let (context, _) = try await Self.captureOneOperation { throw FakeModelRunError() }

        #expect(try Self.durations(in: context.metricsFactory, outcome: .failed).count == Self.oneOperation)
    }

    @Test("a failed operation records no duration with the outcome succeeded")
    func aFailedOperationRecordsNoSucceededDuration() async throws {
        let (context, _) = try await Self.captureOneOperation { throw FakeModelRunError() }

        #expect(throws: TestMetricsError.self) {
            try Self.durations(in: context.metricsFactory, outcome: .succeeded)
        }
    }
}

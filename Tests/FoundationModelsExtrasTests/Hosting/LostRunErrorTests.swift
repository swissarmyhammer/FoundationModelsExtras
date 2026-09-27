@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing

/// Exercises the map from a thrown error to an ``OperationOutcome``: an error
/// that conforms to ``LostRunError`` settles the run as
/// ``OperationOutcome/lost``, the other maps do not change, and a
/// run-to-completion call still gives the error to its caller.
@Suite("LostRunError: a transport drop settles the run as lost")
struct LostRunErrorTests {
    private typealias Fixtures = MountFixtures

    /// The error of a transport that dropped during a request.
    private struct TransportDropped: LostRunError, Equatable {}

    /// Throws ``TransportDropped``.
    private struct TransportDropTool: Tool {
        let name = "transport_drop_tool"
        let description = "throws a transport-drop error"

        func call(arguments: MountArguments) async throws -> String {
            throw TransportDropped()
        }
    }

    /// Throws `CancellationError` from its own body, with no cancel request.
    private struct CancellingTool: Tool {
        let name = "cancelling_tool"
        let description = "throws a cancellation error of its own"

        func call(arguments: MountArguments) async throws -> String {
            throw CancellationError()
        }
    }

    /// The terminal event of one background call of `tool`.
    private static func terminal(ofBackgroundCallOf tool: any Tool<MountArguments, String>) async throws -> OperationEvent {
        let harness = Fixtures.backgroundHarness(wrapping: tool)
        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        return try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.runPlane)
    }

    @Test("a background run whose body throws a LostRunError settles lost, and the detail holds the error description")
    func lostRunErrorSettlesLost() async throws {
        let terminal = try await Self.terminal(ofBackgroundCallOf: TransportDropTool())

        #expect(terminal.outcome == .lost)
        #expect(terminal.detail == String(describing: TransportDropped()))
    }

    @Test("a background run whose body throws a plain error still settles failed")
    func plainErrorSettlesFailed() async throws {
        let terminal = try await Self.terminal(ofBackgroundCallOf: Fixtures.ThrowingTool())

        #expect(terminal.outcome == .failed)
    }

    @Test("a background run whose body throws CancellationError still settles cancelled")
    func cancellationErrorSettlesCancelled() async throws {
        let terminal = try await Self.terminal(ofBackgroundCallOf: CancellingTool())

        #expect(terminal.outcome == .cancelled)
    }

    @Test("a run-to-completion call whose body throws a LostRunError throws it to the caller")
    func runToCompletionThrowsLostRunErrorOnward() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: TransportDropTool())

        await #expect(throws: TransportDropped.self) {
            try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }
    }
}

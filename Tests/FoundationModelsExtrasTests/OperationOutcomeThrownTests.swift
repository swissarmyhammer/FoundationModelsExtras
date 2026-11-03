import Foundation
import FoundationModelsExtras
import Testing

/// ``OperationOutcome/init(thrown:)``: the outcome of a call that threw.
@Suite("OperationOutcome(thrown:): the outcome of an error that a call threw")
struct OperationOutcomeThrownTests {
    /// An error that says the run is lost.
    private struct DroppedTransport: LostRunError {}

    /// An error that no rule names.
    private struct OtherError: Error {}

    @Test("a CancellationError is cancelled")
    func cancellationIsCancelled() {
        #expect(OperationOutcome(thrown: CancellationError()) == .cancelled)
    }

    @Test("the timeout of a mounted call is timedOut")
    func theMountTimeoutIsTimedOut() {
        let timeout = ToolMountError.timedOut(tool: "slow", timeoutSeconds: 1)

        #expect(OperationOutcome(thrown: timeout) == .timedOut)
    }

    @Test("a LostRunError is lost")
    func aLostRunErrorIsLost() {
        #expect(OperationOutcome(thrown: DroppedTransport()) == .lost)
    }

    @Test("each other error is failed")
    func anyOtherErrorIsFailed() {
        #expect(OperationOutcome(thrown: OtherError()) == .failed)
    }
}

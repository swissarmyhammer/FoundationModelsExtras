import FoundationModelsExtras
import Testing

/// ``RaceGate``: a rendezvous that resumes its continuation exactly one time,
/// whether the competitor resolves the race before or after the continuation
/// registers. FoundationModelsRouter had no test of its own for the type; these
/// tests came with the move (decision 2026-09-26).
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees.
@Suite("RaceGate")
struct RaceGateTests {
    /// The value the first competitor resolves the race with.
    private static let firstValue = 3

    /// The value a later competitor offers after the race is resolved.
    private static let laterValue = 5

    /// How many times the race test races a registration against a resolve.
    private static let raceRepetitions = 300

    @Test("a resolve before the registration resumes the continuation when it registers")
    func aResolveBeforeTheRegistrationResumesAtRegistration() async {
        let gate = RaceGate<Int>()

        gate.resume(with: Self.firstValue)
        let value = await withCheckedContinuation { gate.register(continuation: $0) }

        #expect(value == Self.firstValue)
    }

    @Test("a resolve after the registration resumes the registered continuation")
    func aResolveAfterTheRegistrationResumesIt() async {
        let gate = RaceGate<Int>()
        let registered = AsyncSemaphore(value: 0)

        let waiter = Task {
            await withCheckedContinuation { continuation in
                gate.register(continuation: continuation)
                registered.signal()
            }
        }
        let arrived = await BoundedWait.signalArrived(registered, named: "the continuation registered")
        gate.resume(with: Self.firstValue)

        #expect(arrived)
        #expect(await waiter.value == Self.firstValue)
    }

    @Test("only the first resolve counts; each later resolve is a no-op")
    func onlyTheFirstResolveCounts() async {
        let gate = RaceGate<Int>()

        gate.resume(with: Self.firstValue)
        gate.resume(with: Self.laterValue)
        let value = await withCheckedContinuation { gate.register(continuation: $0) }
        gate.resume(with: Self.laterValue)

        #expect(value == Self.firstValue)
    }

    @Test("a registration that races a resolve resumes one time with the value")
    func aRegistrationThatRacesAResolveResumesOneTime() async {
        for _ in 0..<Self.raceRepetitions {
            let gate = RaceGate<Int>()

            async let value = withCheckedContinuation { gate.register(continuation: $0) }
            let resolver = Task { gate.resume(with: Self.firstValue) }
            await resolver.value

            #expect(await value == Self.firstValue)
        }
    }
}

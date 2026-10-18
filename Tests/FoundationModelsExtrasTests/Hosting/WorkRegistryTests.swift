@testable import FoundationModelsExtras
import Foundation
import Logging
import Testing
import TelemetryTestSupport
import ULID

/// Exercises the ``WorkRegistry`` of one session and the ``BackgroundWork``
/// leases in it: the transitions between work and no work, the end of a
/// lease, a lease that is freed with no end, the suspend of a lease, the
/// snapshot, the wait for no work, and the close.
///
/// Each test closes its registry before it reads the transitions. The close
/// ends each stream, thus a read of the transitions never hangs.
@Suite("Work registry: one set of leases for each session, and its transitions")
struct WorkRegistryTests {
    /// The kind of each test lease.
    private static let kind = WorkKind("test.work")

    /// Closes `registry`, and gives each transition that `stream` got.
    ///
    /// - Parameters:
    ///   - registry: The registry. This function closes it.
    ///   - stream: The transitions of `registry`.
    /// - Returns: The transitions, in order.
    private static func closeAndCollect(
        _ registry: WorkRegistry, _ stream: AsyncStream<WorkTransition>
    ) async -> [WorkTransition] {
        registry.close()
        var transitions: [WorkTransition] = []
        for await transition in stream {
            transitions.append(transition)
        }
        return transitions
    }

    // MARK: - Transitions

    @Test("the first lease gives workStarted one time, and the end of the last lease gives noWork one time")
    func theFirstAndTheLastLeaseGiveOneTransitionEach() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()

        let first = registry.begin(Self.kind, id: "a")
        let second = registry.begin(Self.kind, id: "b")
        #expect(registry.hasWork)
        first.end()
        #expect(registry.hasWork)
        second.end()
        #expect(!registry.hasWork)

        #expect(await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork])
    }

    @Test("many concurrent leases under one held lease give no transition of their own")
    func concurrentLeasesUnderAHeldLeaseGiveNoTransition() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()
        let held = registry.begin(Self.kind, id: "held")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<1_000 {
                group.addTask {
                    let lease = registry.begin(Self.kind, id: "\(index)")
                    await Task.yield()
                    lease.end()
                }
            }
        }
        held.end()

        #expect(await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork])
    }

    @Test("many concurrent begins and ends give transitions that alternate, start with workStarted and end with noWork")
    func concurrentBeginsAndEndsAlternate() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<2_000 {
                group.addTask {
                    let lease = registry.begin(Self.kind, id: "\(index)")
                    if index.isMultiple(of: 3) { await Task.yield() }
                    lease.end()
                }
            }
        }

        let transitions = await Self.closeAndCollect(registry, stream)
        #expect(transitions.first == .workStarted)
        #expect(transitions.last == .noWork)
        for (index, transition) in transitions.enumerated() {
            #expect(transition == (index.isMultiple(of: 2) ? .workStarted : .noWork))
        }
        #expect(registry.openWork.isEmpty)
    }

    @Test("each subscriber gets each transition")
    func eachSubscriberGetsEachTransition() async {
        let registry = WorkRegistry(sessionID: ULID())
        let first = registry.transitions()
        let second = registry.transitions()

        registry.begin(Self.kind, id: "a").end()

        registry.close()
        var firstTransitions: [WorkTransition] = []
        for await transition in first { firstTransitions.append(transition) }
        var secondTransitions: [WorkTransition] = []
        for await transition in second { secondTransitions.append(transition) }
        #expect(firstTransitions == [.workStarted, .noWork])
        #expect(secondTransitions == [.workStarted, .noWork])
    }

    @Test("a stream that includes the current state starts with it")
    func aStreamThatIncludesTheCurrentStateStartsWithIt() async {
        let registry = WorkRegistry(sessionID: ULID())
        let idle = registry.transitions(includingCurrent: true)
        let lease = registry.begin(Self.kind, id: "a")
        let busy = registry.transitions(includingCurrent: true)
        lease.end()

        registry.close()
        var idleTransitions: [WorkTransition] = []
        for await transition in idle { idleTransitions.append(transition) }
        var busyTransitions: [WorkTransition] = []
        for await transition in busy { busyTransitions.append(transition) }
        #expect(idleTransitions == [.noWork, .workStarted, .noWork])
        #expect(busyTransitions == [.workStarted, .noWork])
    }

    // MARK: - The end of a lease

    @Test("a second end of a lease does nothing")
    func aSecondEndDoesNothing() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()
        let lease = registry.begin(Self.kind, id: "a")
        let other = registry.begin(Self.kind, id: "b")

        lease.end()
        lease.end()
        #expect(lease.isEnded)
        #expect(registry.hasWork)
        #expect(registry.openWork.map(\.id) == ["b"])
        other.end()
        other.end()

        #expect(await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork])
    }

    @Test("a lease that is freed with no end leaves the registry and writes a warning")
    func aFreedLeaseEndsAndWarns() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let registry = WorkRegistry(sessionID: ULID())
            let stream = registry.transitions()

            do {
                _ = registry.begin(Self.kind, id: "leaked")
            }

            #expect(!registry.hasWork)
            #expect(await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork])
            let warnings = context.logRecords.filter {
                $0.level == .warning && "\($0.message)" == BackgroundWork.freedWithNoEndMessage
            }
            #expect(warnings.count == 1)
            #expect(warnings.first?.metadata[ExtrasTelemetry.LogMetadataKey.workKind] == "\(Self.kind.rawValue)")
        }
    }

    @Test("a lease that ends writes no warning when it is freed")
    func anEndedLeaseWritesNoWarning() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let registry = WorkRegistry(sessionID: ULID())
            do {
                registry.begin(Self.kind, id: "a").end()
            }
            #expect(!context.logRecords.contains { "\($0.message)" == BackgroundWork.freedWithNoEndMessage })
        }
    }

    @Test("withWork holds a lease for its body and ends it also when the body throws")
    func withWorkEndsTheLeaseAlsoOnAThrow() async {
        struct Failure: Error {}
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()

        let held = await registry.withWork(Self.kind, id: "a") { registry.hasWork }
        let thrown = await #expect(throws: Failure.self) {
            try await registry.withWork(Self.kind, id: "b") { () async throws -> Void in throw Failure() }
        }

        #expect(held)
        #expect(thrown != nil)
        #expect(!registry.hasWork)
        #expect(
            await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork, .workStarted, .noWork])
    }

    // MARK: - Suspend

    @Test("a suspended lease is not work, and a resume makes it work again")
    func aSuspendedLeaseIsNotWork() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()
        let lease = registry.begin(Self.kind, id: "a")

        lease.suspend()
        lease.suspend()
        #expect(!registry.hasWork)
        #expect(registry.openWork.isEmpty)
        lease.resume()
        lease.resume()
        #expect(registry.hasWork)
        lease.suspend()
        lease.end()
        lease.resume()
        #expect(!registry.hasWork)

        #expect(
            await Self.closeAndCollect(registry, stream) == [.workStarted, .noWork, .workStarted, .noWork])
    }

    // MARK: - The snapshot

    @Test("the snapshot gives the kind, the id and the session of each open lease, in begin order")
    func theSnapshotGivesEachOpenLease() {
        let sessionID = ULID()
        let registry = WorkRegistry(sessionID: sessionID)
        let first = registry.begin(.backgroundRun, id: "run")
        let second = registry.begin(.mcpCall, id: "call")

        #expect(
            registry.openWork == [
                WorkItem(kind: .backgroundRun, id: "run", sessionID: sessionID),
                WorkItem(kind: .mcpCall, id: "call", sessionID: sessionID),
            ])
        #expect(first.sessionID == sessionID)
        #expect(first.kind == .backgroundRun)
        #expect(first.id == "run")

        first.end()
        second.end()
        #expect(registry.openWork.isEmpty)
    }

    @Test("a kind is open: a host can make its own kind, and a kind keeps its raw value")
    func aKindIsOpen() throws {
        let kind: WorkKind = "router.generation"

        #expect(kind == WorkKind(rawValue: "router.generation"))
        #expect(kind.rawValue == "router.generation")
        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(WorkKind.self, from: data) == kind)
        let wellKnown: Set<WorkKind> = [
            .backgroundRun, .shellCommand, .innerCall, .noticeDelivery, .mcpCall, .childSession,
        ]
        #expect(wellKnown.count == 6)
    }

    // MARK: - Sessions

    @Test("the leases of one session never reach the registry of another session")
    func registriesAreIndependent() async {
        let parent = WorkRegistry(sessionID: ULID())
        let child = WorkRegistry(sessionID: ULID())
        let parentStream = parent.transitions()
        let childStream = child.transitions()

        let childLease = child.begin(Self.kind, id: "child")
        #expect(!parent.hasWork)
        #expect(parent.openWork.isEmpty)
        childLease.end()

        #expect(await Self.closeAndCollect(parent, parentStream) == [])
        #expect(await Self.closeAndCollect(child, childStream) == [.workStarted, .noWork])
    }

    // MARK: - The wait for no work

    @Test("awaitNoWork returns at once with no work, and else when the last lease ends")
    func awaitNoWorkReturnsWhenTheLastLeaseEnds() async {
        let registry = WorkRegistry(sessionID: ULID())
        await registry.awaitNoWork()

        let lease = registry.begin(Self.kind, id: "a")
        let waiter = Task { await registry.awaitNoWork() }
        await registry.waitForNoWorkWaiters(atLeast: 1)
        lease.end()
        await waiter.value
        #expect(!registry.hasWork)
    }

    @Test("a cancel of the task ends awaitNoWork")
    func aCancelEndsAwaitNoWork() async {
        let registry = WorkRegistry(sessionID: ULID())
        let lease = registry.begin(Self.kind, id: "a")
        let waiter = Task { await registry.awaitNoWork() }
        await registry.waitForNoWorkWaiters(atLeast: 1)

        waiter.cancel()
        await waiter.value

        #expect(registry.hasWork)
        lease.end()
    }

    // MARK: - The close

    @Test("after the close the registry gives no transition, and a new lease is not work")
    func afterTheCloseNoTransition() async {
        let registry = WorkRegistry(sessionID: ULID())
        let stream = registry.transitions()
        let open = registry.begin(Self.kind, id: "open")

        registry.close()
        open.end()
        let late = registry.begin(Self.kind, id: "late")
        #expect(!registry.hasWork)
        late.end()
        let lateStream = registry.transitions()

        #expect(registry.isClosed)
        var transitions: [WorkTransition] = []
        for await transition in stream { transitions.append(transition) }
        #expect(transitions == [.workStarted])
        var lateTransitions: [WorkTransition] = []
        for await transition in lateStream { lateTransitions.append(transition) }
        #expect(lateTransitions.isEmpty)
    }

    @Test("the close ends each awaitNoWork")
    func theCloseEndsAwaitNoWork() async {
        let registry = WorkRegistry(sessionID: ULID())
        let lease = registry.begin(Self.kind, id: "a")
        let waiter = Task { await registry.awaitNoWork() }
        await registry.waitForNoWorkWaiters(atLeast: 1)

        registry.close()
        await waiter.value
        await registry.awaitNoWork()
        lease.end()
    }
}

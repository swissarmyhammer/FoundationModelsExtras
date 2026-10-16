import FoundationModelsExtras
import Synchronization
import Testing

/// Behavioral tests for `DoctorRunner`: the
/// concurrent collection of the checks of every applicable component, and the
/// stable registration order of the result.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor runner") struct DoctorRunnerTests {

    // MARK: - The manual drive of the concurrency tests

    /// A task executor that runs no job by itself. It keeps each job that it
    /// gets in a queue, and the test runs the jobs one at a time.
    ///
    /// A task with a preference for this executor sends its jobs here, and so
    /// does each child task, because a child inherits the preference. A
    /// default actor that such a task calls runs on the preferred executor
    /// too, and a continuation resumes the task through that actor. Thus each
    /// step of the run is a job in this queue. When the queue is empty, no
    /// step can run until a job that is not in the queue resumes a waiter.
    private final class ManualTaskExecutor: TaskExecutor {
        /// The jobs that wait to run, oldest first.
        private let jobs = Mutex<[UnownedJob]>([])

        /// Keeps `job` until ``runEachJob()`` runs it.
        ///
        /// - Parameter job: The job to keep.
        func enqueue(_ job: consuming ExecutorJob) {
            let unownedJob = UnownedJob(job)
            jobs.withLock { $0.append(unownedJob) }
        }

        /// Runs the jobs on the current thread, oldest first, until the
        /// queue is empty. A job that a job enqueues runs in the same call.
        func runEachJob() {
            while let job = takeOldestJob() {
                job.runSynchronously(on: asUnownedTaskExecutor())
            }
        }

        /// Removes and gives the oldest job, or `nil` when the queue is empty.
        ///
        /// - Returns: The oldest job, or `nil`.
        private func takeOldestJob() -> UnownedJob? {
            jobs.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    /// Runs `operation` on a ``ManualTaskExecutor``, and breaks a deadlock
    /// with `breakDeadlock` when the run stops before its end.
    ///
    /// The function runs each job of the run until the queue is empty. When
    /// `operation` did not return then, each of its steps waits for a step
    /// that never comes: a serial run is in a deadlock. The function then
    /// records that, runs `breakDeadlock` on the same executor, and runs the
    /// jobs again until `operation` returns. No clock is read: the empty
    /// queue is the event that shows the deadlock.
    ///
    /// - Parameters:
    ///   - operation: The run to drive.
    ///   - breakDeadlock: Resumes each component that waits.
    /// - Returns: The value of `operation`, and whether the run was in a
    ///   deadlock that `breakDeadlock` had to break.
    /// - Throws: An `ExpectationFailedError` when the run did not end after
    ///   the break.
    private static func drive<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value,
        breakingADeadlockWith breakDeadlock: @escaping @Sendable () async -> Void
    ) async throws -> (value: Value, didFire: Bool) {
        let executor = ManualTaskExecutor()
        let result = Mutex<Value?>(nil)
        let running = Task(executorPreference: executor) {
            let value = await operation()
            result.withLock { $0 = value }
        }
        executor.runEachJob()

        let didFire = result.withLock { $0 == nil }
        let breaking = Task(executorPreference: executor) {
            if didFire { await breakDeadlock() }
        }
        executor.runEachJob()

        // Each await below is of a task whose last job ran already, thus no
        // await waits for a job that nothing runs.
        let value = try #require(result.withLock { $0 }, "the run did not end after the break of its deadlock")
        await breaking.value
        await running.value
        return (value, didFire)
    }

    /// Runs `runner` with ``drive(_:breakingADeadlockWith:)``.
    ///
    /// - Parameters:
    ///   - runner: The runner to run.
    ///   - breakDeadlock: Resumes each component that waits.
    /// - Returns: The report, and whether the run was in a deadlock.
    /// - Throws: An `ExpectationFailedError` when the run did not end after
    ///   the break.
    private static func run(
        _ runner: DoctorRunner, breakingADeadlockWith breakDeadlock: @escaping @Sendable () async -> Void
    ) async throws -> (report: DoctorReport, didFire: Bool) {
        let (report, didFire) = try await drive({ await runner.run() }, breakingADeadlockWith: breakDeadlock)
        return (report, didFire)
    }

    /// How many components the barrier test registers.
    private static let barrierPartyCount = 10

    // MARK: - The handoff between two components

    /// A one-shot flag two tasks share, so one component can hand control to
    /// another without a poll loop.
    ///
    /// ``wait()`` returns at once when ``signal()`` already ran, so a signal
    /// that lands before the wait is never lost. That is what makes the handoff
    /// safe in both directions: neither of the two components has to start
    /// before the other.
    private actor Signal {
        /// Whether ``signal()`` already ran.
        private var isSignaled = false

        /// The one suspended ``wait()``, while a caller is waiting.
        private var waiter: CheckedContinuation<Void, Never>?

        /// Suspends until ``signal()`` runs, or returns at once when it already
        /// ran.
        func wait() async {
            guard !isSignaled else { return }
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }

        /// Sets the flag, and resumes the stored ``wait()`` when there is one.
        func signal() {
            isSignaled = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// A rendezvous point where a fixed number of parties suspend in
    /// ``arrive()`` until every one of them has arrived, then all resume
    /// together.
    ///
    /// A serial runner can never fill the barrier: the first party's
    /// ``arrive()`` never resumes, because the runner never starts the
    /// second party while the first is still suspended. That makes the
    /// barrier a proof of concurrency that needs no wall-clock reading, only
    /// the manual drive to break the deadlock a serial runner leaves behind.
    private actor Barrier {
        /// How many parties this barrier waits for.
        private let partyCount: Int

        /// How many parties have arrived so far.
        private var arrivedCount = 0

        /// The parties still suspended in ``arrive()``.
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Whether ``release()`` ran. A released barrier stays open.
        private var isReleased = false

        init(partyCount: Int) {
            self.partyCount = partyCount
        }

        /// Suspends until every party has called ``arrive()``, then resumes
        /// every one of them. Returns at once when the barrier is open.
        func arrive() async {
            arrivedCount += 1
            guard !isReleased else { return }
            if arrivedCount >= partyCount {
                release()
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        /// Opens the barrier for good, and resumes every suspended party at
        /// once, whether or not the full count arrived. The manual drive
        /// calls this to break a deadlock left by a serial runner. The
        /// barrier stays open, thus each later party of a serial runner
        /// passes too, and one break ends the run.
        func release() {
            isReleased = true
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    // MARK: - The stand-in component

    /// What a ``StandInComponent`` does before it reports its finding.
    private enum ComponentBehavior: Sendable {
        /// Reports at once.
        case reportsAtOnce

        /// Waits until the signal is set, then reports.
        case waitsFor(Signal)

        /// Sets the signal, then reports.
        case sets(Signal)

        /// Arrives at the barrier, then reports.
        case arrivesAt(Barrier)

        /// Performs the wait this behavior states.
        func perform() async {
            switch self {
            case .reportsAtOnce:
                break
            case .waitsFor(let signal):
                await signal.wait()
            case .sets(let signal):
                await signal.signal()
            case .arrivesAt(let barrier):
                await barrier.arrive()
            }
        }
    }

    /// A component that reports one finding the test chose, after the wait the
    /// test chose.
    ///
    /// One stand-in covers every scenario in this file — a component that does
    /// not apply, a slow one, a broken one, and the two halves of the handoff —
    /// so the file states one component type and not five.
    private struct StandInComponent: Doctorable {
        /// What this component is called in the report.
        let doctorName: String

        /// Which group its finding belongs to.
        var doctorCategory = DoctorTestSupport.findingCategory

        /// Whether the runner reads this component at all.
        var isApplicable = true

        /// The level the finding of this component reports.
        var status: HealthStatus = .ok

        /// What this component does before it reports.
        var behavior: ComponentBehavior = .reportsAtOnce

        /// Waits as ``behavior`` states, then reports one finding at
        /// ``status``.
        ///
        /// - Returns: One finding named ``doctorName``.
        func runHealthChecks() async -> [HealthCheck] {
            await behavior.perform()
            return [DoctorTestSupport.finding(status, name: doctorName)]
        }
    }

    // MARK: - An empty run

    @Test func `an empty run gives an empty report that exits zero`() async {
        let report = await DoctorRunner(components: []).run()
        #expect(report.checks.isEmpty)
        #expect(report.worstStatus == .ok)
        #expect(report.exitCode == DoctorTestSupport.passingExitCode)
    }

    // MARK: - A component that does not apply

    @Test func `a component that does not apply reports nothing and stays registered`() async {
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "off", isApplicable: false),
            StandInComponent(doctorName: "on"),
        ])

        let report = await runner.run()

        #expect(runner.components.map(\.doctorName) == ["off", "on"])
        #expect(report.checks.map(\.name) == ["on"])
        #expect(report.exitCode == DoctorTestSupport.passingExitCode)
    }

    // MARK: - One broken component does not stop the others

    @Test func `a component that reports only errors does not stop the other components`() async {
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "broken", status: .error),
            StandInComponent(doctorName: "healthy"),
        ])

        let report = await runner.run()

        #expect(report.checks.map(\.name) == ["broken", "healthy"])
        #expect(report.checks.map(\.status) == [.error, .ok])
        #expect(report.exitCode == DoctorTestSupport.brokenExitCode)
    }

    // MARK: - The components run at the same time

    /// The first component reports only after the second one has run, so the
    /// run can finish at all only when the two run at the same time. The
    /// first component ends last, thus the test also shows that the report
    /// keeps the registration order when the first component is slow.
    ///
    /// The manual drive of ``run(_:breakingADeadlockWith:)`` is what makes a
    /// serial runner **fail** and not hang.
    @Test func `one slow component does not hold back the others`() async throws {
        let signal = Signal()
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "waiting", behavior: .waitsFor(signal)),
            StandInComponent(doctorName: "signalling", behavior: .sets(signal)),
        ])

        let (report, didFire) = try await Self.run(runner) { await signal.signal() }

        #expect(didFire == false)
        #expect(report.checks.map(\.name) == ["waiting", "signalling"])
    }

    /// N components finish only when the runner starts every one of them at
    /// the same time: each blocks in a shared ``Barrier`` until all N have
    /// arrived, so a serial runner — which never starts component 2 before
    /// component 1 returns — deadlocks instead of finishing.
    ///
    /// The manual drive breaks that deadlock the same way it does in ``one
    /// slow component does not hold back the others``, so a serial runner
    /// fails this test instead of hanging.
    @Test func `components that each wait for the others finish only when the runner starts them all at once`()
        async throws
    {
        let barrier = Barrier(partyCount: Self.barrierPartyCount)
        let components = (1...Self.barrierPartyCount).map { position in
            StandInComponent(doctorName: "sleeper-\(position)", behavior: .arrivesAt(barrier))
        }

        let (report, didFire) = try await Self.run(DoctorRunner(components: components)) { await barrier.release() }

        #expect(didFire == false)
        #expect(report.checks.count == Self.barrierPartyCount)
    }

    /// The proof that the manual drive can fail the two tests above. A run
    /// that asks the components one after the other, as a serial runner
    /// does, never fills the barrier. The drive must find that deadlock when
    /// the queue is empty, break it, and give the full report.
    @Test func `the manual drive finds the deadlock of a serial run and breaks it`() async throws {
        let barrier = Barrier(partyCount: Self.barrierPartyCount)
        let components = (1...Self.barrierPartyCount).map { position in
            StandInComponent(doctorName: "sleeper-\(position)", behavior: .arrivesAt(barrier))
        }

        let (checks, didFire) = try await Self.drive(
            {
                var checks: [HealthCheck] = []
                for component in components {
                    checks += await component.runHealthChecks()
                }
                return checks
            },
            breakingADeadlockWith: { await barrier.release() })

        #expect(didFire)
        #expect(checks.count == Self.barrierPartyCount)
    }
}

import FoundationModelsExtras
import Testing

/// Behavioral tests for `DoctorRunner`: the
/// concurrent collection of the checks of every applicable component, and the
/// stable registration order of the result.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor runner") struct DoctorRunnerTests {

    // MARK: - The watchdog of the concurrency tests

    /// How long the watchdog waits before it declares the runner serial. Far
    /// longer than a concurrent runner needs, so a slow machine never fires it.
    ///
    /// A serial runner leaves the components in a deadlock that gives no
    /// event, thus only this deadline can end the run of such a runner. A
    /// concurrent runner ends the run before the deadline, and the watchdog
    /// is then cancelled.
    private static let watchdogPatience: Duration = .seconds(5)

    /// Runs `runner`, and breaks a deadlock with `breakDeadlock` when the run
    /// does not end inside ``watchdogPatience``.
    ///
    /// The watchdog sets its flag before it breaks the deadlock, so the flag
    /// already stands when the deadlocked run resumes. The function awaits
    /// the watchdog after the run, thus the reading is deterministic in both
    /// cases.
    ///
    /// - Parameters:
    ///   - runner: The runner to run.
    ///   - breakDeadlock: Resumes each component that waits.
    /// - Returns: The report, and whether the watchdog had to break a
    ///   deadlock.
    private static func run(
        _ runner: DoctorRunner, breakingADeadlockWith breakDeadlock: @escaping @Sendable () async -> Void
    ) async -> (report: DoctorReport, didFire: Bool) {
        let watchdogFlag = WatchdogFlag()
        let watchdog = Task {
            do {
                try await Task.sleep(for: watchdogPatience)
            } catch {
                return
            }
            await watchdogFlag.fire()
            await breakDeadlock()
        }

        let report = await runner.run()
        watchdog.cancel()
        await watchdog.value

        return (report, await watchdogFlag.didFire)
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

    /// The reading the watchdog leaves behind, so a test can tell whether the
    /// watchdog had to break a deadlock.
    private actor WatchdogFlag {
        /// Whether the watchdog ran out of patience.
        private(set) var didFire = false

        /// Records that the watchdog ran out of patience.
        func fire() {
            didFire = true
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
    /// the watchdog to break the deadlock a serial runner leaves behind.
    private actor Barrier {
        /// How many parties this barrier waits for.
        private let partyCount: Int

        /// How many parties have arrived so far.
        private var arrivedCount = 0

        /// The parties still suspended in ``arrive()``.
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(partyCount: Int) {
            self.partyCount = partyCount
        }

        /// Suspends until every party has called ``arrive()``, then resumes
        /// every one of them.
        func arrive() async {
            arrivedCount += 1
            if arrivedCount >= partyCount {
                release()
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        /// Resumes every suspended party at once, whether or not the full
        /// count arrived. The watchdog calls this to break a deadlock left
        /// by a serial runner.
        func release() {
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
    /// The watchdog of ``run(_:breakingADeadlockWith:)`` is what makes a
    /// serial runner **fail** and not hang.
    @Test func `one slow component does not hold back the others`() async {
        let signal = Signal()
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "waiting", behavior: .waitsFor(signal)),
            StandInComponent(doctorName: "signalling", behavior: .sets(signal)),
        ])

        let (report, didFire) = await Self.run(runner) { await signal.signal() }

        #expect(didFire == false)
        #expect(report.checks.map(\.name) == ["waiting", "signalling"])
    }

    /// N components finish only when the runner starts every one of them at
    /// the same time: each blocks in a shared ``Barrier`` until all N have
    /// arrived, so a serial runner — which never starts component 2 before
    /// component 1 returns — deadlocks instead of finishing.
    ///
    /// The watchdog breaks that deadlock the same way it does in ``one slow
    /// component does not hold back the others``, so a serial runner fails
    /// this test instead of hanging.
    @Test func `components that each wait for the others finish only when the runner starts them all at once`() async {
        let barrier = Barrier(partyCount: Self.barrierPartyCount)
        let components = (1...Self.barrierPartyCount).map { position in
            StandInComponent(doctorName: "sleeper-\(position)", behavior: .arrivesAt(barrier))
        }

        let (report, didFire) = await Self.run(DoctorRunner(components: components)) { await barrier.release() }

        #expect(didFire == false)
        #expect(report.checks.count == Self.barrierPartyCount)
    }
}

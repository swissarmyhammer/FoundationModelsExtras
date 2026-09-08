import FoundationModelsExtras
import Testing

/// Behavioral tests for the doctor runner of `doctor-plan.md` §4: the
/// concurrent collection of the checks of every applicable component, and the
/// stable registration order of the result.
///
/// The suite imports the module plainly rather than with `@testable`, so it
/// exercises the same surface a consumer package sees — the tests fail to
/// compile if any of this API stops being `public`.
@Suite("Doctor runner") struct DoctorRunnerTests {

    // MARK: - The timings the concurrency tests spend

    /// How long the first component sleeps in the ordering test. Long enough
    /// that the second component finishes first on any machine, and short
    /// enough that the suite stays fast.
    private static let orderingDelay: Duration = .milliseconds(200)

    /// How long the watchdog waits before it declares the runner serial. Far
    /// longer than a concurrent runner needs, so a slow machine never fires it.
    private static let watchdogPatience: Duration = .seconds(5)

    /// How long each component of the timing test sleeps.
    private static let componentDelay: Duration = .milliseconds(100)

    /// How many sleeping components the timing test registers.
    private static let sleepingComponentCount = 10

    /// What the serial time is divided by to get the time a concurrent run
    /// must stay under. A concurrent run takes about one ``componentDelay``,
    /// so half of the serial time is a wide margin on a slow machine.
    private static let serialTimeFraction = 2

    /// The longest a run of ``sleepingComponentCount`` components may take
    /// before the test reads the runner as serial.
    private static let concurrentRunLimit: Duration =
        componentDelay * sleepingComponentCount / serialTimeFraction

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

    // MARK: - The stand-in component

    /// What a ``StandInComponent`` does before it reports its finding.
    private enum ComponentBehavior: Sendable {
        /// Reports at once.
        case reportsAtOnce

        /// Sleeps for the given time, then reports.
        case sleeps(Duration)

        /// Waits until the signal is set, then reports.
        case waitsFor(Signal)

        /// Sets the signal, then reports.
        case sets(Signal)

        /// Performs the wait this behavior states.
        func perform() async {
            switch self {
            case .reportsAtOnce:
                break
            case .sleeps(let duration):
                try? await Task.sleep(for: duration)
            case .waitsFor(let signal):
                await signal.wait()
            case .sets(let signal):
                await signal.signal()
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

    // MARK: - The order of the report

    @Test func `the report keeps the registration order when the first component is slow`() async {
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "slow", behavior: .sleeps(Self.orderingDelay)),
            StandInComponent(doctorName: "fast"),
        ])

        let report = await runner.run()

        #expect(report.checks.map(\.name) == ["slow", "fast"])
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
    /// run can finish at all only when the two run at the same time.
    ///
    /// The watchdog is what makes a serial runner **fail**. The
    /// `.timeLimit(.minutes(1))` trait is a last backstop only: swift-testing
    /// enforces a time limit by cancellation, cancellation never resumes a
    /// pending continuation, and a test that leaned on the trait alone would
    /// hang in place of failing. The watchdog sets its flag before it sets the
    /// signal, so the flag already stands when the deadlocked run resumes, and
    /// awaiting `watchdog.value` makes the reading deterministic in both cases.
    @Test(.timeLimit(.minutes(1)))
    func `one slow component does not hold back the others`() async {
        let signal = Signal()
        let watchdogFlag = WatchdogFlag()
        let runner = DoctorRunner(components: [
            StandInComponent(doctorName: "waiting", behavior: .waitsFor(signal)),
            StandInComponent(doctorName: "signalling", behavior: .sets(signal)),
        ])

        let watchdog = Task {
            do {
                try await Task.sleep(for: Self.watchdogPatience)
            } catch {
                return
            }
            await watchdogFlag.fire()
            await signal.signal()
        }

        let report = await runner.run()
        watchdog.cancel()
        await watchdog.value

        let didFire = await watchdogFlag.didFire
        #expect(didFire == false)
        #expect(report.checks.map(\.name) == ["waiting", "signalling"])
    }

    /// N components that each wait ``componentDelay`` finish in well under
    /// N times that wait, because the runner asks them all at the same time.
    @Test(.timeLimit(.minutes(1)))
    func `components that each wait finish in well under the sum of their waits`() async {
        let components = (1...Self.sleepingComponentCount).map { position in
            StandInComponent(doctorName: "sleeper-\(position)", behavior: .sleeps(Self.componentDelay))
        }
        let runner = DoctorRunner(components: components)
        let clock = ContinuousClock()

        let start = clock.now
        let report = await runner.run()
        let elapsed = clock.now - start

        #expect(report.checks.count == Self.sleepingComponentCount)
        #expect(elapsed < Self.concurrentRunLimit)
    }
}

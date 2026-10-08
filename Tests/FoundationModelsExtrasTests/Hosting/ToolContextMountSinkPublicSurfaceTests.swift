import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

/// The output of a fixture tool in this file when no ``ToolContext`` is
/// bound. No test reads it: each call goes through a mount, and a mount binds
/// a context.
private let unboundToolOutput = "unbound"

/// Holds ``ToolContext/mount(_:op:as:postingTo:)`` to the public surface. A
/// caller gives its own sink, and the events of each mounted run reach that
/// sink under the completion token of the run.
///
/// The import is plain, with no `@testable`. The compiler is thus the first
/// assertion: the overload, ``OperationEventSink``, ``RunPlane``, ``MountSite``
/// and ``ToolMounting`` must be public, or this file does not compile.
///
/// Each mount is made where an outside caller makes it: in a running tool, on
/// the context that the tool reads from ``ToolContext/current``. The test
/// mounts that tool on a new session with ``ToolMounting``, as a host does.
///
/// Two tests wait until a mounted run arrives. When a change stops such a run,
/// the time limit fails the test and does not stop the whole test run.
@Suite(
    "ToolContext.mount(postingTo:): a sink of the caller over the public surface",
    .timeLimit(.minutes(1))
)
struct ToolContextMountSinkPublicSurfaceTests {
    // MARK: - Labels

    /// The label of the host run: the tool that the session mounts. Each mount
    /// in this file is made from it.
    private static let hostLabel = "host"

    /// The label of the run that mounts the two runs that the re-stamp test
    /// compares.
    private static let mountingLabel = "mounting"

    /// The label of a run that the default overload mounts.
    private static let defaultMountedLabel = "default-mounted"

    /// The label of a run that `postingTo:` mounts.
    private static let sinkMountedLabel = "sink-mounted"

    /// The label of the first of the two concurrent runs.
    private static let firstConcurrentLabel = "first-concurrent"

    /// The label of the second of the two concurrent runs.
    private static let secondConcurrentLabel = "second-concurrent"

    /// The label of the run that the background test mounts.
    private static let backgroundLabel = "background"

    /// The limit of the wait for the background run to settle, in seconds.
    private static let settlementDeadlineSeconds: Double = 30

    // MARK: - Fixtures

    /// The arguments of the fixture tools.
    @Generable
    struct LabelArguments {
        /// The label that the model sends.
        let value: String
    }

    /// A sink as a caller outside this package writes it.
    private typealias RecordingSink = PublicSurfaceRecordingSink

    /// The completion tokens that the runs of one test recorded, by the label
    /// of each run. A run makes its token when it opens, so the test learns
    /// the token from the run.
    private actor RunTokenLog {
        /// Each recorded token, by the label of its run.
        private(set) var tokens: [String: String] = [:]

        /// Records the completion token of one run.
        ///
        /// - Parameters:
        ///   - label: The label of the run.
        ///   - token: The `completionToken` of the run.
        func record(_ label: String, token: String) {
            tokens[label] = token
        }
    }

    /// What the background test saw when its mounted call returned.
    private actor ReturnSnapshot {
        /// The events of the sink when the mounted call returned.
        private(set) var events: [OperationEvent] = []

        /// The number of runs that the run plane tracked at that time.
        private(set) var trackedRunCount = 0

        /// Records what the mounting run saw when its mounted call returned.
        ///
        /// - Parameters:
        ///   - events: The events of the sink at that time.
        ///   - trackedRunCount: The number of tracked runs at that time.
        func record(events: [OperationEvent], trackedRunCount: Int) {
            self.events = events
            self.trackedRunCount = trackedRunCount
        }
    }

    /// Records the completion token of its run, posts one progress event with
    /// ``label`` as its detail, and returns.
    ///
    /// The detail lets a test find the event of this run in a sink that more
    /// runs post to. The test compares the `correlationID` of that event with
    /// the recorded token.
    private struct RunIdentityTool: Tool {
        let name = "run_identity_tool"
        let description = "test-only tool that posts one progress event and records the token of its run"

        /// The label of this run: the detail that it posts, and the key of
        /// its token.
        let label: String

        /// Where this run records its completion token.
        let log: RunTokenLog

        /// Opened after the progress event, or `nil`.
        var arrived: RunLatch?

        /// Waited on after ``arrived`` opens, or `nil` to return at once.
        var release: RunLatch?

        func call(arguments: LabelArguments) async throws -> String {
            guard let context = ToolContext.current else { return unboundToolOutput }
            await log.record(label, token: context.completionToken)
            await context.progress(label)
            arrived?.open()
            await release?.waitUntilOpen()
            return "ran: \(label)"
        }
    }

    /// Runs a body with the ``ToolContext`` of its own call, and records the
    /// completion token of that context.
    ///
    /// A mount reaches a real context over the public surface this way: the
    /// session mounts this tool, the test calls it, and the body mounts the
    /// tool of the test on the context that it gets.
    private struct MountingTool: Tool {
        let name = "mounting_tool"
        let description = "test-only tool that mounts another tool on its own running context"

        /// The key of the token of this run.
        let label: String

        /// Where this run records its completion token.
        let log: RunTokenLog

        /// What to do with the bound context.
        let body: @Sendable (ToolContext) async throws -> Void

        func call(arguments: LabelArguments) async throws -> String {
            guard let context = ToolContext.current else { return unboundToolOutput }
            await log.record(label, token: context.completionToken)
            try await body(context)
            return "mounted: \(label)"
        }
    }

    // MARK: - Harness

    /// Mounts `host` on a new session, as a host does, and calls it one time.
    ///
    /// The settle period of the session is `0`, so each inner background call
    /// answers with its pending envelope at once.
    ///
    /// - Parameter host: The tool that the session mounts.
    /// - Throws: What the call throws.
    private static func callOnANewSession(_ host: MountingTool) async throws {
        let site = MountSite(sessionID: ULID(), runPlane: RunPlane(), sink: RecordingSink(), inlineSettleGrace: 0)
        let mounted = ToolMounting.makeWrapped(tool: host, site: site, configuration: .synchronous)
        let typed = try #require(mounted as? any Tool<LabelArguments, String>)
        _ = try await typed.call(arguments: LabelArguments(value: hostLabel))
    }

    /// The `correlationID` of the one event with `detail`.
    ///
    /// - Parameters:
    ///   - detail: The detail to find, exactly.
    ///   - events: The events of the sink.
    /// - Returns: The `correlationID` of that event.
    /// - Throws: When no event has `detail`.
    private static func correlationID(ofEventDetailed detail: String, in events: [OperationEvent]) throws -> String {
        try #require(events.first { $0.detail == detail }).correlationID
    }

    /// The completion token that the run `label` recorded.
    ///
    /// - Parameters:
    ///   - label: The label of the run.
    ///   - tokens: Each recorded token.
    /// - Returns: The `completionToken` of that run.
    /// - Throws: When that run recorded nothing.
    private static func token(of label: String, in tokens: [String: String]) throws -> String {
        try #require(tokens[label])
    }

    // MARK: - The correlation of the run

    @Test("a run mounted with a sink of the caller posts under its own completion token")
    func theSinkOfTheCallerSeesTheCorrelationOfTheMountedRun() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounted = context.mount(RunIdentityTool(label: Self.sinkMountedLabel, log: log), postingTo: sink)
            _ = try await mounted.call(arguments: LabelArguments(value: Self.sinkMountedLabel))
        }

        try await Self.callOnANewSession(host)

        let events = await sink.events
        let tokens = await log.tokens
        let observed = try Self.correlationID(ofEventDetailed: Self.sinkMountedLabel, in: events)
        let ownToken = try Self.token(of: Self.sinkMountedLabel, in: tokens)
        let hostToken = try Self.token(of: Self.hostLabel, in: tokens)

        // The token of the run itself, not the token of the run that mounted it.
        #expect(observed == ownToken)
        #expect(observed != hostToken)
    }

    // MARK: - The re-stamp, both ways

    @Test("the default overload re-stamps onto the mounting run, and postingTo: does not")
    func theDefaultOverloadRestampsWhereTheSinkOverloadDoesNot() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        // Both mounts are made on one context, of one tool. Only the overload
        // is different.
        let mountingBody: @Sendable (ToolContext) async throws -> Void = { context in
            let restamped = context.mount(RunIdentityTool(label: Self.defaultMountedLabel, log: log))
            _ = try await restamped.call(arguments: LabelArguments(value: Self.defaultMountedLabel))

            let direct = context.mount(RunIdentityTool(label: Self.sinkMountedLabel, log: log), postingTo: sink)
            _ = try await direct.call(arguments: LabelArguments(value: Self.sinkMountedLabel))
        }
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounting = context.mount(
                MountingTool(label: Self.mountingLabel, log: log, body: mountingBody), postingTo: sink)
            _ = try await mounting.call(arguments: LabelArguments(value: Self.mountingLabel))
        }

        try await Self.callOnANewSession(host)

        let events = await sink.events
        let tokens = await log.tokens
        let mountingToken = try Self.token(of: Self.mountingLabel, in: tokens)
        let restampedCorrelation = try Self.correlationID(ofEventDetailed: Self.defaultMountedLabel, in: events)
        let directCorrelation = try Self.correlationID(ofEventDetailed: Self.sinkMountedLabel, in: events)
        let restampedOwnToken = try Self.token(of: Self.defaultMountedLabel, in: tokens)
        let directOwnToken = try Self.token(of: Self.sinkMountedLabel, in: tokens)

        // The default overload stamps a second time: the mounting context puts
        // its own token on the event before the sink sees it.
        #expect(restampedCorrelation == mountingToken)
        #expect(restampedCorrelation != restampedOwnToken)

        // `postingTo:` does not stamp a second time, because the sink is the
        // upstream of the run. The run keeps its own correlation.
        #expect(directCorrelation == directOwnToken)
        #expect(directCorrelation != mountingToken)
    }

    // MARK: - Two runs at one time

    @Test("two concurrent runs mounted with a sink of the caller have different correlations")
    func twoConcurrentRunsHaveDifferentCorrelations() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let firstArrived = RunLatch.closed()
        let secondArrived = RunLatch.closed()
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            // Each run waits until the other run posted, so the two runs are
            // in flight at the same time.
            let first = context.mount(
                RunIdentityTool(
                    label: Self.firstConcurrentLabel, log: log, arrived: firstArrived, release: secondArrived),
                postingTo: sink)
            let second = context.mount(
                RunIdentityTool(
                    label: Self.secondConcurrentLabel, log: log, arrived: secondArrived, release: firstArrived),
                postingTo: sink)

            async let firstRun = first.call(arguments: LabelArguments(value: Self.firstConcurrentLabel))
            async let secondRun = second.call(arguments: LabelArguments(value: Self.secondConcurrentLabel))
            _ = try await (firstRun, secondRun)
        }

        try await Self.callOnANewSession(host)

        let events = await sink.events
        let tokens = await log.tokens
        let firstCorrelation = try Self.correlationID(ofEventDetailed: Self.firstConcurrentLabel, in: events)
        let secondCorrelation = try Self.correlationID(ofEventDetailed: Self.secondConcurrentLabel, in: events)

        // The default overload cannot give this assertion: there, both events
        // get the one token of the mounting run.
        #expect(firstCorrelation != secondCorrelation)
        #expect(firstCorrelation == (try Self.token(of: Self.firstConcurrentLabel, in: tokens)))
        #expect(secondCorrelation == (try Self.token(of: Self.secondConcurrentLabel, in: tokens)))
    }

    // MARK: - The sink lives longer than the call

    @Test("a background mount posts to the sink of the caller after the call returned")
    func aBackgroundMountPostsAfterTheCallReturned() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let arrived = RunLatch.closed()
        let release = RunLatch.closed()
        let snapshot = ReturnSnapshot()
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounted = context.mount(
                RunIdentityTool(label: Self.backgroundLabel, log: log, arrived: arrived, release: release),
                as: ToolMount(mode: .background, timeout: nil),
                postingTo: sink)
            _ = try await mounted.call(arguments: LabelArguments(value: Self.backgroundLabel))

            // The call returned its envelope, and the run continues. It waits
            // on `release` after its progress event. Read the sink now.
            await arrived.waitUntilOpen()
            let tracked = await context.backgroundRuns()
            await snapshot.record(events: await sink.events, trackedRunCount: tracked.count)

            // Let the run go, and wait until it settles.
            release.open()
            for run in tracked {
                _ = await context.wait(completionToken: run.completionToken, seconds: Self.settlementDeadlineSeconds)
            }
        }

        try await Self.callOnANewSession(host)

        let atReturn = await snapshot.events
        // The run plane tracked the run, and its progress event was in the
        // sink. Thus the missing terminal event means the run did not settle.
        #expect(await snapshot.trackedRunCount == 1)
        #expect(atReturn.contains { $0.kind == .progress })
        #expect(!atReturn.contains { $0.kind == .completed })

        let events = await sink.events
        let tokens = await log.tokens
        let terminal = try #require(events.first { $0.kind == .completed })
        let ownToken = try Self.token(of: Self.backgroundLabel, in: tokens)
        let hostToken = try Self.token(of: Self.hostLabel, in: tokens)

        // The sink stayed for the life of the run: it got the terminal event
        // after the call returned, with the correlation of the run.
        #expect(terminal.correlationID == ownToken)
        #expect(terminal.correlationID != hostToken)
    }
}

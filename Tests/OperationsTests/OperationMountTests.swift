import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing
import ULID

@testable import Operations

/// The shared context of the mount fixtures. It holds no state.
private struct MountFixtureContext: Sendable {}

/// The output of each mount fixture: the op string of the operation.
private struct MountFixtureOutput: Encodable, Sendable {
    let op: String
}

/// `start job`: an operation that declares a background mount.
private struct StartJobFixture: OperationDefinition {
    typealias Context = MountFixtureContext
    typealias Output = MountFixtureOutput

    static let verb = "start"
    static let noun = "job"
    static let operationDescription = "Start a job in the background"
    static let parameterMetadata: [ParamMeta] = []
    static let mount = ToolMount(mode: .background)

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: StartJobFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }

    func execute(in context: MountFixtureContext) async throws -> MountFixtureOutput {
        MountFixtureOutput(op: Self.opString)
    }
}

/// `list jobs`: an operation that declares no mount.
private struct ListJobsFixture: OperationDefinition {
    typealias Context = MountFixtureContext
    typealias Output = MountFixtureOutput

    static let verb = "list"
    static let noun = "jobs"
    static let operationDescription = "List the jobs"
    static let parameterMetadata: [ParamMeta] = []

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: ListJobsFixture.self, description: operationDescription, properties: [])
    }

    init(_ content: GeneratedContent) throws {}

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [:])
    }

    func execute(in context: MountFixtureContext) async throws -> MountFixtureOutput {
        MountFixtureOutput(op: Self.opString)
    }
}

/// A sink that drops each event.
private struct DiscardingSink: OperationEventSink {
    func post(event: OperationEvent) async {}
}

/// Each operation of an `OperationTool` declares its mount, and the tool
/// gives the mount of the called operation for each call.
@Suite("OperationTool: each operation declares its mount", .timeLimit(.minutes(1)))
struct OperationMountTests {
    /// How long a test waits for a background run to settle, in seconds.
    private static let settlementDeadline: TimeInterval = 30

    /// An op string that no fixture operation has.
    private static let unknownOp = "fly kite"

    /// A tool with the background `start job` and the synchronous `list jobs`.
    private static func makeTool() throws -> OperationTool<MountFixtureContext> {
        try OperationTool(
            name: "jobs",
            description: "Starts and lists jobs",
            context: MountFixtureContext(),
            operations: [AnyOperation(StartJobFixture.self), AnyOperation(ListJobsFixture.self)]
        )
    }

    /// The payload of a call of `op`.
    private static func payload(_ op: String) -> GeneratedContent {
        GeneratedContent(properties: ["op": op])
    }

    /// The JSON output of a fixture operation for `op`.
    private static func output(_ op: String) -> String {
        "{\"op\":\"\(op)\"}"
    }

    /// Mounts `tool` on a new session with `configuration`, as a host does.
    ///
    /// The settle period of the session is `0`, so a background operation
    /// answers with its pending envelope at once, also when its work is fast.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - configuration: The mount of the host.
    /// - Returns: The mounted tool and the run plane of the session.
    private static func mountOnNewSession(
        _ tool: OperationTool<MountFixtureContext>,
        as configuration: ToolMount
    ) throws -> (mounted: any Tool<GeneratedContent, String>, runPlane: RunPlane) {
        let runPlane = RunPlane()
        let site = MountSite(sessionID: ULID(), runPlane: runPlane, sink: DiscardingSink(), inlineSettleGrace: 0)
        let wrapped = ToolMounting.makeWrapped(tool: tool, site: site, configuration: configuration)
        return (try #require(wrapped as? any Tool<GeneratedContent, String>), runPlane)
    }

    /// The terminal event of a settled wait, or `nil` for each other outcome.
    private static func terminal(of outcome: WaitOutcome) -> OperationEvent? {
        if case .settled(let terminal) = outcome {
            return terminal
        }
        return nil
    }

    @Test("an operation with no declared mount is synchronous")
    func undeclaredMountIsSynchronous() {
        #expect(ListJobsFixture.mount == .synchronous)
        #expect(AnyOperation(ListJobsFixture.self).mount == .synchronous)
    }

    @Test("the type-erased operation keeps the declared mount")
    func anyOperationKeepsTheDeclaredMount() {
        #expect(AnyOperation(StartJobFixture.self).mount == ToolMount(mode: .background))
    }

    @Test("the tool gives the mount of the called operation")
    func toolGivesTheMountOfTheCalledOperation() throws {
        let tool = try Self.makeTool()

        #expect(tool.mount(for: Self.payload(StartJobFixture.opString)) == ToolMount(mode: .background))
        #expect(tool.mount(for: Self.payload(ListJobsFixture.opString)) == .synchronous)
    }

    @Test("an unknown operation is synchronous")
    func unknownOperationIsSynchronous() throws {
        let tool = try Self.makeTool()

        #expect(tool.mount(for: Self.payload(Self.unknownOp)) == .synchronous)
    }

    @Test("the background operation returns a pending token, and the synchronous operation returns its result in band")
    func eachOperationRunsWithItsOwnMount() async throws {
        let session = try Self.mountOnNewSession(try Self.makeTool(), as: .synchronous)

        let started = try await session.mounted.call(arguments: Self.payload(StartJobFixture.opString))
        let envelope = try JSONDecoder().decode(PendingRunEnvelope.self, from: Data(started.utf8))
        #expect(envelope.pending)
        let outcome = await session.runPlane.wait(
            completionToken: envelope.completionToken, seconds: Self.settlementDeadline)
        let terminal = try #require(Self.terminal(of: outcome), "the run did not settle: \(outcome)")
        #expect(terminal.detail == Self.output(StartJobFixture.opString))

        let listed = try await session.mounted.call(arguments: Self.payload(ListJobsFixture.opString))
        #expect(listed == Self.output(ListJobsFixture.opString))
    }

    @Test("under a background host mount, an operation with no declared mount returns its result in band")
    func undeclaredOperationIsSynchronousUnderABackgroundHost() async throws {
        let session = try Self.mountOnNewSession(try Self.makeTool(), as: ToolMount(mode: .background))

        let listed = try await session.mounted.call(arguments: Self.payload(ListJobsFixture.opString))

        #expect(listed == Self.output(ListJobsFixture.opString))
        #expect(await session.runPlane.backgroundRuns().isEmpty)
    }
}

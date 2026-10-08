@testable import FoundationModelsExtras
import Foundation
import FoundationModels
import Testing
import ULID

/// ``ToolMounting``: the decorator of a tool, from the mount that the tool
/// declares or from the mount of the site, and the binding-only decorator of
/// a tool whose output is not `String`.
@Suite("ToolMounting: mount a tool in the layer it declares", .timeLimit(.minutes(1)))
struct ToolMountingTests {
    private typealias Fixtures = MountFixtures

    /// How many ``MountFixtures/shortInterval`` windows a declared
    /// run-to-completion call is held: longer than the timeout of the site,
    /// so only the declaration explains a call that is neither in the
    /// background nor timed out.
    private static let declaredMountHoldWindows: Double = 3

    /// How long, in seconds, the tool with no timeout runs with no progress.
    private static let quietRunSeconds: TimeInterval = 3

    /// The timeout, in seconds, of the mount in the timeout test.
    private static let statedTimeoutSeconds: TimeInterval = 1

    /// Mounts `tool` as a session mounts each tool: the mount decorator under
    /// the failure decorator, with the synchronous mount. Returns the mount
    /// decorator, which this suite reads.
    private static func makeSessionMounted(_ tool: any Tool, site: MountSite) -> any Tool {
        ToolFailureDelivery.throwingTool(
            of: ToolFailureDelivery.makeWrapped(
                tool: ToolMounting.makeWrapped(tool: tool, site: site, configuration: .synchronous)))
    }

    // MARK: - The String-output path

    @Test("a String-output tool mounts in the background layer when the site says so")
    func factoryWrapsStringOutputTool() async throws {
        let gate = RunLatch()
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: Fixtures.GatedTool(gate: gate),
            site: Fixtures.site(runPlane: runPlane, sink: sink),
            configuration: ToolMount(mode: .background)
        )

        let mounted = try #require(wrapped as? BackgroundToolRunner<MountArguments>)
        #expect(mounted.timeout == nil)
        let rendered = try await mounted.call(arguments: MountArguments(value: "factory"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
        #expect(terminal.detail == "gated: factory")
    }

    @Test("a mount on a ToolContext tracks the run on the run plane of that context, in its session")
    func factoryInheritsRunPlaneAndSessionIdentity() async throws {
        let gate = RunLatch()
        let runPlane = RunPlane()
        let sessionID = ULID()
        let sink = Fixtures.RecordingSink()
        let outer = ToolContext(
            sessionID: sessionID,
            runPlane: runPlane,
            sink: sink,
            tool: "gated_session_identity_tool",
            op: "gated_session_identity_tool",
            completionToken: RunPlane.makeCompletionToken(),
            isCancelled: { false },
            inlineSettleGrace: Fixtures.pendingAtOnceGrace
        )
        let wrapped = outer.mount(
            Fixtures.GatedSessionIdentityTool(gate: gate), as: ToolMount(mode: .background), postingTo: sink)

        let mounted = try #require(wrapped as? BackgroundToolRunner<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "inherited"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        // The run plane of the context tracks the run. The call never named
        // that run plane.
        let runs = await runPlane.backgroundRuns()
        #expect(runs.map(\.completionToken) == [envelope.completionToken])

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
        // The inner run ran in the session of the context.
        #expect(terminal.detail == sessionID.ulidString)
        #expect(terminal.outcome == .succeeded)
    }

    // MARK: - The metadata that the model sees

    /// The JSON of `schema`, with sorted keys. `GenerationSchema` is not
    /// `Equatable`, so the test compares this text.
    private static func encodedSchema(_ schema: GenerationSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(schema), as: UTF8.self)
    }

    @Test(
        "a runner in each mode gives the name, description, parameters and schema choice of the tool it wraps",
        arguments: [ToolMount.Mode.background, .runToCompletion]
    )
    func runnerForwardsTheMetadataOfTheWrappedTool(mode: ToolMount.Mode) throws {
        let tool = Fixtures.SchemaOmittingTool()
        let wrapped = ToolMounting.makeWrapped(
            tool: tool,
            site: Fixtures.site(runPlane: RunPlane(), sink: Fixtures.RecordingSink()),
            configuration: ToolMount(mode: mode)
        )

        let runner = try #require(wrapped as? any MountRunner)
        #expect(type(of: runner).defaultMode == mode)
        #expect(runner.name == tool.name)
        #expect(runner.description == tool.description)
        #expect(try Self.encodedSchema(runner.parameters) == Self.encodedSchema(tool.parameters))
        // The tool keeps its schema out of the instructions, so a forwarder
        // that gives the default of `Tool` fails here.
        #expect(runner.includesSchemaInInstructions == tool.includesSchemaInInstructions)
        #expect(!runner.includesSchemaInInstructions)
    }

    // MARK: - The non-String-output path

    @Test("a non-String-output tool mounts in the binding-only ContextBindingTool")
    func factoryBindsNonStringOutputTool() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: Fixtures.NonStringOutputTool(),
            site: Fixtures.site(runPlane: RunPlane(), sink: sink),
            configuration: ToolMount(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<MountArguments, NonStringToolOutput>)
        let output = try await binding.call(arguments: MountArguments(value: "silent"))

        // The output of the wrapped tool comes back unchanged, and a silent
        // run posts nothing.
        #expect(output.text == "ignored")
        #expect(await sink.events.isEmpty)
    }

    @Test("the events of a non-String-output tool have its own tool identity and a new correlationID for each call")
    func nonStringOutputToolAmbientPostsCarryPerCallIdentity() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: AmbientNonStringOutputTool(),
            site: Fixtures.site(runPlane: RunPlane(), sink: sink),
            configuration: ToolMount(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let first = try await binding.call(arguments: AmbientToolArguments(value: "one"))
        let second = try await binding.call(arguments: AmbientToolArguments(value: "two"))

        let events = await sink.events
        #expect(events.map(\.detail) == ["one", "two"])
        #expect(events.map(\.tool) == ["ambient-non-string", "ambient-non-string"])
        #expect(events.map(\.op) == ["ambient-non-string", "ambient-non-string"])
        // A token for each run, not for the session.
        #expect(events.map(\.correlationID) == [first.text, second.text])
        #expect(first.text != second.text)
        #expect(ULID(ulidString: first.text) != nil)
    }

    @Test("a mount on a ToolContext binds a non-String-output tool in the session of that context")
    func factoryInheritsAmbientContext() async throws {
        let sink = Fixtures.RecordingSink()
        let outer = ToolContext(
            sessionID: ULID(),
            runPlane: RunPlane(),
            sink: sink,
            tool: "ambient-non-string",
            op: "ambient-non-string",
            completionToken: "outer-run",
            isCancelled: { false }
        )
        let wrapped = outer.mount(AmbientNonStringOutputTool(), as: ToolMount(mode: .background), postingTo: sink)

        let binding = try #require(wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let inner = try await binding.call(arguments: AmbientToolArguments(value: "inherited"))

        // The inner call has its own identity and its own correlation, not the
        // token of the outer run.
        let events = await sink.events
        #expect(events.map(\.detail) == ["inherited"])
        #expect(events.map(\.tool) == ["ambient-non-string"])
        #expect(events.map(\.correlationID) == [inner.text])
        #expect(inner.text != outer.completionToken)
    }

    @Test("the records of a non-String-output tool go to the settlement of the binding call, in call order")
    func nonStringOutputToolAttachmentsDrainToTheSettlement() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: Fixtures.AttachingNonStringOutputTool(),
            site: Fixtures.site(runPlane: RunPlane(), sink: sink),
            configuration: ToolMount(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<MountArguments, NonStringToolOutput>)
        let settlement = await binding.settle(arguments: MountArguments(value: "x"))

        #expect(settlement.attachments == Fixtures.attachmentsInCallOrder)
        #expect(try settlement.outcome.get().text == "attached: x")
        // The records go only on the settlement: no event carries them.
        #expect(await sink.events.isEmpty)
    }

    // MARK: - The mount that a tool declares

    @Test("a tool that declares nothing mounts run-to-completion with no timeout, and its slow call stays in band")
    func undeclaredToolMountsRunToCompletion() async throws {
        let gate = RunLatch()
        let runPlane = RunPlane()
        let site = Fixtures.site(runPlane: runPlane, sink: Fixtures.RecordingSink())
        let mounted = try #require(
            Self.makeSessionMounted(Fixtures.GatedTool(gate: gate), site: site) as? RunToCompletionRunner<MountArguments>
        )

        #expect(mounted.timeout == nil)

        let calling = Task {
            try await mounted.call(arguments: MountArguments(value: "edit"))
        }
        try await Task.sleep(for: .seconds(Fixtures.shortInterval))
        // No token came back: the call is still in band.
        #expect(await runPlane.backgroundRuns().isEmpty)
        gate.open()

        let rendered = try await calling.value
        #expect(rendered == "gated: edit")
        #expect(await runPlane.backgroundRuns().isEmpty)
    }

    @Test("a tool with no timeout that runs with no progress completes")
    func unstatedTimeoutLetsAQuietRunComplete() async throws {
        let site = Fixtures.site(runPlane: RunPlane(), sink: Fixtures.RecordingSink())
        let mounted = Self.makeSessionMounted(Fixtures.QuietTool(duration: Self.quietRunSeconds), site: site)
        let quiet = try #require(mounted as? RunToCompletionRunner<MountArguments>)

        let rendered = try await quiet.call(arguments: MountArguments(value: "slow"))

        #expect(rendered == "quiet: slow")
    }

    @Test("a mount with a timeout times out a run with no progress")
    func statedTimeoutTimesOutAQuietRun() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: Fixtures.SleepingTool(),
            site: Fixtures.site(runPlane: RunPlane(), sink: sink),
            configuration: ToolMount(mode: .runToCompletion, timeout: Self.statedTimeoutSeconds)
        )
        let mounted = try #require(wrapped as? RunToCompletionRunner<MountArguments>)

        await #expect(
            throws: ToolMountError.timedOut(tool: "sleeping_tool", timeoutSeconds: Self.statedTimeoutSeconds)
        ) {
            _ = try await mounted.call(arguments: MountArguments(value: "x"))
        }
        #expect(await sink.events.last?.outcome == .timedOut)
    }

    @Test("a tool that declares background mounts in the background layer, and its call gives a token back at once")
    func declaredToolMountsBackground() async throws {
        let gate = RunLatch()
        let runPlane = RunPlane()
        let site = Fixtures.site(runPlane: runPlane, sink: Fixtures.RecordingSink())
        let mounted = try #require(
            Self.makeSessionMounted(Fixtures.DeclaredBackgroundToolRunner(gate: gate), site: site)
                as? BackgroundToolRunner<MountArguments>
        )

        #expect(mounted.timeout == nil)

        let rendered = try await mounted.call(arguments: MountArguments(value: "tests"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)
        #expect(await runPlane.backgroundRuns().map(\.tool) == ["declared_background_tool"])

        gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
        #expect(terminal.detail == "background: tests")
    }

    @Test("the mount that a tool declares wins over the mount of the site, the timeout also")
    func declaredMountOverridesTheSiteConfiguration() async throws {
        let gate = RunLatch()
        let runPlane = RunPlane()
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolMounting.makeWrapped(
            tool: Fixtures.DeclaredRunToCompletionRunner(gate: gate),
            site: Fixtures.site(runPlane: runPlane, sink: sink),
            configuration: ToolMount(mode: .background, timeout: Fixtures.shortInterval)
        )

        let mounted = try #require(wrapped as? RunToCompletionRunner<MountArguments>)
        #expect(mounted.timeout == nil)

        let calling = Task {
            try await mounted.call(arguments: MountArguments(value: "catalogue"))
        }
        // Held longer than the timeout of the site: with the mount of the
        // site, the call would go to the background at once, and then time out.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.declaredMountHoldWindows))
        #expect(await runPlane.backgroundRuns().isEmpty)
        gate.open()

        let rendered = try await calling.value
        #expect(rendered == "declared: catalogue")
        #expect(await runPlane.backgroundRuns().isEmpty)
        // A slow call is not a failed call: the run settles with no event.
        #expect(await sink.events.isEmpty)
    }

    @Test("two tools on one session keep their own modes: one waits in band, the other gives a token back")
    func oneSessionMountsBothModes() async throws {
        let runPlane = RunPlane()
        let site = Fixtures.site(runPlane: runPlane, sink: Fixtures.RecordingSink())
        let blockingGate = RunLatch()
        let backgroundingGate = RunLatch()
        // Both tools are mounted as a session mounts them, on one site.
        let blocking = try #require(
            Self.makeSessionMounted(Fixtures.DeclaredRunToCompletionRunner(gate: blockingGate), site: site)
                as? RunToCompletionRunner<MountArguments>
        )
        let backgrounding = try #require(
            Self.makeSessionMounted(Fixtures.DeclaredBackgroundToolRunner(gate: backgroundingGate), site: site)
                as? BackgroundToolRunner<MountArguments>
        )

        // The tool that declares background gives a token back.
        let rendered = try await backgrounding.call(arguments: MountArguments(value: "snippet"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.isPending)

        // On the same session, the run-to-completion tool waits.
        let discovering = Task {
            try await blocking.call(arguments: MountArguments(value: "catalogue"))
        }
        try await Task.sleep(for: .seconds(Fixtures.shortInterval))

        // The run plane tracks one run: the run of the background tool.
        let runs = await runPlane.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.tool == "declared_background_tool")

        blockingGate.open()
        let catalogue = try await discovering.value
        #expect(catalogue == "declared: catalogue")

        backgroundingGate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: runPlane)
        #expect(terminal.detail == "background: snippet")
    }
}

import Foundation
import FoundationModels
import Tracing
import ULID

/// Where a mounted tool runs: the session, its run plane, the sink of its
/// events, the op of the registration, and the tracer of its spans.
public struct MountSite: Sendable {
    /// The session of each call.
    let sessionID: ULID

    /// The run plane of the session.
    let runPlane: RunPlane

    /// The session that started this session, or `nil` when this session is
    /// the root of its tree.
    let parentSessionID: ULID?

    /// The root session of the tree of this session. At the root, it is
    /// ``sessionID``.
    let rootSessionID: ULID

    /// The run plane of the root session. The facts that the whole tree
    /// shares, for example the user presence of the root, come from it. At
    /// the root, it is ``runPlane``.
    let rootRunPlane: RunPlane

    /// The sink of the events and the records of each call.
    private(set) var sink: any OperationEventSink

    /// The sink of the session. A background run lives longer than the call
    /// that starts it, so each background call posts here. The terminal of a
    /// run in a nested mount thus goes to the session as the terminal of that
    /// run.
    private(set) var sessionSink: any OperationEventSink

    /// The `"verb noun"` op of the registration, or `nil` for the tool name.
    private(set) var op: String?

    /// The tracer of the session, or `nil` for `InstrumentationSystem.tracer`
    /// at call time.
    let tracer: (any Tracer)?

    /// The settle period that the host configured, in seconds: how long a
    /// background call waits for its own run. Never negative. `0` means that
    /// each background call answers with its pending envelope at once.
    ///
    /// A tool that states no ``BackgroundTool/inlineSettleGrace`` of its own
    /// uses this value.
    private(set) var inlineSettleGrace: TimeInterval

    /// The end of the settle period of the run that mounts this site, or `nil`
    /// when no run in its settle period mounts it.
    ///
    /// A run that makes inner calls, for example a script runner, waits for
    /// its own settle period. An inner background call that waits past that
    /// end makes the outer run answer with a pending envelope, so an inner call
    /// stops its wait before it. See ``BackgroundToolRunner``.
    private(set) var inlineSettleDeadline: ContinuousClock.Instant?

    /// The completion token of the run that holds each synchronous call of
    /// this site, or `nil` when no run holds them.
    ///
    /// A synchronous call that a run mounts runs inside the body of that run.
    /// Thus each question of the call stops that run, and links to its token.
    /// A background call is a run of its own, and does not use this value.
    private(set) var holdingRunToken: String?

    /// Makes a mount site. Each value must belong to the same session.
    ///
    /// - Parameters:
    ///   - sessionID: The session of each call.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the events and the records of each call.
    ///   - op: The `"verb noun"` op of the registration, or `nil` for the
    ///     tool name.
    ///   - tracer: The tracer of the session, or `nil` for
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - inlineSettleGrace: The settle period of each background call, in
    ///     seconds. A negative value acts as `0`. The default is
    ///     ``ToolMount/defaultInlineSettleGrace``.
    public init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        op: String? = nil,
        tracer: (any Tracer)? = nil,
        inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace
    ) {
        self.init(
            sessionID: sessionID, runPlane: runPlane, parent: nil, sink: sink, op: op, tracer: tracer,
            inlineSettleGrace: inlineSettleGrace)
    }

    /// Makes the mount site of a child session: a session that a call of the
    /// session `parentSessionID` started, for example a subagent.
    ///
    /// The child session has its own run plane, and thus its own
    /// ``WorkRegistry``. A lease of the child never goes into the registry of
    /// the parent. Each value must belong to the child session, except the
    /// ids and the run plane of the parent and of the root.
    ///
    /// ``ToolContext/childSite(sessionID:runPlane:sink:)`` makes this site
    /// from the context of the call that starts the child.
    ///
    /// - Parameters:
    ///   - sessionID: The child session.
    ///   - runPlane: The run plane of the child session.
    ///   - parentSessionID: The session that started the child.
    ///   - rootSessionID: The root session of the tree.
    ///   - rootRunPlane: The run plane of the root session.
    ///   - sink: The sink of the events and the records of each call.
    ///   - op: The `"verb noun"` op of the registration, or `nil` for the
    ///     tool name.
    ///   - tracer: The tracer of the session, or `nil` for
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - inlineSettleGrace: The settle period of each background call, in
    ///     seconds. A negative value acts as `0`.
    public init(
        sessionID: ULID,
        runPlane: RunPlane,
        parentSessionID: ULID,
        rootSessionID: ULID,
        rootRunPlane: RunPlane,
        sink: any OperationEventSink,
        op: String? = nil,
        tracer: (any Tracer)? = nil,
        inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace
    ) {
        self.init(
            sessionID: sessionID, runPlane: runPlane,
            parent: (parentSessionID, rootSessionID, rootRunPlane), sink: sink, op: op, tracer: tracer,
            inlineSettleGrace: inlineSettleGrace)
    }

    /// Makes a mount site at the root (`parent` is `nil`) or in a child
    /// session.
    ///
    /// - Parameters:
    ///   - sessionID: The session of each call.
    ///   - runPlane: The run plane of the session.
    ///   - parent: The parent session, the root session and the run plane of
    ///     the root, or `nil` at the root.
    ///   - sink: The sink of the events and the records of each call.
    ///   - op: The op of the registration, or `nil` for the tool name.
    ///   - tracer: The tracer of the session, or `nil`.
    ///   - inlineSettleGrace: The settle period of each background call.
    private init(
        sessionID: ULID,
        runPlane: RunPlane,
        parent: (sessionID: ULID, rootSessionID: ULID, rootRunPlane: RunPlane)?,
        sink: any OperationEventSink,
        op: String?,
        tracer: (any Tracer)?,
        inlineSettleGrace: TimeInterval
    ) {
        self.sessionID = sessionID
        self.runPlane = runPlane
        self.parentSessionID = parent?.sessionID
        self.rootSessionID = parent?.rootSessionID ?? sessionID
        self.rootRunPlane = parent?.rootRunPlane ?? runPlane
        self.sink = sink
        self.sessionSink = sink
        self.op = op
        self.tracer = tracer
        self.inlineSettleGrace = max(0, inlineSettleGrace)
        self.inlineSettleDeadline = nil
        self.holdingRunToken = nil
    }

    /// The site of a child session that a call on this site starts, for
    /// example a subagent. This session is the parent of the child, and the
    /// root of this session is the root of the child. The child keeps the
    /// tracer and the configured settle period of this site.
    ///
    /// - Parameters:
    ///   - sessionID: The child session.
    ///   - runPlane: The run plane of the child session.
    ///   - sink: The sink of the child session.
    /// - Returns: The site of the child session.
    public func childSite(sessionID: ULID, runPlane: RunPlane, sink: any OperationEventSink) -> MountSite {
        MountSite(
            sessionID: sessionID, runPlane: runPlane, parentSessionID: self.sessionID, rootSessionID: rootSessionID,
            rootRunPlane: rootRunPlane, sink: sink, tracer: tracer, inlineSettleGrace: inlineSettleGrace)
    }

    /// This site, with the sink of the session as the sink of each call.
    var postingToSession: MountSite {
        posting(to: sessionSink, sessionSink: sessionSink, op: op)
    }

    /// This site, with `sink` as the sink of each call, `sessionSink` as the
    /// sink of the session, and `op` as the op of the registration. Each
    /// other value stays.
    ///
    /// - Parameters:
    ///   - sink: The sink of the events and the records of each call.
    ///   - sessionSink: The sink of the session.
    ///   - op: The `"verb noun"` op of the registration, or `nil` for the
    ///     tool name.
    /// - Returns: The changed site.
    func posting(to sink: any OperationEventSink, sessionSink: any OperationEventSink, op: String?) -> MountSite {
        var changed = self
        changed.sink = sink
        changed.sessionSink = sessionSink
        changed.op = op
        return changed
    }

    /// This site, for the calls of one run: `runToken` holds each synchronous
    /// call, and `deadline` ends the settle period that the inner calls keep.
    /// Each other value stays.
    ///
    /// - Parameters:
    ///   - runToken: The completion token of the run that holds each
    ///     synchronous call, or `nil` for a call that is a run of its own.
    ///   - deadline: The end of the settle period of the run, or `nil` for
    ///     none.
    /// - Returns: The changed site.
    func held(by runToken: String?, settlingBy deadline: ContinuousClock.Instant?) -> MountSite {
        var changed = self
        changed.holdingRunToken = runToken
        changed.inlineSettleDeadline = deadline
        return changed
    }

    /// This site, with `grace` as the configured settle period. Each other
    /// value stays.
    ///
    /// - Parameter grace: The settle period in seconds. A negative value acts
    ///   as `0`.
    /// - Returns: The changed site.
    func settling(within grace: TimeInterval) -> MountSite {
        var changed = self
        changed.inlineSettleGrace = max(0, grace)
        return changed
    }
}

/// A decorator that runs each call of a `String` tool with the mount of that
/// call. ``BackgroundToolRunner`` and ``RunToCompletionRunner`` are the two
/// runners. Each one only sets its ``defaultMode``.
protocol MountRunner: Tool where Output == String {
    /// The mode of a call when the tool gives no mount for that call.
    static var defaultMode: ToolMount.Mode { get }

    /// The tool beneath this decorator.
    var wrapped: any Tool<Arguments, String> { get }

    /// Where the tool runs.
    var site: MountSite { get }

    /// The timeout with no progress, or `nil` for none. A timeout that the
    /// tool gives for one call wins.
    var timeout: TimeInterval? { get }

    /// Makes the runner. The memberwise initializer of each runner gives it.
    ///
    /// - Parameters:
    ///   - wrapped: The tool.
    ///   - site: Where the tool runs.
    ///   - timeout: The timeout with no progress, or `nil` for none.
    init(wrapped: any Tool<Arguments, String>, site: MountSite, timeout: TimeInterval?)
}

extension MountRunner where Arguments: Sendable {
    /// Wraps `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The tool.
    ///   - site: Where the tool runs.
    ///   - timeout: The timeout with no progress, or `nil` for none.
    init(wrapping wrapped: any Tool<Arguments, String>, site: MountSite, timeout: TimeInterval?) {
        self.init(wrapped: wrapped, site: site, timeout: timeout)
    }

    /// The name of the wrapped tool.
    var name: String { wrapped.name }

    /// The description of the wrapped tool.
    var description: String { wrapped.description }

    /// The parameters of the wrapped tool.
    var parameters: GenerationSchema { wrapped.parameters }

    /// The schema choice of the wrapped tool.
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Runs one call with the mount that the tool gives for `arguments`, or
    /// else with ``defaultMode``. See ``ToolMounting/call(_:arguments:site:mount:)``.
    ///
    /// - Parameter arguments: The arguments of the call.
    /// - Returns: The output of the tool, or the envelope of a background call.
    /// - Throws: The error of a call that runs to completion, or
    ///   ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
    func call(arguments: Arguments) async throws -> String {
        try await ToolMounting.call(
            wrapped, arguments: arguments, site: site, mount: ToolMount(mode: Self.defaultMode, timeout: timeout))
    }

    /// Prepares one call of the wrapped tool on `site`, with the timeout of
    /// this runner. Each runner gives the site of its own run: a background
    /// call is a run of its own, and a synchronous call keeps the site of its
    /// caller.
    ///
    /// - Parameters:
    ///   - arguments: The arguments of the call.
    ///   - site: The site of the run, with its settle deadline and its holding
    ///     run.
    /// - Returns: The run of the call. Call `open()`, then
    ///   `execute(arguments:)`.
    func makeRun(arguments: Arguments, on site: MountSite) -> ToolRun<Arguments> {
        ToolRun(wrapped: wrapped, arguments: arguments, site: site, mountTimeout: timeout)
    }
}

/// Mounts a tool of unknown type: it opens the `any Tool` and picks the
/// decorator.
public enum ToolMounting {
    /// Mounts `tool` on `site`.
    ///
    /// A `String` tool runs in the background or to completion. The mount
    /// that the tool declares through ``BackgroundTool/mount`` wins over
    /// `configuration`, and the mount that the tool gives for one call
    /// through ``BackgroundTool/mount(for:)`` wins over both. Each other tool
    /// only gets a bound ``ToolContext``.
    ///
    /// When `tool` is ``CatalogNoticing``, the session of `site` joins the
    /// ``CatalogNoticeBoard`` of the tool, and gets each later catalog change
    /// on the session sink of `site`.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - site: Where the tool runs.
    ///   - configuration: The mount when the tool declares none.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of
    ///   `tool`.
    public static func makeWrapped(tool: any Tool, site: MountSite, configuration: ToolMount) -> any Tool {
        (tool as? any CatalogNoticing)?.catalogNoticeBoard.join(site)
        func runner<A: ConvertibleFromGeneratedContent & Sendable>(_: A.Type, for tool: any Tool) -> any Tool {
            guard let typed = tool as? any Tool<A, String> else { return tool }
            let mount = (typed as? any BackgroundTool)?.mount ?? configuration
            switch mount.mode {
            case .background:
                return BackgroundToolRunner(wrapping: typed, site: site, timeout: mount.timeout)
            case .runToCompletion:
                return RunToCompletionRunner(wrapping: typed, site: site, timeout: mount.timeout)
            }
        }
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard tool is any Tool<T.Arguments, String> else {
                return ContextBindingTool<T.Arguments, T.Output>(wrapping: tool, site: site)
            }
            // `Tool` already makes `Arguments` `Sendable`. The cast tells the
            // generic system the same fact, so the fallback does not run.
            let arguments: Any = T.Arguments.self
            guard let sendable = arguments as? any (ConvertibleFromGeneratedContent & Sendable).Type else {
                return tool
            }
            return runner(sendable, for: tool)
        }
        return open(tool)
    }

    /// Runs one call of a `String` tool with the mount of that call: the
    /// mount that the tool gives for `arguments`, or else `mount`. This is
    /// the one decision point of each call.
    ///
    /// A background call posts to the sink of the session, also in a nested
    /// mount. Thus its terminal goes to the session as the terminal of its
    /// own run.
    ///
    /// - Parameters:
    ///   - wrapped: The called tool.
    ///   - arguments: The arguments of the call.
    ///   - site: Where the tool runs.
    ///   - mount: The mount when the tool gives none for the call.
    /// - Returns: The output of the tool, or the envelope of a background run.
    /// - Throws: The error of a call that runs to completion.
    static func call<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        _ wrapped: any Tool<Arguments, String>,
        arguments: Arguments,
        site: MountSite,
        mount: ToolMount
    ) async throws -> String {
        let declared = backgroundDeclaration(of: wrapped, for: arguments)
        let chosen = declared.flatMap { $0.tool.mount(for: $0.content) } ?? mount
        switch chosen.mode {
        case .background:
            let runner = BackgroundToolRunner(wrapping: wrapped, site: site.postingToSession, timeout: chosen.timeout)
            return try await runner.callInBackground(arguments: arguments)
        case .runToCompletion:
            let runner = RunToCompletionRunner(wrapping: wrapped, site: site, timeout: chosen.timeout)
            return try await runner.callToCompletion(arguments: arguments)
        }
    }

    /// `wrapped` as a ``BackgroundTool``, and `arguments` as content that
    /// the tool reads, or `nil` when the tool is not a ``BackgroundTool``.
    ///
    /// - Parameters:
    ///   - wrapped: The called tool.
    ///   - arguments: The arguments of the call.
    /// - Returns: The declaration of the tool and the content of the call.
    static func backgroundDeclaration(
        of wrapped: any Tool,
        for arguments: some Sendable
    ) -> (tool: any BackgroundTool, content: GeneratedContent)? {
        guard
            let tool = wrapped as? any BackgroundTool,
            let content = arguments as? any ConvertibleToGeneratedContent
        else {
            return nil
        }
        return (tool, content.generatedContent)
    }
}

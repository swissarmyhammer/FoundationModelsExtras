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

    /// The sink of the events and the records of each call.
    let sink: any OperationEventSink

    /// The sink of the session. A background run lives longer than the call
    /// that starts it, so each background call posts here. The terminal of a
    /// run in a nested mount thus goes to the session as the terminal of that
    /// run.
    let sessionSink: any OperationEventSink

    /// The `"verb noun"` op of the registration, or `nil` for the tool name.
    let op: String?

    /// The tracer of the session, or `nil` for `InstrumentationSystem.tracer`
    /// at call time.
    let tracer: (any Tracer)?

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
    public init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        op: String? = nil,
        tracer: (any Tracer)? = nil
    ) {
        self.init(sessionID: sessionID, runPlane: runPlane, sink: sink, sessionSink: sink, op: op, tracer: tracer)
    }

    /// Makes a mount site whose calls post to `sink`, and whose background
    /// calls post to `sessionSink`.
    ///
    /// - Parameters:
    ///   - sessionID: The session of each call.
    ///   - runPlane: The run plane of the session.
    ///   - sink: The sink of the events and the records of each call.
    ///   - sessionSink: The sink of the session.
    ///   - op: The `"verb noun"` op of the registration, or `nil`.
    ///   - tracer: The tracer of the session, or `nil`.
    init(
        sessionID: ULID,
        runPlane: RunPlane,
        sink: any OperationEventSink,
        sessionSink: any OperationEventSink,
        op: String?,
        tracer: (any Tracer)?
    ) {
        self.sessionID = sessionID
        self.runPlane = runPlane
        self.sink = sink
        self.sessionSink = sessionSink
        self.op = op
        self.tracer = tracer
    }

    /// This site, with the sink of the session as the sink of each call.
    var postingToSession: MountSite {
        MountSite(sessionID: sessionID, runPlane: runPlane, sink: sessionSink, sessionSink: sessionSink, op: op, tracer: tracer)
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
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - site: Where the tool runs.
    ///   - configuration: The mount when the tool declares none.
    /// - Returns: The mounted tool, with the `Arguments` and `Output` of
    ///   `tool`.
    public static func makeWrapped(tool: any Tool, site: MountSite, configuration: ToolMount) -> any Tool {
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

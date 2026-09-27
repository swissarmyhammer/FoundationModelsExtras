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
        self.sessionID = sessionID
        self.runPlane = runPlane
        self.sink = sink
        self.op = op
        self.tracer = tracer
    }
}

/// Mounts a tool of unknown type: it opens the `any Tool` and picks the
/// decorator.
public enum ToolMounting {
    /// Mounts `tool` on `site`.
    ///
    /// A `String` tool runs in the background or to completion. The mount
    /// that the tool declares through ``BackgroundTool/mount`` wins over
    /// `configuration`. Each other tool only gets a bound ``ToolContext``.
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
}

import FoundationModels
import Tracing
import ULID

/// Where a mounted tool runs: the session, its run plane, the sink of its
/// events, the op of the registration, and the tracer of its spans.
struct MountSite: Sendable {
    /// The session of each call.
    let sessionID: ULID

    /// The run plane of the session.
    let runPlane: RunPlane

    /// The sink of the events and the records of each call.
    let sink: any OperationEventSink

    /// The `"verb noun"` op of the registration, or `nil` for the tool name.
    var op: String? = nil

    /// The tracer of the session, or `nil` for `InstrumentationSystem.tracer`
    /// at call time.
    var tracer: (any Tracer)? = nil
}

/// Mounts a tool of unknown type: it opens the `any Tool` and picks the
/// decorator.
enum ToolMounting {
    /// Mounts `tool` on `site`.
    ///
    /// A `String` tool becomes a ``BackgroundToolRunner`` or a
    /// ``RunToCompletionRunner``. The mount that the tool declares through
    /// ``BackgroundTool/mount`` wins over `configuration`. Each other tool
    /// becomes a ``ContextBindingTool``.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - site: Where the tool runs.
    ///   - configuration: The mount when the tool declares none.
    /// - Returns: The mounted tool.
    static func makeWrapped(tool: any Tool, site: MountSite, configuration: ToolMount) -> any Tool {
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

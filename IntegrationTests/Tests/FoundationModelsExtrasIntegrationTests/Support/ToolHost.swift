import Foundation
import FoundationModels
import FoundationModelsExtras
import ULID

/// The host side of one model session: its id, its run plane, and the sink of
/// its events. A test mounts each tool here, as a host does, and then reads
/// what the host saw.
struct ToolHost {
    /// The tool name of the context that the host makes to cancel a run.
    private static let hostToolName = "host"

    /// The op of the context that the host makes to cancel a run.
    private static let hostOp = "cancel run"

    /// The session of each mounted call.
    let sessionID = ULID()

    /// The run plane of the session.
    let runPlane = RunPlane()

    /// Each event that the mounted tools posted to the session, in order.
    let events = EventLog<OperationEvent>()

    /// The settle period of each background call of this session, in
    /// seconds. `0` answers with the pending envelope at once.
    let inlineSettleGrace: TimeInterval

    /// Makes the host of a new session.
    ///
    /// - Parameter inlineSettleGrace: The settle period of each background
    ///   call. The default is ``ToolMount/defaultInlineSettleGrace``.
    init(inlineSettleGrace: TimeInterval = ToolMount.defaultInlineSettleGrace) {
        self.inlineSettleGrace = inlineSettleGrace
    }

    /// `tool` as the model sees it: mounted on this session with
    /// `configuration`, with the failure decorator as the outermost layer. A
    /// failure of the tool thus reaches the model as text, not as a throw.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - configuration: The mount when the tool declares none.
    /// - Returns: The tool for the tool list of the model session.
    func mount(_ tool: any Tool, as configuration: ToolMount = .synchronous) -> any Tool {
        let site = MountSite(
            sessionID: sessionID, runPlane: runPlane, sink: events, inlineSettleGrace: inlineSettleGrace)
        let mounted = ToolMounting.makeWrapped(tool: tool, site: site, configuration: configuration)
        return ToolFailureDelivery.makeWrapped(tool: mounted)
    }

    /// Asks the run plane to cancel a background run, through a context of
    /// this session, as a host does.
    ///
    /// - Parameter completionToken: The completion token of the run.
    /// - Returns: The outcome that the canceler of the run gives.
    func cancel(completionToken: String) async -> CancelOutcome {
        let context = ToolContext(
            sessionID: sessionID, runPlane: runPlane, sink: events, tool: Self.hostToolName, op: Self.hostOp,
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
        return await context.cancel(completionToken: completionToken)
    }
}

extension EventLog: OperationEventSink where Event == OperationEvent {
    /// Adds `event` at the end of the list.
    ///
    /// - Parameter event: The event that a tool posted.
    func post(event: OperationEvent) async {
        append(event)
    }
}

extension EventLog: BackgroundRunSettlementObserver where Event == OperationEvent {
    /// Adds the terminal event of a run that settled by itself at the end of
    /// the list.
    ///
    /// - Parameter terminal: The terminal event of the run.
    func deliver(settledTerminal terminal: OperationEvent) async {
        append(terminal)
    }
}

/// A sink that also takes a ``ToolCallReport``.
///
/// This protocol is apart from ``OperationEventSink`` on purpose. A tool
/// decorator holds its sink as `any OperationEventSink`, and a protocol
/// extension method has static dispatch. Thus the decorator asks the sink at
/// run time, with a cast, if it is also a `ToolCallReportSink`. A sink that is
/// not one drops the report.
public protocol ToolCallReportSink: Sendable {
    /// Gets the report of one call, after the close record of the call.
    ///
    /// - Parameter report: The report of the call that closed.
    func post(report: ToolCallReport) async
}

/// Gets the terminal event of each background run that settles by itself.
///
/// The session mailbox holds its observer weakly, so the observer is a class
/// or an actor.
public protocol BackgroundRunSettlementObserver: AnyObject, Sendable {
    /// Gets the terminal event of one settled run.
    ///
    /// - Parameter terminal: The terminal event of the run.
    func deliver(settledTerminal terminal: OperationEvent) async
}

/// A sink that can take back the events that it staged for a later prompt.
///
/// A background run that settles inside its grace period answers with its
/// result in its own envelope. The staged copy of its events must then not
/// also go in front of the next prompt, so the runner withdraws them. A sink
/// that stages nothing does not conform.
public protocol StagedEventWithdrawing: Sendable {
    /// Removes each event that is staged under `correlationID`.
    ///
    /// - Parameter correlationID: The completion token of the run.
    func withdrawStagedEvents(correlationID: String) async
}

extension OperationEventSink {
    /// Posts the ``ToolCallReport`` of one closed call to this sink, when the
    /// call attached one or more records and this sink is a
    /// ``ToolCallReportSink``.
    ///
    /// - Parameters:
    ///   - record: The close record of the call, already posted.
    ///   - attachments: The records that the call attached, in call order.
    func postToolCallReport(closing record: ToolInvocationRecord, attachments: [ToolCallAttachment]) async {
        guard let report = ToolCallReport(closing: record, attachments: attachments) else { return }
        await (self as? any ToolCallReportSink)?.post(report: report)
    }
}

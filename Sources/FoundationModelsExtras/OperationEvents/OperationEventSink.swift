import ULID

/// A destination `OperationEvent`s are posted to.
///
/// Router implements this one time, in its `SessionOutbox`. The per-call binding layers post every event a tool emits through the ambient `ToolContext`; tools never wire a sink themselves. The contract guarantees only that the host eventually observes each event.
public protocol OperationEventSink: Sendable {
    /// Receives one posted event.
    func post(event: OperationEvent) async

    /// Receives one posted ``ToolInvocationRecord``: an open record before each wrapped call and a close record when it returns, also on throw.
    /// Delivery-only: a record is never staged for a future turn and never recorded to the transcript.
    /// - Parameter record: The record to receive.
    func post(invocation record: ToolInvocationRecord) async

    /// Receives one posted ``ToolDisplayEvent``: output or metadata of a tool
    /// call for the client.
    /// Display-only: the event never goes into the model input, is never
    /// combined with another event, and is never recorded in the journal.
    /// - Parameter event: The event to receive.
    func post(display event: ToolDisplayEvent) async

    /// Receives the end of an accepted URL elicitation.
    ///
    /// The run plane calls this when an accepted URL elicitation completes,
    /// from any source: a call of ``RunPlane/complete(elicitationId:)`` by the
    /// host, or a call of ``ToolContext/complete(elicitationId:)`` by the tool
    /// that asked. A host reports it, for example as the end of the URL flow
    /// to the client.
    ///
    /// The time of this call follows the time of the completion. A host that
    /// completes a URL flow at the consent of the user (today the relay of an
    /// ACP agent does this) makes this call come at consent. A host that
    /// completes the flow at its real end makes this call come at that time.
    ///
    /// - Parameter elicitationId: The id of the elicitation that completed.
    func post(elicitationCompleted elicitationId: ULID) async
}

extension OperationEventSink {
    /// Blanket default: ignores the record.
    public func post(invocation record: ToolInvocationRecord) async {}

    /// Blanket default: ignores the display event.
    public func post(display event: ToolDisplayEvent) async {}

    /// Blanket default: ignores the end of the URL elicitation.
    public func post(elicitationCompleted elicitationId: ULID) async {}
}

/// Opt-in context protocol: a `Context` conforming to this exposes the
/// connected `OperationEventSink` every operation's `execute(in:)` posts
/// `OperationEvent`s through, plus the pure copy-with-sink-replaced
/// `connecting(_:)` that wires it up.
///
/// Conforming is what turns `OperationTool<Context>` into an
/// `EventEmittingTool` (see its conditional conformance in
/// `OperationTool.swift`) — a `Context` that doesn't conform gets no
/// event-posting capability, and `OperationTool`'s `as? any
/// EventEmittingTool` cast simply fails for it.
///
/// **Capture-at-start rule.** An operation that starts long-running work
/// must capture `context.operationEventSink` once, at the start of
/// `execute(in:)`, into whatever outlives the call (e.g. a detached task) —
/// never re-read it later from a context reference that might have changed
/// out from under it. This is what keeps event ownership with the session
/// whose turn started the operation: a later `connecting(_:)` call, made to
/// produce a fresh `Context` for a different session, cannot retroactively
/// redirect events an already-running operation is posting.
public protocol EventEmittingContext: Sendable {
    /// The sink every event this context's operations post flows through,
    /// or `nil` if none is connected — posting is then safely a no-op.
    var operationEventSink: (any OperationEventSink)? { get }

    /// Returns a copy of this context with its `operationEventSink` replaced
    /// by `sink`, sharing every other piece of state — in particular any
    /// reference-typed storage — with the receiver.
    ///
    /// - Parameter sink: The sink the returned context's operations post to.
    /// - Returns: A copy of the receiver routed to `sink`.
    func connecting(_ sink: any OperationEventSink) -> Self
}

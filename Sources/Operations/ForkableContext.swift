/// A `Context` that can produce a per-session copy of itself, derived at
/// fork time.
///
/// Pairs with `ForkableTool`: `OperationTool`'s `forked()` consults
/// `Context`'s conformance to this protocol —
/// `(context as? any ForkableContext)?.forked() ?? context` — so fork
/// semantics live entirely in the `Context` a tool's author writes, never in
/// a host's fork logic. A `Context` that doesn't conform is simply shared
/// unchanged with the forked tool, still sharing whatever reference-typed
/// state it holds.
public protocol ForkableContext: Sendable {
    /// Returns a child session's copy of this context, derived at fork
    /// time.
    ///
    /// The blanket default (below) simply returns a plain copy of the
    /// receiver, sharing every reference-typed piece of state unchanged.
    /// Override to mark, reset, or otherwise adjust state specific to a
    /// forked child session (e.g. a generation counter).
    ///
    /// - Returns: The forked context copy.
    func forked() -> Self
}

extension ForkableContext {
    /// Blanket default: returns a plain copy of the receiver. See
    /// `forked()`'s documentation for what this default does and doesn't do.
    ///
    /// - Returns: `self`.
    public func forked() -> Self { self }
}

import FoundationModelsExtras

/// A `Tool` that can produce a per-session instance of itself, derived at
/// fork time.
///
/// The canonical definition is `FoundationModelsExtras.ForkableTool`, in the
/// core module's `OperationEvents/` folder. This typealias re-exports it so
/// code that imports only `Operations` compiles against the one shared type.
public typealias ForkableTool = FoundationModelsExtras.ForkableTool

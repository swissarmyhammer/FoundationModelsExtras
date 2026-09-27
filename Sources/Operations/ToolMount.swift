import FoundationModelsExtras

/// How a call of an operation runs: in the background or synchronously.
///
/// The canonical definition is `FoundationModelsExtras.ToolMount`, in the
/// core module's `Hosting/` folder. This typealias re-exports it so code that
/// imports only `Operations` can declare the mount of an operation.
public typealias ToolMount = FoundationModelsExtras.ToolMount

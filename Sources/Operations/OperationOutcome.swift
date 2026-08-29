import FoundationModelsExtras

/// How a completed operation run ended.
///
/// The canonical definition is `FoundationModelsExtras.OperationOutcome`, in
/// the core module's `OperationEvents/` folder. This typealias re-exports it
/// so code that imports only `Operations` compiles against the one shared
/// type.
public typealias OperationOutcome = FoundationModelsExtras.OperationOutcome

import FoundationModelsExtras

/// A destination `OperationEvent`s are posted to.
///
/// The canonical definition is `FoundationModelsExtras.OperationEventSink`,
/// in the core module's `OperationEvents/` folder. This typealias re-exports
/// it so code that imports only `Operations` compiles against the one shared
/// type.
public typealias OperationEventSink = FoundationModelsExtras.OperationEventSink

import FoundationModelsExtras

/// The category of a posted `OperationEvent`: whether a long-running
/// operation reports progress, reports completion, or asks the user a
/// question.
///
/// The canonical definition is `FoundationModelsExtras.OperationEventKind`,
/// in the core module's `OperationEvents/` folder. This typealias re-exports
/// it so code that imports only `Operations` compiles against the one shared
/// type.
public typealias OperationEventKind = FoundationModelsExtras.OperationEventKind

/// A standard progress/completion event a long-running operation posts
/// through a connected `OperationEventSink`.
///
/// The canonical definition is `FoundationModelsExtras.OperationEvent`, in
/// the core module's `OperationEvents/` folder. This typealias re-exports it
/// so code that imports only `Operations` compiles against the one shared
/// type.
public typealias OperationEvent = FoundationModelsExtras.OperationEvent

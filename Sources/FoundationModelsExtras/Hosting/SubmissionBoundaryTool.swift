import FoundationModels

/// A `Tool` that the host session calls one time before each submission.
///
/// A submission is one model call. The session calls
/// ``submissionWillBegin()`` after it takes its waiting messages and before
/// the model call. A tool uses this call to apply a change that it prepared
/// before, for example a new surface.
///
/// A host finds these tools with `tool as? any SubmissionBoundaryTool`. The
/// protocol has no associated types, so the cast works on `any Tool`.
public protocol SubmissionBoundaryTool: Tool {
    /// The session calls this one time before each submission.
    func submissionWillBegin() async
}

/// An error that tells that the work is gone and nothing observes it, for
/// example a transport that dropped during a request. A run that throws it
/// settles as ``OperationOutcome/lost``.
public protocol LostRunError: Error {}

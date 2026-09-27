/// A tool that wraps one other tool and takes its place on the mounted list.
///
/// A host that casts a mounted tool thus finds a decorator, not the tool
/// that the caller registered. ``wrapped`` lets a rule go down the chain to
/// that tool.
public protocol ToolDecorator {
    /// The type of the wrapped tool. Each decorator sets it.
    associatedtype Wrapped

    /// The tool beneath this decorator.
    var wrapped: Wrapped { get }
}

extension SubmissionBoundaryTool where Self: ToolDecorator {
    /// Passes the boundary to the wrapped tool when it conforms, and does
    /// nothing when it does not.
    public func submissionWillBegin() async {
        await (wrapped as? any SubmissionBoundaryTool)?.submissionWillBegin()
    }
}

import ArgumentParser
import FoundationModels

/// A CLI leaf command produced for an operation: the type-erasable
/// extension point `OperationsCLI`'s driver uses to reach a parsed leaf's
/// canonical dispatch payload without knowing its concrete type.
///
/// `@Operation`'s macro-generated nested `Command` conforms to this — see
/// `HasCLICommand` for how the driver reaches it generically. Per plan.md's
/// handoff on `Command` emission, `operationPayload()` (not `run()`) is the
/// stable extension point: the driver calls it directly on the parsed
/// instance and dispatches the result through `AnyOperation.run` itself,
/// rather than relying on the leaf's own `run()`.
public protocol OperationCommand: AsyncParsableCommand {
    /// The canonical `op` + fields payload this parsed command represents,
    /// in the identical shape `AnyOperation.run` expects and the model path
    /// sends.
    func operationPayload() -> GeneratedContent
}

/// An `OperationDefinition` whose `@Operation` macro expansion also emitted
/// a nested CLI leaf command.
///
/// `OperationDefinition` itself declares no CLI-facing requirement — the
/// manual escape hatch (plan.md's "Manual escape hatch") has no `Command` to
/// offer. `HasCLICommand` is the separate, macro-only refinement that lets
/// generic code (`AnyOperation`'s initializer, in particular) reach a
/// macro-generated operation's `Command` type through `commandType` without
/// naming `CLICommand` directly, since the caller may only have `O.self`
/// dynamically cast to `any HasCLICommand.Type`.
public protocol HasCLICommand: OperationDefinition {
    /// The macro-generated CLI leaf command for this operation.
    associatedtype CLICommand: OperationCommand
}

extension HasCLICommand {
    /// `CLICommand.self`, type-erased to `any OperationCommand.Type` so
    /// callers that only have `any HasCLICommand.Type` (from a dynamic cast)
    /// can still reach the concrete leaf type without naming `CLICommand`.
    public static var commandType: any OperationCommand.Type {
        CLICommand.self
    }
}

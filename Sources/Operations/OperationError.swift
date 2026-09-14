/// Errors surfaced while resolving, decoding, or dispatching an operation.
///
/// Most of these are not `throw`n across the `FoundationModels.Tool.call`
/// boundary — per plan.md's "Error handling — return, don't throw", the
/// fused `OperationTool` catches them and returns a corrective message as
/// the tool's `String` output so the model can retry within the turn.
/// `AnyOperation.run` throws `OperationError` for the dispatch layer above
/// it to make that translation.
public enum OperationError: Error, Sendable {
    /// No operation matches the resolved `op` string; `valid` lists every
    /// `opString` the registry knows about.
    case unknownOperation(valid: [String])

    /// One or more required parameters were absent from the payload.
    case missingRequired([String])

    /// The payload could not be decoded into the target operation's typed
    /// representation (e.g. `OperationDefinition.init(_:)` threw).
    case decodingFailed

    /// The operation's `Output` could not be JSON-encoded, or the resulting
    /// JSON bytes were not valid UTF-8 (e.g. `JSONEncoder.encode` threw, or
    /// `String(data:encoding:)` returned `nil`).
    case encodingFailed

    /// The operation's `execute(in:)` threw.
    ///
    /// `cause` is the error that `execute(in:)` threw. The description of
    /// this case includes the text of `cause`, so a log or a transcript
    /// tells the reader what went wrong.
    case executionFailed(cause: any Error)
}

extension OperationError: Equatable {
    /// Returns `true` when `lhs` and `rhs` are the same case with equal
    /// values.
    ///
    /// An `any Error` has no `Equatable` conformance, so two
    /// `.executionFailed` values are equal when their causes have the same
    /// dynamic type and the same text.
    ///
    /// - Parameters:
    ///   - lhs: The first error to compare.
    ///   - rhs: The second error to compare.
    /// - Returns: `true` when the two errors are equal.
    public static func == (lhs: OperationError, rhs: OperationError) -> Bool {
        switch (lhs, rhs) {
        case let (.unknownOperation(lhsValid), .unknownOperation(rhsValid)):
            return lhsValid == rhsValid
        case let (.missingRequired(lhsNames), .missingRequired(rhsNames)):
            return lhsNames == rhsNames
        case (.decodingFailed, .decodingFailed), (.encodingFailed, .encodingFailed):
            return true
        case let (.executionFailed(lhsCause), .executionFailed(rhsCause)):
            return type(of: lhsCause) == type(of: rhsCause)
                && String(describing: lhsCause) == String(describing: rhsCause)
        case (.unknownOperation, _), (.missingRequired, _), (.decodingFailed, _),
            (.encodingFailed, _), (.executionFailed, _):
            return false
        }
    }
}

extension OperationError: CustomStringConvertible {
    /// A human-readable, model- and CLI-facing summary of the failure.
    ///
    /// `OperationTool.call(arguments:)` returns this text as its corrective
    /// output for `.unknownOperation` and `.missingRequired` (values it
    /// constructs itself from the resolver's outcome) and for
    /// `.decodingFailed` (caught from `AnyOperation.run`) — see plan.md's
    /// "Error handling — return, don't throw". `.executionFailed` and
    /// `.encodingFailed` aren't part of that contract (`OperationTool`
    /// rethrows them as fatal), but still describe themselves here for
    /// consistent logging. The text of `.executionFailed` starts with its
    /// fixed sentence and then gives the text of its cause.
    public var description: String {
        switch self {
        case let .unknownOperation(valid):
            return "Unknown operation. Valid operations: \(valid.joined(separator: ", "))."
        case let .missingRequired(names):
            return "Missing required parameter(s): \(names.joined(separator: ", "))."
        case .decodingFailed:
            return "Could not parse the given parameter values for this operation."
        case .encodingFailed:
            return "Could not encode this operation's result."
        case let .executionFailed(cause):
            return "This operation failed while executing. Cause: \(cause)"
        }
    }
}

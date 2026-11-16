/// Errors surfaced while resolving, decoding, or dispatching an operation.
///
/// Most of these are not `throw`n across the `FoundationModels.Tool.call`
/// boundary. When a `Tool.call` throws, FoundationModels does not give the
/// error back to the model, and the turn stops. So the fused `OperationTool`
/// catches them and returns a corrective message as the tool's `String`
/// output, and the model can retry within the turn.
/// `AnyOperation.run` throws `OperationError` for the dispatch layer above
/// it to make that translation.
public enum OperationError: Error, Sendable {
    /// No operation matches the resolved `op` string; `valid` lists every
    /// `opString` the registry knows about.
    case unknownOperation(valid: [String])

    /// The payload names no operation, and key-fit inference found no
    /// operation that it can choose. `fitting` lists the `opString` of each
    /// operation whose parameters fit the keys of the payload, also an
    /// operation that is not inferable. `valid` lists every `opString` the
    /// registry knows about.
    case unnamedOperation(fitting: [String], valid: [String])

    /// One or more required parameters were absent from the payload.
    case missingRequired([String])

    /// The payload could not be decoded into the target operation's typed
    /// representation (e.g. `OperationDefinition.init(_:)` threw).
    case decodingFailed

    /// The operation's `Output` could not be JSON-encoded, or the resulting
    /// JSON bytes were not valid UTF-8 (e.g. `JSONEncoder.encode` threw, or
    /// `String(data:encoding:)` returned `nil`).
    case encodingFailed

    /// The operation's `execute(in:)` threw an error other than
    /// `CancellationError` or a `LostRunError`.
    ///
    /// `AnyOperation.run` does not wrap those two errors: it rethrows them as
    /// they are, so the run ends as cancelled or lost, not as failed.
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
        case (.unknownOperation(let lhsValid), .unknownOperation(let rhsValid)):
            return lhsValid == rhsValid
        case (.unnamedOperation(let lhsFitting, let lhsValid), .unnamedOperation(let rhsFitting, let rhsValid)):
            return lhsFitting == rhsFitting && lhsValid == rhsValid
        case (.missingRequired(let lhsNames), .missingRequired(let rhsNames)):
            return lhsNames == rhsNames
        case (.decodingFailed, .decodingFailed), (.encodingFailed, .encodingFailed):
            return true
        case (.executionFailed(let lhsCause), .executionFailed(let rhsCause)):
            return type(of: lhsCause) == type(of: rhsCause)
                && String(describing: lhsCause) == String(describing: rhsCause)
        case (.unknownOperation, _), (.unnamedOperation, _), (.missingRequired, _), (.decodingFailed, _),
            (.encodingFailed, _), (.executionFailed, _):
            return false
        }
    }
}

extension OperationError: CustomStringConvertible {
    /// A human-readable, model- and CLI-facing summary of the failure.
    ///
    /// `OperationTool.call(arguments:)` returns this text as its corrective
    /// output for `.unknownOperation`, `.unnamedOperation` and
    /// `.missingRequired` (values it constructs itself from the resolver's
    /// outcome) and for
    /// `.decodingFailed` (caught from `AnyOperation.run`), so the model can
    /// correct its call within the turn. `.executionFailed` and
    /// `.encodingFailed` aren't part of that contract (`OperationTool`
    /// rethrows them as fatal), but still describe themselves here for
    /// consistent logging. The text of `.executionFailed` starts with its
    /// fixed sentence and then gives the text of its cause.
    public var description: String {
        switch self {
        case .unknownOperation(let valid):
            return "Unknown operation. \(Self.validOperationsText(valid))"
        case .unnamedOperation(let fitting, let valid):
            return Self.unnamedOperationText(fitting: fitting, valid: valid)
        case .missingRequired(let names):
            return "Missing required parameter(s): \(names.joined(separator: ", "))."
        case .decodingFailed:
            return "Could not parse the given parameter values for this operation."
        case .encodingFailed:
            return "Could not encode this operation's result."
        case .executionFailed(let cause):
            return "This operation failed while executing. Cause: \(cause)"
        }
    }
}

extension OperationError {
    /// The corrective text of `.unnamedOperation`. It tells the caller to
    /// name the operation in `op`, then lists the operations that fit the
    /// keys (when there are some), and then lists all valid operations.
    ///
    /// - Parameters:
    ///   - fitting: The op strings of the operations that fit the keys.
    ///   - valid: The op strings of all operations.
    /// - Returns: The corrective text.
    private static func unnamedOperationText(fitting: [String], valid: [String]) -> String {
        let fittingText =
            fitting.isEmpty
            ? "" : "Operations whose parameters fit the given keys: \(fitting.joined(separator: ", ")). "
        return "No operation is named. Name the operation in `op`. \(fittingText)\(validOperationsText(valid))"
    }

    /// The sentence that lists all valid operations, for the corrective text
    /// of `.unknownOperation` and `.unnamedOperation`.
    ///
    /// - Parameter valid: The op strings of all operations.
    /// - Returns: The sentence.
    private static func validOperationsText(_ valid: [String]) -> String {
        "Valid operations: \(valid.joined(separator: ", "))."
    }
}

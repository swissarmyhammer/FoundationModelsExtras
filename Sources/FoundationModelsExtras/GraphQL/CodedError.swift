import Foundation
import GraphQL

/// An error that a GraphQL endpoint gives to the caller in the `errors` list of a response, with a fixed code in
/// `extensions.code`.
///
/// Each package keeps its own error type and conforms it to this protocol, so that the toolkit codes its errors the
/// same way as the errors of ``GraphQLToolkitError``. The ``message`` tells the caller how to correct the call.
public protocol CodedError: Error, Sendable {
    /// The code of the error, as `extensions.code` gives it, for example `NOT_FOUND`.
    var code: String { get }

    /// The message of the error: what is wrong, and how to correct the call.
    var message: String { get }
}

/// The errors of the GraphQL toolkit itself: the errors that each endpoint can give, whatever its schema.
public enum GraphQLToolkitError: CodedError, Hashable {
    /// `INVALID_VARIABLES`: the `variables` of the call are not a JSON object. The value tells what the call sent,
    /// for example `a number`.
    case invalidVariables(received: String)

    /// `SUBSCRIPTION_NOT_IN_TOOL`: the call sent a `subscription` through a model tool. The hint tells the agent what
    /// to do in place of the subscription, or is `nil` for no hint.
    case subscriptionNotInTool(hint: String?)

    /// `GRAPHQL_PARSE_FAILED`: the document has a syntax error. The detail is the message of the GraphQL parser.
    case graphQLParseFailed(detail: String)

    /// `GRAPHQL_VALIDATION_FAILED`: the document is not valid for the schema, for example it has an unknown field
    /// or an argument of the wrong type. The detail is the message of the GraphQL engine, with its "did you mean"
    /// suggestion.
    case graphQLValidationFailed(detail: String)

    /// `AMBIGUOUS_NAME`: the name rewrite matches a name of the document to more than one name of the schema. The
    /// matches are these names.
    case ambiguousName(name: String, matches: [String])

    /// `INTERNAL`: a fault that is not a ``CodedError``. The detail is the message of the GraphQL engine.
    case internalFailure(detail: String)

    /// The text between two items of a list in a message.
    static let listSeparator = ", "

    /// The code of the error, for example `GRAPHQL_PARSE_FAILED`.
    public var code: String {
        switch self {
        case .invalidVariables: "INVALID_VARIABLES"
        case .subscriptionNotInTool: "SUBSCRIPTION_NOT_IN_TOOL"
        case .graphQLParseFailed: "GRAPHQL_PARSE_FAILED"
        case .graphQLValidationFailed: "GRAPHQL_VALIDATION_FAILED"
        case .ambiguousName: "AMBIGUOUS_NAME"
        case .internalFailure: "INTERNAL"
        }
    }

    /// The message of the error: what is wrong, and how to correct the call.
    public var message: String {
        switch self {
        case .invalidVariables(let received):
            "The variables are not a JSON object. The call sent \(received). Send the variables as a JSON object, "
                + "or as a string that holds a JSON object, for example {\"id\": \"^ajv8v4t\"}."
        case .subscriptionNotInTool(let hint):
            ["The tool does not run a subscription.", hint ?? "Send a query or a mutation."].joined(separator: " ")
        case .graphQLParseFailed(let detail), .graphQLValidationFailed(let detail), .internalFailure(let detail):
            detail
        case .ambiguousName(let name, let matches):
            "The name \"\(name)\" matches more than one name: \(matches.joined(separator: Self.listSeparator)). "
                + "Use one of these names."
        }
    }
}

// MARK: - Coded GraphQL errors

extension GraphQLError {
    /// The key of the code in the `extensions` object of an error.
    static let codeKey = "code"

    /// Gives this error with the message and the code of a ``CodedError``.
    ///
    /// The path, the locations, and the nodes of the error do not change.
    ///
    /// - Parameter codedError: The error that gives the message and the code.
    /// - Returns: The error with the message of `codedError`, and its code in `extensions.code`. The other keys of
    ///   `extensions` do not change.
    public func coded(as codedError: any CodedError) -> GraphQLError {
        GraphQLError(
            message: codedError.message,
            nodes: nodes,
            source: source,
            positions: positions,
            path: path,
            originalError: codedError,
            extensions: extensions.merging([Self.codeKey: .string(codedError.code)]) { _, code in code }
        )
    }

    /// Gives an error of the parse of a document with its code: `GRAPHQL_PARSE_FAILED`, or the code of the
    /// ``CodedError`` that the error already holds.
    ///
    /// - Returns: The coded error.
    public func codedAsParseFailure() -> GraphQLError {
        coded(as: originalError as? any CodedError ?? GraphQLToolkitError.graphQLParseFailed(detail: message))
    }

    /// Gives an error of the validation or the execution of a document with its code.
    ///
    /// - A resolver error that is a ``CodedError`` keeps the code of that error.
    /// - An error with no path and no original error comes from the request before execution: validation, the
    ///   values of the variables, or the choice of the operation. It gets `GRAPHQL_VALIDATION_FAILED`.
    /// - Each other error is a fault of the execution. It gets `INTERNAL`.
    ///
    /// The message of the engine does not change, except for a ``CodedError``.
    ///
    /// - Returns: The coded error.
    public func codedAsResultError() -> GraphQLError {
        if let codedError = originalError as? any CodedError {
            return coded(as: codedError)
        }
        guard originalError != nil || !path.elements.isEmpty else {
            return coded(as: GraphQLToolkitError.graphQLValidationFailed(detail: message))
        }
        return coded(as: GraphQLToolkitError.internalFailure(detail: message))
    }
}

// MARK: - Error JSON

/// The GraphQL error JSON of a ``CodedError``: `{ message, path, extensions: { code } }`.
public struct CodedErrorJSON: Codable, Hashable, Sendable {
    /// One step of the `path` of a GraphQL error: the response key of a field, or the index of a list item.
    ///
    /// The JSON form is a string for a key and a number for an index, as the GraphQL specification tells.
    public enum PathComponent: Codable, Hashable, Sendable {
        /// The response key of a field, for example `addTask`.
        case key(String)

        /// The index of an item in a list.
        case index(Int)

        /// Reads a path step from a JSON number or a JSON string.
        ///
        /// - Parameter decoder: The decoder that holds one value.
        /// - Throws: A `DecodingError` when the value is not a number or a string.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let position = try? container.decode(Int.self) {
                self = .index(position)
            } else {
                self = .key(try container.decode(String.self))
            }
        }

        /// Writes the path step as a JSON string for a key, or a JSON number for an index.
        ///
        /// - Parameter encoder: The encoder that gets one value.
        /// - Throws: An error from the encoder.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .key(let name):
                try container.encode(name)
            case .index(let position):
                try container.encode(position)
            }
        }
    }

    /// The `extensions` object of a GraphQL error.
    public struct Extensions: Codable, Hashable, Sendable {
        /// The code of the error, for example `NOT_FOUND`.
        public let code: String

        /// Makes the `extensions` object of an error.
        ///
        /// - Parameter code: The code of the error.
        public init(code: String) {
            self.code = code
        }
    }

    /// The message of the error.
    public let message: String

    /// The path to the response field of the error. The path is empty when no field caused the error.
    public let path: [PathComponent]

    /// The `extensions` object, which holds the code.
    public let extensions: Extensions

    /// Makes the error JSON of a ``CodedError``.
    ///
    /// - Parameters:
    ///   - error: The error.
    ///   - path: The path to the response field of the error. Leave it empty when no field caused the error, for
    ///     example for `INVALID_VARIABLES`.
    public init(_ error: any CodedError, at path: [PathComponent] = []) {
        message = error.message
        self.path = path
        extensions = Extensions(code: error.code)
    }
}

/// The JSON of a response that holds only errors, no `data`, and the warnings of the call when it has some.
private struct ErrorOnlyResponse: Encodable {
    /// The `extensions` object of the response, which holds the warnings.
    struct Extensions: Encodable {
        /// The warnings of the call, in the order that the call added them.
        let warnings: [ResponseWarning]
    }

    /// The errors of the response.
    let errors: [CodedErrorJSON]

    /// The `extensions` object, or `nil` for a call with no warning. The encoder leaves out the key when the value
    /// is `nil`.
    let extensions: Extensions?
}

extension CodedError {
    /// Makes the GraphQL response of a call that fails as a whole with this error: `{"errors": [...]}`, with no
    /// `data`. The warnings that the call collected before it failed go in `extensions.warnings`, so that the agent
    /// sees them also on this path. The keys are in sorted order, and a `/` is not escaped, the same as each other
    /// response of the toolkit.
    ///
    /// - Parameter warnings: The warnings of the call. With no warning, the response has no `extensions` key.
    /// - Returns: The response as JSON text.
    /// - Throws: An error from the JSON encoder.
    public func responseJSON(warnings: [ResponseWarning] = []) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let extensions = warnings.isEmpty ? nil : ErrorOnlyResponse.Extensions(warnings: warnings)
        let response = ErrorOnlyResponse(errors: [CodedErrorJSON(self)], extensions: extensions)
        return String(decoding: try encoder.encode(response), as: UTF8.self)
    }
}

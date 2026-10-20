import Graphiti
import GraphQL

/// The context of one run of a document through the toolkit: it holds the warnings of the run, and gives the more
/// `extensions` keys of the response.
///
/// Make a new context for each call, so that the warnings of one call do not go into the response of a different
/// call.
public protocol GraphQLRunContext: Sendable {
    /// The warnings of the run, for `extensions.warnings`.
    var warnings: ResponseWarnings { get }

    /// Gives the more keys of `extensions` after the run, for example `txn` of an endpoint with transactions. The
    /// default gives none.
    ///
    /// - Returns: The keys and their values.
    func responseExtensions() async -> [String: Map]
}

extension GraphQLRunContext {
    /// Gives no more key of `extensions`.
    ///
    /// - Returns: An empty map.
    public func responseExtensions() async -> [String: Map] {
        [:]
    }
}

extension API where ContextType: GraphQLRunContext {
    /// The schema in the GraphQL schema definition language (SDL).
    public var sdl: String {
        printSchema(schema: schema.schema)
    }

    /// Runs one GraphQL document, and returns the response as JSON text.
    ///
    /// The response follows the GraphQL specification: `{"data": …}`, and `"errors"` when the document has an error.
    /// A GraphQL error does not throw: a document that does not parse gives a response with one error and no `data`.
    /// Each error has `extensions.code`: an error that a resolver threw as a ``CodedError`` has its message and code,
    /// and a field that failed is `null`. With no formatting, the keys of `data` are in the order of the selection. A
    /// `/` is not escaped.
    ///
    /// The name rewrite changes the document and the keys of each `input` object in `variables` before validation,
    /// and the response has each change in `extensions.rewrites`. A name that matches two or more names gives an
    /// error, and the document does not run.
    ///
    /// The response has the warnings that the run added to the context in `extensions.warnings`, also when the
    /// document does not parse. The warnings of the removed parameters that the rewrite took out come first. A run
    /// with no warning has no `extensions.warnings` key. The more keys of
    /// ``GraphQLRunContext/responseExtensions()`` go in `extensions` too.
    ///
    /// - Parameters:
    ///   - document: The GraphQL document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil` when the document has one operation.
    ///   - rules: The rules of the name rewrite.
    ///   - formatting: The formatting of the JSON text, for example `.sortedKeys`. Slashes are never escaped.
    ///   - context: The context of each resolver.
    /// - Returns: The response as JSON text.
    /// - Throws: An error that is not a GraphQL error, for example an error from the JSON encoder.
    public func respond(
        to document: String,
        variables: [String: Map] = [:],
        operationName: String? = nil,
        rules: GraphQLNameRules = .standard,
        formattedWith formatting: GraphQLJSONEncoder.OutputFormatting = [],
        context: ContextType
    ) async throws -> String {
        let answerParseFailure: (GraphQLError) async throws -> String = { error in
            try GraphQLResponse(
                result: GraphQLResult(errors: [error.codedAsParseFailure()]),
                warnings: await context.warnings.list,
                extensions: await context.responseExtensions()
            ).json(formattedWith: formatting)
        }
        let rewritten: RewrittenDocument
        do {
            rewritten = try DocumentRewriter(for: schema.schema, rules: rules).rewrittenDocument(
                from: document,
                variables: variables,
                operationName: operationName
            )
        } catch let error as GraphQLError {
            return try await answerParseFailure(error)
        }
        await context.warnings.add(contentsOf: rewritten.warnings)
        let result: GraphQLResult
        do {
            result = try await self.result(of: rewritten, operationName: operationName, context: context)
        } catch let error as GraphQLError {
            return try await answerParseFailure(error)
        }
        return try GraphQLResponse(
            result: result,
            rewrites: rewritten.rewrites,
            warnings: await context.warnings.list,
            extensions: await context.responseExtensions()
        ).json(formattedWith: formatting)
    }

    /// Starts one subscription document, and gives the response of each event as JSON text.
    ///
    /// The name rewrite changes the document first, the same as for a call. A document that does not parse or
    /// validate, and a subscription that cannot start, give a stream with one response with the errors and no
    /// `data`, and the stream then ends.
    ///
    /// The warnings list is for a call: a response of a subscription has no `extensions.warnings`.
    ///
    /// - Parameters:
    ///   - document: The subscription document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil` when the document has one operation.
    ///   - rules: The rules of the name rewrite.
    ///   - formatting: The formatting of the JSON text. Slashes are never escaped.
    ///   - context: The context of each resolver, for the start and for each event.
    /// - Returns: The response of each event, in the order of the events.
    /// - Throws: An error that is not a GraphQL error, for example an error from the JSON encoder.
    public func subscribe(
        to document: String,
        variables: [String: Map] = [:],
        operationName: String? = nil,
        rules: GraphQLNameRules = .standard,
        formattedWith formatting: GraphQLJSONEncoder.OutputFormatting = [],
        context: ContextType
    ) async throws -> AsyncThrowingStream<String, Error> {
        let rewritten: RewrittenDocument
        do {
            rewritten = try DocumentRewriter(for: schema.schema, rules: rules).rewrittenDocument(
                from: document,
                variables: variables,
                operationName: operationName
            )
        } catch let error as GraphQLError {
            let response = GraphQLResponse(result: GraphQLResult(errors: [error.codedAsParseFailure()]))
            return .single(try response.json(formattedWith: formatting))
        }
        let encode: @Sendable (GraphQLResult) throws -> String = { result in
            try GraphQLResponse(result: rewritten.codedCallerResult(from: result), rewrites: rewritten.rewrites)
                .json(formattedWith: formatting)
        }
        guard rewritten.ties.isEmpty else {
            return .single(try encode(GraphQLResult(errors: rewritten.ties)))
        }
        let started = try await subscribe(
            request: rewritten.text,
            context: context,
            variables: rewritten.variables,
            operationName: operationName
        )
        switch started {
        case .success(let results):
            return .encoding(results, with: encode)
        case .failure(let failure):
            return .single(try encode(GraphQLResult(errors: failure.errors)))
        }
    }

    /// Runs a rewritten document, and gives the result in the form of the document that the caller wrote.
    ///
    /// The run binds a ``ResolverWarnings`` collector, so that the warnings of synchronous resolver code go into the
    /// warnings of the context.
    ///
    /// - Parameters:
    ///   - rewritten: The document and the values of its variables after the name rewrite.
    ///   - operationName: The operation of the document to run, or `nil`.
    ///   - context: The context of each resolver.
    /// - Returns: The result, or the tie errors and no `data` when a name of the document or a key of a variable has a
    ///   tie.
    /// - Throws: A `GraphQLError` when the rewritten text does not parse, or an error that is not a GraphQL error.
    private func result(
        of rewritten: RewrittenDocument,
        operationName: String?,
        context: ContextType
    ) async throws -> GraphQLResult {
        guard rewritten.ties.isEmpty else {
            return GraphQLResult(errors: rewritten.ties)
        }
        let result = try await ResolverWarnings.collecting(into: context.warnings) {
            try await execute(
                request: rewritten.text,
                context: context,
                variables: rewritten.variables,
                operationName: operationName
            )
        }
        return rewritten.codedCallerResult(from: result)
    }
}

extension AsyncThrowingStream where Element == String, Failure == Error {
    /// Gives a stream of one response that then ends: the response of a subscription that cannot start.
    ///
    /// - Parameter response: The response JSON text.
    /// - Returns: The stream.
    static func single(_ response: String) -> Self {
        AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }

    /// Gives the response of each event of a subscription as JSON text. The stream ends when the results end, and it
    /// stops reading the results when the reader of the stream stops.
    ///
    /// - Parameters:
    ///   - results: The result of each event.
    ///   - encode: Gives the response JSON text of one result.
    /// - Returns: The stream.
    fileprivate static func encoding(
        _ results: AsyncThrowingStream<GraphQLResult, Error>,
        with encode: @escaping @Sendable (GraphQLResult) throws -> String
    ) -> Self {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await result in results {
                        continuation.yield(try encode(result))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}

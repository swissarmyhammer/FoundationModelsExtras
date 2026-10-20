import FoundationModels
import GraphQL

/// A GraphQL model tool over one ``GraphQLEndpoint``: one GraphQL document goes in, and one `{data, errors}` response
/// comes out.
///
/// The tool and the endpoint are two front ends over one engine: the tool calls the endpoint with no viewer, because a
/// model tool call has no client. The tool gives its endpoint through ``GraphQLEndpointTool``, so a host registers the
/// same engine for its clients.
///
/// The tool does not run a subscription. When the selected operation is a `subscription`, the tool gives the error
/// `SUBSCRIPTION_NOT_IN_TOOL`. Variables that are not a JSON object give the error `INVALID_VARIABLES`. In both cases
/// the endpoint runs nothing.
public struct GraphQLTool: GraphQLEndpointTool {
    /// The name of the tool.
    public let name: String

    /// The description of the tool for the model.
    public let description: String

    /// The schema of the arguments: ``GraphQLArguments/generationSchema``.
    public var parameters: GenerationSchema {
        GraphQLArguments.generationSchema
    }

    /// The endpoint that runs each document.
    private let endpoint: any GraphQLEndpoint

    /// The text of the `SUBSCRIPTION_NOT_IN_TOOL` error that tells the agent what to do in place of a subscription,
    /// or `nil` for the general text.
    private let subscriptionHint: String?

    /// Makes the tool over an endpoint.
    ///
    /// - Parameters:
    ///   - name: The name of the tool, or `nil` for the name of the endpoint.
    ///   - description: The description of the tool for the model.
    ///   - endpoint: The endpoint that runs each document.
    ///   - subscriptionHint: What the agent can do in place of a subscription, or `nil` for the general text.
    public init(
        name: String? = nil,
        description: String,
        endpoint: any GraphQLEndpoint,
        subscriptionHint: String? = nil
    ) {
        self.name = name ?? endpoint.name
        self.description = description
        self.endpoint = endpoint
        self.subscriptionHint = subscriptionHint
    }

    /// The endpoint of the tool: a list of one.
    public var graphQLEndpoints: [any GraphQLEndpoint] {
        [endpoint]
    }

    /// Runs the document of the arguments against the endpoint.
    ///
    /// - Parameter arguments: The decoded arguments of the call.
    /// - Returns: The GraphQL response (`{data, errors}`) as JSON text.
    /// - Throws: A fault of the endpoint that is not a GraphQL error.
    public func call(arguments: GraphQLArguments) async throws -> String {
        try await Self.answer(arguments, subscriptionHint: subscriptionHint) { query, variables, operationName in
            try await endpoint.execute(query: query, variables: variables, operationName: operationName, viewer: nil)
        }
    }

    /// Gives the response of one call of a GraphQL model tool: the checks of the arguments, then the run.
    ///
    /// A tool with its own run, for example one that also reads the tool context of the call, uses this step so that
    /// it gives the same errors as ``GraphQLTool``.
    ///
    /// - Parameters:
    ///   - arguments: The decoded arguments of the call.
    ///   - subscriptionHint: What the agent can do in place of a subscription, or `nil` for the general text.
    ///   - run: Runs the document, its variables, and the name of its operation, and gives the response.
    /// - Returns: `INVALID_VARIABLES` for variables that are not a JSON object, `SUBSCRIPTION_NOT_IN_TOOL` for a
    ///   subscription, else the response of `run`.
    /// - Throws: The error of `run`, or an error from the JSON encoder.
    public static func answer(
        _ arguments: GraphQLArguments,
        subscriptionHint: String? = nil,
        run: (String, [String: Map], String?) async throws -> String
    ) async throws -> String {
        if let received = arguments.variablesError {
            return try GraphQLToolkitError.invalidVariables(received: received).responseJSON()
        }
        if arguments.selectsSubscription {
            return try GraphQLToolkitError.subscriptionNotInTool(hint: subscriptionHint).responseJSON()
        }
        return try await run(arguments.query, arguments.variables, arguments.operationName)
    }
}

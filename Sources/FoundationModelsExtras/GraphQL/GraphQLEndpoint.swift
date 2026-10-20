import GraphQL

/// The scope of a ``GraphQLEndpoint``: the place whose state the endpoint reads and changes.
///
/// The raw values are the wire values of the GraphQL tunnel of ACP: `sessionFolder` and `server`.
public enum GraphQLEndpointScope: String, Codable, CaseIterable, Hashable, Sendable {
    /// The endpoint reads the folder of one session, for example the board in `<cwd>/.kanban`. A host keeps one
    /// endpoint for each folder, and the session id of a call selects the folder.
    case sessionFolder

    /// The endpoint reads the state of the server. A host keeps one endpoint for its name, and a call needs no
    /// session id.
    case server
}

/// A named GraphQL endpoint that runs on the server side.
///
/// An endpoint has a name, a version, a scope and an SDL schema. ``execute(query:variables:operationName:viewer:)``
/// gives the JSON result of one document as text, and ``subscribe(query:variables:operationName:viewer:)`` gives one
/// JSON text for each event of a subscription. A GraphQL error does not throw: the response holds it in `errors`.
///
/// The protocol uses no ACP type. A package owns its endpoint, and a host registers each endpoint that it finds, for
/// example through ``GraphQLEndpointTool``.
public protocol GraphQLEndpoint: Sendable {
    /// The name of the endpoint, for example `kanban`. A client finds the endpoint by this name.
    var name: String { get }

    /// The version of the schema of the endpoint, for example `1`.
    var version: String { get }

    /// The scope of the endpoint.
    var scope: GraphQLEndpointScope { get }

    /// The schema of the endpoint in the GraphQL schema definition language (SDL).
    var schema: String { get }

    /// Runs one GraphQL document.
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil` when the document has one operation.
    ///   - viewer: The client that makes the call, or `nil` for the agent of the session itself, for example a
    ///     model tool call.
    /// - Returns: The GraphQL response (`{data, errors, extensions}`) as JSON text.
    /// - Throws: A fault that is not a GraphQL error, for example an I/O fault of the engine.
    func execute(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> String

    /// Starts one GraphQL subscription.
    ///
    /// - Parameters:
    ///   - query: The subscription document.
    ///   - variables: The values of the variables of the document.
    ///   - operationName: The operation of the document to run, or `nil` when the document has one operation.
    ///   - viewer: The client that makes the call, or `nil` for the agent of the session itself.
    /// - Returns: The GraphQL response of each event as JSON text. A document that cannot start gives a stream of one
    ///   response with the errors, and the stream then ends.
    /// - Throws: A fault that is not a GraphQL error, for example an I/O fault of the engine.
    func subscribe(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error>
}

extension GraphQLEndpoint {
    /// The description of the endpoint that a host lists to its clients.
    public var endpointDescription: GraphQLEndpointDescription {
        GraphQLEndpointDescription(name: name, version: version, scope: scope, schema: schema)
    }
}

/// The description of one ``GraphQLEndpoint``: its name, its version, its scope and its SDL schema.
///
/// The JSON form has the keys `name`, `version`, `scope` and `schema`, the same as an endpoint in the list of the
/// GraphQL tunnel of ACP.
public struct GraphQLEndpointDescription: Codable, Hashable, Sendable {
    /// The name of the endpoint.
    public var name: String

    /// The version of the schema of the endpoint.
    public var version: String

    /// The scope of the endpoint.
    public var scope: GraphQLEndpointScope

    /// The schema of the endpoint in SDL.
    public var schema: String

    /// Makes the description of an endpoint.
    ///
    /// - Parameters:
    ///   - name: The name of the endpoint.
    ///   - version: The version of the schema of the endpoint.
    ///   - scope: The scope of the endpoint.
    ///   - schema: The schema of the endpoint in SDL.
    public init(name: String, version: String, scope: GraphQLEndpointScope, schema: String) {
        self.name = name
        self.version = version
        self.scope = scope
        self.schema = schema
    }
}

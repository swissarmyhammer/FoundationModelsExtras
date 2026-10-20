import FoundationModels

/// A `Tool` that also gives one or more ``GraphQLEndpoint`` values for use in code.
///
/// A model tool of server state conforms, and gives its endpoints over the same engine that the tool uses, so the
/// model and a client see the same data and the same rules. A host finds these tools with
/// `tool as? any GraphQLEndpointTool`. The protocol declares no associated types, so that cast succeeds on an
/// `any Tool` existential.
public protocol GraphQLEndpointTool: Tool {
    /// The endpoints of the tool. A tool can give zero, one or more endpoints.
    var graphQLEndpoints: [any GraphQLEndpoint] { get }
}

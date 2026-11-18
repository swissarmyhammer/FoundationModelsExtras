import GraphQL
import Graphiti
import Testing

@testable import FoundationModelsExtras

/// Proves that a resolver can add a rewrite to `extensions.rewrites` of the response through ``ResolverRewrites``.
@Suite("Resolver rewrites")
struct ResolverRewritesTests {
    /// The rules of the tests: `addr` is an alias of the root field `address`.
    static let rules = GraphQLNameRules(aliases: GraphQLAliasTable(everywhere: ["address": ["addr"]]))

    /// Runs one document through the schema of the tests.
    ///
    /// - Parameter document: The GraphQL document.
    /// - Returns: The response as JSON text.
    /// - Throws: An error that is not a GraphQL error.
    static func respond(to document: String) async throws -> String {
        try await RewriteAPI().respond(
            to: document,
            rules: rules,
            formattedWith: .sortedKeys,
            context: RewriteContext()
        )
    }

    @Test("a resolver that adds one rewrite gives it in extensions.rewrites")
    func resolverRewriteIsInTheResponse() async throws {
        let response = try await Self.respond(to: #"{ address(to: "@Agent") }"#)

        #expect(try ResponseJSON.rewrites(response) == ["@Agent→@agent"])
    }

    @Test("the name rewrite comes first, then the resolver rewrite")
    func nameRewriteComesBeforeTheResolverRewrite() async throws {
        let response = try await Self.respond(to: #"{ addr(to: "@Agent") }"#)

        #expect(try ResponseJSON.rewrites(response) == ["addr→address", "@Agent→@agent"])
    }

    @Test("two adds of the same rewrite give one item")
    func sameRewriteIsAddedOneTime() async throws {
        let response = try await Self.respond(to: #"{ first: address(to: "@Agent") second: address(to: "@Agent") }"#)

        #expect(try ResponseJSON.rewrites(response) == ["@Agent→@agent"])
    }

    @Test("a resolver in a child task adds a rewrite that the response gives")
    func childTaskRewriteIsInTheResponse() async throws {
        let response = try await Self.respond(to: #"{ addresses(to: ["@Agent", "@Other"]) { canonical } }"#)

        #expect(Set(try ResponseJSON.rewrites(response)) == ["@Agent→@agent", "@Other→@other"])
    }

    @Test("a run with no rewrite has no extensions.rewrites key")
    func runWithNoRewriteHasNoRewritesKey() async throws {
        let response = try await Self.respond(to: #"{ address(to: "@agent") }"#)

        #expect(response == #"{"data":{"address":"@agent"}}"#)
    }

    @Test("an add with no bound collector does nothing")
    func addWithNoCollectorDoesNothing() {
        ResolverRewrites.current?.add(NameRewrite(from: "@Agent", to: "@agent", path: ["address", "to"]))

        #expect(ResolverRewrites.current == nil)
    }

    @Test("two runs at the same time do not mix their rewrites")
    func concurrentRunsKeepTheirOwnRewrites() async throws {
        let written = ["@First", "@Second"]

        let rewrites = try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for address in written {
                group.addTask {
                    let response = try await Self.respond(to: #"{ address(to: "\#(address)") }"#)
                    return (address, try ResponseJSON.rewrites(response))
                }
            }
            return try await group.reduce(into: [String: [String]]()) { rewrites, run in rewrites[run.0] = run.1 }
        }

        #expect(rewrites == ["@First": ["@First→@first"], "@Second": ["@Second→@second"]])
    }
}

/// The context of one run of the schema of the tests.
struct RewriteContext: GraphQLRunContext {
    let warnings = ResponseWarnings()
}

/// The arguments of `address`.
struct AddressArguments: Codable, Sendable {
    /// The address as the caller wrote it.
    let to: String
}

/// The arguments of `addresses`.
struct AddressesArguments: Codable, Sendable {
    /// Each address as the caller wrote it.
    let to: [String]
}

/// One address that the caller wrote. Its field `canonical` is async, so the engine can resolve it in a child task.
struct RewriteAddress: Codable, Sendable {
    /// The address as the caller wrote it.
    let written: String

    /// Resolves `Address.canonical`, and adds a rewrite when the canonical form is different.
    func canonical(context _: RewriteContext, arguments _: NoArguments) async -> String {
        await Task.yield()
        return RewriteResolver.canonical(of: written, at: ["addresses", "to"])
    }
}

/// The root resolver of the schema of the tests.
struct RewriteResolver: Sendable {
    /// Gives the canonical form of an address, in lowercase, and adds a rewrite when the caller wrote another form.
    ///
    /// - Parameters:
    ///   - written: The address as the caller wrote it.
    ///   - path: The path of the value in the document.
    /// - Returns: The canonical form.
    static func canonical(of written: String, at path: [String]) -> String {
        let canonical = written.lowercased()
        if canonical != written {
            ResolverRewrites.current?.add(NameRewrite(from: written, to: canonical, path: path))
        }
        return canonical
    }

    /// Resolves `Query.address`, with no `await`.
    func address(context _: RewriteContext, arguments: AddressArguments) -> String {
        Self.canonical(of: arguments.to, at: ["address", "to"])
    }

    /// Resolves `Query.addresses`.
    func addresses(context _: RewriteContext, arguments: AddressesArguments) -> [RewriteAddress] {
        arguments.to.map { written in RewriteAddress(written: written) }
    }
}

/// The Graphiti engine of the tests.
struct RewriteAPI: API {
    let resolver = RewriteResolver()
    let schema: Schema<RewriteResolver, RewriteContext>

    /// Builds the schema.
    init() throws {
        schema = try SchemaBuilder(RewriteResolver.self, RewriteContext.self)
            .add {
                Type(RewriteAddress.self, as: "Address") {
                    Field("canonical", at: RewriteAddress.canonical).description("The canonical form.")
                }
                .description("One address.")
            }
            .addQuery {
                Field("address", at: RewriteResolver.address) {
                    Argument("to", at: \.to).description("The address.")
                }
                .description("Gives the canonical form of an address.")
                Field("addresses", at: RewriteResolver.addresses) {
                    Argument("to", at: \.to).description("The addresses.")
                }
                .description("Gives each address.")
            }
            .build()
    }
}

import Foundation
import Graphiti
import GraphQL
import Testing

@testable import FoundationModelsExtras

/// The context of one call of the change feed example.
struct ChangeFeedContext: GraphQLRunContext {
    let warnings = ResponseWarnings()
}

/// The arguments of `Subscription.noteChanges`.
struct NoteChangesArguments: Codable, Sendable {
    /// The cursor to resume after, or `nil` for the live changes only.
    let after: String?
}

/// The root resolver of the change feed example: the notes change log, and its `changes` subscription.
struct ChangeFeedResolver: Sendable {
    /// The change log of the notes.
    let log: ChangeLog<ChangedIDs>

    /// Resolves `Query.cursor`: the newest cursor of the notes.
    func cursor(context _: ChangeFeedContext, arguments _: NoArguments) async -> String {
        await log.cursor
    }

    /// Resolves the source stream of `Subscription.noteChanges`.
    func noteChanges(
        context _: ChangeFeedContext,
        arguments: NoteChangesArguments
    ) async -> AsyncThrowingStream<ChangeLogEntry<ChangedIDs>, Error> {
        await log.changes(after: arguments.after)
    }
}

/// A small Graphiti engine with a `noteChanges` subscription over a ``ChangeLog``, so that the tests run a
/// subscription through the toolkit from the document to the response JSON.
struct ChangeFeedAPI: API {
    let resolver: ChangeFeedResolver
    let schema: Schema<ChangeFeedResolver, ChangeFeedContext>

    /// Builds the schema over a change log.
    ///
    /// - Parameter log: The change log of the notes.
    init(log: ChangeLog<ChangedIDs>) throws {
        resolver = ChangeFeedResolver(log: log)
        schema = try SchemaBuilder(ChangeFeedResolver.self, ChangeFeedContext.self)
            .addToolkitScalars()
            .addToolkitIDScalar()
            .add {
                Type(IDChange.self, as: "NoteChange") {
                    Field("cursor", at: \.cursor).description("The cursor that resumes after this change.")
                    Field("at", at: \.at).description("The time of the change.")
                    Field("added", at: \.added).description("The ids of the added notes.")
                    Field("changed", at: \.changed).description("The ids of the changed notes.")
                    Field("removed", at: \.removed).description("The ids of the removed notes.")
                }
                .description("One change of the notes.")
            }
            .addQuery {
                Field("cursor", at: ChangeFeedResolver.cursor).description("The newest cursor of the notes.")
            }
            .addSubscription {
                SubscriptionField(
                    "noteChanges",
                    at: { (entry: ChangeLogEntry<ChangedIDs>) in
                        { (_: ChangeFeedContext, _: NoteChangesArguments) async throws -> IDChange in IDChange(entry) }
                    },
                    atSub: ChangeFeedResolver.noteChanges
                ) {
                    Argument("after", at: \.after).description("The cursor to resume after.")
                }
                .description("The changes of the notes.")
            }
            .build()
    }
}

/// Proves that a `changes` subscription over a ``ChangeLog`` runs through the toolkit, and that a
/// `RESYNC_REQUIRED` that ends it reaches the caller as a response with `extensions.code`.
@Suite("ChangeLog subscription")
struct ChangeLogSubscriptionTests {
    /// The subscription document of the tests.
    static let document = "subscription Changes($after: String) { noteChanges(after: $after) { cursor added } }"

    /// Starts the subscription after a cursor.
    ///
    /// - Parameters:
    ///   - api: The engine.
    ///   - cursor: The cursor to resume after.
    /// - Returns: The response of each event.
    /// - Throws: An error that is not a GraphQL error.
    static func subscribe(
        _ api: ChangeFeedAPI,
        after cursor: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await api.subscribe(
            to: document,
            variables: ["after": .string(cursor)],
            formattedWith: .sortedKeys,
            context: ChangeFeedContext()
        )
    }

    @Test("a change of the log reaches the subscriber as a response with the cursor and the ids")
    func changeReachesTheSubscriber() async throws {
        let log = ChangeLog<ChangedIDs>()
        let api = try ChangeFeedAPI(log: log)
        let stream = try await Self.subscribe(api, after: await log.cursor)

        let entry = await log.append(ChangedIDs(added: ["n2"]))
        var iterator = stream.makeAsyncIterator()
        let response = try #require(try await iterator.next())

        #expect(response == #"{"data":{"noteChanges":{"added":["n2"],"cursor":"\#(entry.cursor)"}}}"#)
    }

    @Test("a cursor that does not parse gives one response with RESYNC_REQUIRED, and the stream ends")
    func resyncReachesTheCallerWithItsCode() async throws {
        let api = try ChangeFeedAPI(log: ChangeLog<ChangedIDs>())

        var responses: [String] = []
        for try await response in try await Self.subscribe(api, after: "not a cursor") {
            responses.append(response)
        }

        let response = try #require(responses.first)
        #expect(responses.count == 1)
        #expect(try ResponseJSON.codes(response) == ["RESYNC_REQUIRED"])
        #expect(response.contains("Query the state again, then subscribe with the new cursor."))
    }
}

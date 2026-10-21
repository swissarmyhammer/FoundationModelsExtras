import Foundation
import Graphiti
import GraphQL

@testable import FoundationModelsExtras

/// A small `notes` endpoint built only from the GraphQL toolkit: the example that the toolkit tests run against.
///
/// The schema has a root container field `shelf`, so the root query fields `note` and `notes` can move into it, an
/// `input` type with a list field, an enum, the `DateTime` and `JSON` scalars, a resolver that throws a coded error,
/// and a resolver that adds a warning with no `await`. It obeys each rule of ``GraphQLConventionRule``: the root
/// query `cursor` and the subscription `changes(after:)` read a ``ChangeLog``, and each mutation takes one `input`.
struct ExampleGraph: GraphQLEndpoint {
    /// The name of the endpoint.
    static let endpointName = "notes"

    /// The note that the store holds at the start.
    static let firstNote = ExampleNote(id: "n1", title: "First", body: "The first note.", tags: ["a"], state: .open)

    /// The time that `Query.now` gives.
    static let now = DateTime(millisecondsSince1970: 1_791_000_000_123)

    /// The rules of the example: one alias of each table kind, the root container, and one removed parameter.
    static let rules = GraphQLNameRules(
        aliases: GraphQLAliasTable(
            everywhere: ["body": ["description"]],
            inEachInput: ["body": ["content"]],
            byType: ["Note": ["state": ["status"]]],
            byField: ["Shelf.notes": ["first": ["limit"]]]
        ),
        rootContainer: GraphQLRootContainer(field: "shelf", responseKeyPrefix: "_shelfRoot"),
        removedParameters: [GraphQLRemovedParameter(name: "exclude_done", replacement: "use the state field.")]
    )

    /// The probe of the conformance check: a field alias of the example.
    static let aliasProbe = GraphQLAliasProbe(
        query: "{ shelf { note(id: \"n1\") { description } } }",
        from: "description",
        to: "body"
    )

    let name = endpointName
    let version = "1"
    let scope = GraphQLEndpointScope.sessionFolder

    /// The engine of the endpoint.
    let api: ExampleAPI

    /// The transaction id that each response gives in `extensions.txn`, or `nil` for none.
    let transaction: String?

    /// Makes the example endpoint.
    ///
    /// - Parameter transaction: The transaction id that each response gives in `extensions.txn`, or `nil` for none.
    init(transaction: String? = nil) throws {
        api = try ExampleAPI()
        self.transaction = transaction
    }

    var schema: String {
        api.sdl
    }

    func execute(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> String {
        try await api.respond(
            to: query,
            variables: variables,
            operationName: operationName,
            rules: Self.rules,
            formattedWith: .sortedKeys,
            context: ExampleContext(viewer: viewer, transaction: transaction)
        )
    }

    func subscribe(
        query: String,
        variables: [String: Map],
        operationName: String?,
        viewer: GraphQLViewer?
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await api.subscribe(
            to: query,
            variables: variables,
            operationName: operationName,
            rules: Self.rules,
            formattedWith: .sortedKeys,
            context: ExampleContext(viewer: viewer, transaction: transaction)
        )
    }
}

/// The context of one call of the example.
struct ExampleContext: GraphQLRunContext {
    let warnings = ResponseWarnings()

    /// The client of the call, or `nil` for the agent.
    let viewer: GraphQLViewer?

    /// The transaction id that the response gives in `extensions.txn`, or `nil` for none.
    let transaction: String?

    func responseExtensions() async -> [String: Map] {
        transaction.map { transaction in ["txn": .string(transaction)] } ?? [:]
    }
}

/// The state of a note.
enum ExampleState: String, Codable, CaseIterable, Sendable {
    /// The note is open.
    case open = "OPEN"

    /// The note is closed.
    case closed = "CLOSED"
}

/// One note.
struct ExampleNote: Codable, Sendable {
    let id: String
    let title: String
    let body: String?
    let tags: [String]
    let state: ExampleState
}

/// The error of a note that the store does not have.
struct NoteNotFound: CodedError {
    /// The id that the call sent.
    let id: String

    var code: String { "NOT_FOUND" }

    var message: String { "No note has the id \"\(id)\". Query the shelf to get the ids." }
}

/// A fault that is not a coded error.
struct ExampleFault: Error {}

/// The arguments of a field that takes the id of a note.
struct NoteIDArguments: Codable, Sendable {
    let id: String
}

/// The arguments of `Shelf.notes`.
struct NotesArguments: Codable, Sendable {
    let first: Int?
}

/// The `input` object of `addNote`.
struct AddNoteInput: Codable, Sendable {
    let title: String
    let body: String?
    let tags: [String]?
    let state: ExampleState?
}

/// The arguments of `addNote`.
struct AddNoteArguments: Codable, Sendable {
    let input: AddNoteInput
}

/// The `input` object of `removeNote`.
struct RemoveNoteInput: Codable, Sendable {
    let id: String
}

/// The arguments of `removeNote`.
struct RemoveNoteArguments: Codable, Sendable {
    let input: RemoveNoteInput
}

/// The arguments of `Subscription.changes`.
struct ExampleChangesArguments: Codable, Sendable {
    /// The cursor to resume after, or `nil` for the new changes only.
    let after: String?
}

/// The arguments of `echo`.
struct EchoArguments: Codable, Sendable {
    let value: Map?
}

/// The root container of the notes.
struct ExampleShelf: Sendable {
    /// Resolves `Shelf.note`.
    func note(context _: ExampleContext, arguments: NoteIDArguments) -> ExampleNote? {
        arguments.id == ExampleGraph.firstNote.id ? ExampleGraph.firstNote : nil
    }

    /// Resolves `Shelf.notes`.
    func notes(context _: ExampleContext, arguments: NotesArguments) -> [ExampleNote] {
        Array([ExampleGraph.firstNote].prefix(arguments.first ?? .max))
    }
}

/// The root resolver of the example.
struct ExampleResolver: Sendable {
    /// The change log of the notes.
    let log = ChangeLog<ChangedIDs>()

    /// Resolves `Query.cursor`: the newest cursor of the notes.
    func cursor(context _: ExampleContext, arguments _: NoArguments) async -> String {
        await log.cursor
    }

    /// Resolves the source stream of `Subscription.changes`.
    func changes(
        context _: ExampleContext,
        arguments: ExampleChangesArguments
    ) async -> AsyncThrowingStream<ChangeLogEntry<ChangedIDs>, Error> {
        await log.changes(after: arguments.after)
    }

    /// Resolves `Query.shelf`.
    func shelf(context _: ExampleContext, arguments _: NoArguments) -> ExampleShelf {
        ExampleShelf()
    }

    /// Resolves `Query.now`.
    func now(context _: ExampleContext, arguments _: NoArguments) -> DateTime {
        ExampleGraph.now
    }

    /// Resolves `Query.echo`: gives the `JSON` value back.
    func echo(context _: ExampleContext, arguments: EchoArguments) -> Map? {
        arguments.value
    }

    /// Resolves `Query.ping`, and adds a warning with no `await`.
    func ping(context _: ExampleContext, arguments _: NoArguments) -> String {
        ResolverWarnings.current?.add(ResponseWarning(message: "The ping is a test.", code: "PING"))
        return "pong"
    }

    /// Resolves `Query.viewer`: the trust of the client of the call, or `agent`.
    func viewer(context: ExampleContext, arguments _: NoArguments) -> String {
        context.viewer?.trust.rawValue ?? "agent"
    }

    /// Resolves `Query.fault`: a fault that is not a coded error.
    func fault(context _: ExampleContext, arguments _: NoArguments) throws -> String? {
        throw ExampleFault()
    }

    /// Resolves `Mutation.addNote`, and adds a warning when the note has no body.
    func addNote(context: ExampleContext, arguments: AddNoteArguments) async -> ExampleNote {
        let input = arguments.input
        if input.body == nil {
            await context.warnings.add("The note has no body.", code: "NO_BODY")
        }
        return ExampleNote(
            id: "n2",
            title: input.title,
            body: input.body,
            tags: input.tags ?? [],
            state: input.state ?? .open
        )
    }

    /// Resolves `Mutation.removeNote`: the store has only the first note, so each other id gives `NOT_FOUND`.
    func removeNote(context _: ExampleContext, arguments: RemoveNoteArguments) throws -> ExampleNote? {
        guard arguments.input.id == ExampleGraph.firstNote.id else {
            throw NoteNotFound(id: arguments.input.id)
        }
        return ExampleGraph.firstNote
    }
}

/// The Graphiti engine of the example.
struct ExampleAPI: API {
    let resolver = ExampleResolver()
    let schema: Schema<ExampleResolver, ExampleContext>

    /// Builds the schema.
    init() throws {
        schema = try SchemaBuilder(ExampleResolver.self, ExampleContext.self)
            .addToolkitScalars()
            .add {
                Enum(ExampleState.self, as: "State") {
                    Value(.open).description("The note is open.")
                    Value(.closed).description("The note is closed.")
                }
                .description("The state of a note.")
                Type(ExampleNote.self, as: "Note") {
                    Field("id", at: \.id).description("The id of the note.")
                    Field("title", at: \.title).description("The title of the note.")
                    Field("body", at: \.body).description("The text of the note.")
                    Field("tags", at: \.tags).description("The tags of the note.")
                    Field("state", at: \.state).description("The state of the note.")
                }
                .description("One note.")
                Type(ExampleShelf.self, as: "Shelf") {
                    Field("note", at: ExampleShelf.note) {
                        Argument("id", at: \.id).description("The id of the note.")
                    }
                    .description("One note, or null.")
                    Field("notes", at: ExampleShelf.notes) {
                        Argument("first", at: \.first).description("The most notes to give.")
                    }
                    .description("The notes.")
                }
                .description("The notes of the folder.")
                Input(AddNoteInput.self) {
                    InputField("title", at: \.title).description("The title of the note.")
                    InputField("body", at: \.body).description("The text of the note.")
                    InputField("tags", at: \.tags).description("The tags of the note.")
                    InputField("state", at: \.state).description("The state of the note.")
                }
                .description("A new note.")
                Input(RemoveNoteInput.self) {
                    InputField("id", at: \.id).description("The id of the note.")
                }
                .description("The note to remove.")
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
                Field("cursor", at: ExampleResolver.cursor).description("The newest cursor of the notes.")
                Field("shelf", at: ExampleResolver.shelf).description("The notes of the folder.")
                Field("now", at: ExampleResolver.now).description("The time now.")
                Field("echo", at: ExampleResolver.echo) {
                    Argument("value", at: \.value).description("Any JSON value.")
                }
                .description("Gives the value back.")
                Field("ping", at: ExampleResolver.ping).description("Gives pong and a warning.")
                Field("viewer", at: ExampleResolver.viewer).description("The trust of the client of the call.")
                Field("fault", at: ExampleResolver.fault).description("Fails with a fault.")
            }
            .addMutation {
                Field("addNote", at: ExampleResolver.addNote) {
                    Argument("input", at: \.input).description("The new note.")
                }
                .description("Adds a note.")
                Field("removeNote", at: ExampleResolver.removeNote) {
                    Argument("input", at: \.input).description("The note to remove.")
                }
                .description("Removes a note.")
            }
            .addSubscription {
                SubscriptionField(
                    "changes",
                    at: { (entry: ChangeLogEntry<ChangedIDs>) in
                        { (_: ExampleContext, _: ExampleChangesArguments) async throws -> IDChange in IDChange(entry) }
                    },
                    atSub: ExampleResolver.changes
                ) {
                    Argument("after", at: \.after).description("The cursor to resume after.")
                }
                .description("The changes of the notes.")
            }
            .build()
    }
}

/// Reads a JSON response text as an object, for the tests.
enum ResponseJSON {
    /// Reads a response.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The object.
    /// - Throws: An error when the text is not a JSON object.
    static func object(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ExampleFault()
        }
        return object
    }

    /// Gives the codes of the errors of a response.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The `extensions.code` of each error, in order.
    /// - Throws: An error when the text is not a JSON object.
    static func codes(_ text: String) throws -> [String] {
        let errors = try object(text)["errors"] as? [[String: Any]] ?? []
        return errors.compactMap { error in (error["extensions"] as? [String: Any])?["code"] as? String }
    }

    /// Gives the `extensions.rewrites` of a response as `from → to` pairs.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: Each rewrite as `"from→to"`, in order.
    /// - Throws: An error when the text is not a JSON object.
    static func rewrites(_ text: String) throws -> [String] {
        let extensions = try object(text)["extensions"] as? [String: Any]
        let rewrites = extensions?["rewrites"] as? [[String: Any]] ?? []
        return rewrites.map { rewrite in "\(rewrite["from"] ?? "")→\(rewrite["to"] ?? "")" }
    }

    /// Gives the codes of `extensions.warnings` of a response.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The code of each warning, in order.
    /// - Throws: An error when the text is not a JSON object.
    static func warningCodes(_ text: String) throws -> [String] {
        let extensions = try object(text)["extensions"] as? [String: Any]
        let warnings = extensions?["warnings"] as? [[String: Any]] ?? []
        return warnings.compactMap { warning in warning["code"] as? String }
    }
}

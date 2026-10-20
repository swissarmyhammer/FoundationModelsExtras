/// The rules of the forgiving name rewrite of one endpoint: the alias tables, the verbs, the root container, and the
/// removed parameters.
///
/// The schema has one name for each field, and introspection shows only that name. Each endpoint gives these rules as
/// data, so that its Swift code stays the one source of the names, and the rewrite engine stays the same for each
/// endpoint. ``standard`` holds only the general verbs.
public struct GraphQLNameRules: Sendable {
    /// The other names that the agent can write for each name of the schema, by the position of the name.
    public var aliases: GraphQLAliasTable

    /// The verb synonyms of a top-level mutation: each synonym and its canonical verb, for example `create` → `add`.
    public var verbSynonyms: [String: String]

    /// The verb synonyms of a top-level mutation for one noun, by the noun in the singular. For the noun, they apply
    /// before ``verbSynonyms``, for example `board` → (`create` → `init`) when the schema has `initBoard` and no
    /// `addBoard`.
    public var nounVerbSynonyms: [String: [String: String]]

    /// The verbs of a root query field, by the verb, for example `get` → the singular field of the noun.
    public var queryVerbs: [String: GraphQLQueryVerb]

    /// The root query field that holds more fields, or `nil` for none. A root query field that the query type does not
    /// have, and that the type of the container has, moves into the container.
    public var rootContainer: GraphQLRootContainer?

    /// The parameters that the schema does not have any more. The rewrite takes each one out of the document or out
    /// of the value of a variable, and gives a warning.
    public var removedParameters: [GraphQLRemovedParameter]

    /// The general verbs and no other rule: no alias, no root container, and no removed parameter.
    public static let standard = GraphQLNameRules()

    /// The general verb synonyms of a top-level mutation.
    public static let standardVerbSynonyms: [String: String] = [
        "create": "add", "new": "add", "insert": "add",
        "remove": "delete", "rm": "delete", "del": "delete",
        "edit": "update", "modify": "update", "set": "update", "patch": "update",
        "mv": "move",
    ]

    /// The general verbs of a root query field: `get`, `show`, `read`, and `fetch` give the singular field of the
    /// noun, and `list`, `find`, and `query` give the plural field.
    public static let standardQueryVerbs: [String: GraphQLQueryVerb] = [
        "get": .singular, "show": .singular, "read": .singular, "fetch": .singular,
        "list": .plural, "find": .plural, "query": .plural,
    ]

    /// Makes the rules of an endpoint.
    ///
    /// - Parameters:
    ///   - aliases: The alias tables. The default has no alias.
    ///   - verbSynonyms: The verb synonyms of a top-level mutation. The default is ``standardVerbSynonyms``.
    ///   - nounVerbSynonyms: The verb synonyms for one noun. The default has none.
    ///   - queryVerbs: The verbs of a root query field. The default is ``standardQueryVerbs``.
    ///   - rootContainer: The root query field that holds more fields, or `nil` for none.
    ///   - removedParameters: The parameters that the schema does not have any more. The default has none.
    public init(
        aliases: GraphQLAliasTable = GraphQLAliasTable(),
        verbSynonyms: [String: String] = standardVerbSynonyms,
        nounVerbSynonyms: [String: [String: String]] = [:],
        queryVerbs: [String: GraphQLQueryVerb] = standardQueryVerbs,
        rootContainer: GraphQLRootContainer? = nil,
        removedParameters: [GraphQLRemovedParameter] = []
    ) {
        self.aliases = aliases
        self.verbSynonyms = verbSynonyms
        self.nounVerbSynonyms = nounVerbSynonyms
        self.queryVerbs = queryVerbs
        self.rootContainer = rootContainer
        self.removedParameters = removedParameters
    }

    /// Gives the removed parameter that a name of the agent names.
    ///
    /// - Parameter name: The name as the agent wrote it, in any case and style.
    /// - Returns: The removed parameter, or `nil` when the name is not a removed parameter.
    func removedParameter(matching name: String) -> GraphQLRemovedParameter? {
        removedParameters.first { parameter in NameMatcher.hasSameWords(name, as: parameter.name) }
    }
}

// MARK: - Alias tables

/// The place of a name in a document, for the lookup of its aliases.
///
/// One input type can be the input of more than one field. So the scope of an input field names its input type and
/// the field whose argument holds it.
public enum AliasScope: Hashable, Sendable {
    /// A field of a selection, on the object type or the interface with this name.
    case selection(type: String)

    /// An argument of a field. The coordinate is `Type.field`, for example `Board.tasks`.
    case argument(coordinate: String)

    /// A field of an `input` object type. The coordinate is the `Type.field` of the field whose argument holds the
    /// object, for example `Mutation.deleteTask`.
    case inputField(type: String, coordinate: String)
}

/// The aliases of the fields, the arguments, and the `input` fields of a schema: the other names that the agent can
/// write for each name.
///
/// An alias applies only in the positions of its table: a name that has one meaning in one position can have a
/// different meaning, or none, in a different position. When two names of one position have the same alias, the name
/// of the agent gives `AMBIGUOUS_NAME`. The match folds the case and the style before it reads an alias, so one alias
/// `taskId` also covers `task_id` and `TASK_ID`.
public struct GraphQLAliasTable: Sendable {
    /// The aliases that apply at each position of a document, by the canonical name.
    public var everywhere: [String: [String]]

    /// The aliases that apply to the fields of each `input` object type, by the canonical name.
    public var inEachInput: [String: [String]]

    /// The aliases of the fields of each object type, interface type and `input` object type, by the GraphQL name of
    /// the type, then by the canonical name.
    public var byType: [String: [String: [String]]]

    /// The aliases of the arguments of each field, and of the `input` fields under each field, by the coordinate
    /// `Type.field`, then by the canonical name.
    public var byField: [String: [String: [String]]]

    /// Makes the alias tables.
    ///
    /// - Parameters:
    ///   - everywhere: The aliases that apply at each position.
    ///   - inEachInput: The aliases that apply to the fields of each `input` object type.
    ///   - byType: The aliases of the fields of each type.
    ///   - byField: The aliases of the arguments of each field, and of the `input` fields under each field.
    public init(
        everywhere: [String: [String]] = [:],
        inEachInput: [String: [String]] = [:],
        byType: [String: [String: [String]]] = [:],
        byField: [String: [String: [String]]] = [:]
    ) {
        self.everywhere = everywhere
        self.inEachInput = inEachInput
        self.byType = byType
        self.byField = byField
    }

    /// Gives the aliases of a name at a position of a document.
    ///
    /// - Parameters:
    ///   - name: The GraphQL name, for example `body`.
    ///   - scope: The position of the name.
    /// - Returns: The aliases of each table that applies at the position, in the order of the tables.
    public func aliases(of name: String, in scope: AliasScope) -> [String] {
        let tables: [[String: [String]]?] = switch scope {
        case .selection(let type):
            [everywhere, byType[type]]
        case .argument(let coordinate):
            [everywhere, byField[coordinate]]
        case .inputField(let type, let coordinate):
            [everywhere, inEachInput, byType[type], byField[coordinate]]
        }
        return tables.flatMap { table in table?[name] ?? [] }
    }
}

// MARK: - Verbs, container, removed parameters

/// A verb of a root query field: how the noun after the verb gives the name of the field.
public struct GraphQLQueryVerb: Hashable, Sendable {
    /// The number of a noun that a query verb asks for.
    public enum Number: Hashable, Sendable {
        /// The singular: `getTasks` gives `task`.
        case singular

        /// The plural: `listTask` gives `tasks`.
        case plural
    }

    /// A verb that gives the singular field of the noun, for example `get` in `getTask`.
    public static let singular = GraphQLQueryVerb(fieldWords: [], defaultNoun: [], number: .singular)

    /// A verb that gives the plural field of the noun, for example `list` in `listTasks`.
    public static let plural = GraphQLQueryVerb(fieldWords: [], defaultNoun: [], number: .plural)

    /// The words of the verb that the field name keeps, for example `search` in `searchTasks`. The list is empty
    /// when the field name is the noun alone.
    public var fieldWords: [String]

    /// The noun when the agent wrote the verb with no noun, for example `task` for `next`. The list is empty when
    /// the verb needs a noun.
    public var defaultNoun: [String]

    /// The number of the noun that the verb tries first.
    public var number: Number

    /// Makes a query verb.
    ///
    /// - Parameters:
    ///   - fieldWords: The words of the verb that the field name keeps, in lowercase.
    ///   - defaultNoun: The words of the noun when the agent wrote no noun, in lowercase.
    ///   - number: The number of the noun that the verb tries first.
    public init(fieldWords: [String], defaultNoun: [String], number: Number) {
        self.fieldWords = fieldWords
        self.defaultNoun = defaultNoun
        self.number = number
    }
}

/// A root query field that holds more fields, for example `board` of the `kanban` endpoint.
///
/// A root query field that the query type does not have, and that the type of the container has, moves into an added
/// container field. The response puts its result back at the root of `data`, so that the caller finds it under the
/// key that it wrote.
public struct GraphQLRootContainer: Hashable, Sendable {
    /// The name of the root query field that holds the fields, for example `board`.
    public var field: String

    /// The start of the response key of a container field that the rewrite adds. The number of the move follows it.
    /// It must not be a key that a caller writes.
    public var responseKeyPrefix: String

    /// Makes a root container.
    ///
    /// - Parameters:
    ///   - field: The name of the root query field that holds the fields.
    ///   - responseKeyPrefix: The start of the response key of an added container field.
    public init(field: String, responseKeyPrefix: String) {
        self.field = field
        self.responseKeyPrefix = responseKeyPrefix
    }
}

/// A parameter that the schema does not have any more.
///
/// The rewrite ignores a removed parameter: it takes the parameter out of the document or out of the value of a
/// variable, the call runs, and the response gives a warning in `extensions.warnings` that tells the agent what to
/// use. The rewrite accepts the name in each case and style, so `exclude_done`, `excludeDone`, and `EXCLUDE_DONE` are
/// the same parameter. A name that a field, an argument, or an `input` field of the position has, also as an alias,
/// is never a removed parameter.
public struct GraphQLRemovedParameter: Hashable, Sendable {
    /// The code of the warning of a removed parameter.
    public static let warningCode = "REMOVED_PARAMETER"

    /// The name of the parameter, for example `exclude_done`.
    public var name: String

    /// What the agent can do in place of the parameter, as the end of the warning sentence, for example
    /// "use the filter `!#DONE`.".
    public var replacement: String

    /// Makes a removed parameter.
    ///
    /// - Parameters:
    ///   - name: The name of the parameter.
    ///   - replacement: What the agent can do in place of the parameter, as the end of the warning sentence.
    public init(name: String, replacement: String) {
        self.name = name
        self.replacement = replacement
    }

    /// Gives the warning of the parameter for the response.
    ///
    /// - Parameter name: The name as the agent wrote it. The warning quotes this name.
    /// - Returns: The warning, for example "`due` is removed, with no replacement. The call ignored it."
    public func warning(writtenAs name: String) -> ResponseWarning {
        ResponseWarning(message: "`\(name)` is removed, \(replacement) The call ignored it.", code: Self.warningCode)
    }
}

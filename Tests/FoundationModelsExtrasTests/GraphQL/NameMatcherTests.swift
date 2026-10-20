import Testing

@testable import FoundationModelsExtras

/// Proves the name matcher of the forgiving names: each match step, ties, the root query verbs, and the verbs of one
/// noun, with the verbs and the aliases as data in ``GraphQLNameRules``.
@Suite("Name matcher")
struct NameMatcherTests {
    /// Rules with more verbs than the standard rules, the way a package with a board gives them: verbs for complete,
    /// tag, and undelete, `init` for the noun `board`, and the query verbs `search` and `next`.
    static let boardRules = GraphQLNameRules(
        aliases: GraphQLAliasTable(
            everywhere: ["body": ["description", "desc"], "tags": ["labels", "label"]],
            byType: ["Task": ["column": ["status", "state"]]],
            byField: ["Mutation.moveTask": ["id": ["taskId"], "column": ["status"]]]
        ),
        verbSynonyms: GraphQLNameRules.standardVerbSynonyms.merging([
            "archive": "delete", "done": "complete", "finish": "complete", "close": "complete",
            "label": "tag", "unlabel": "untag", "restore": "undelete", "unarchive": "undelete", "recover": "undelete",
        ]) { standard, _ in standard },
        nounVerbSynonyms: ["board": ["create": "init", "new": "init"]],
        queryVerbs: GraphQLNameRules.standardQueryVerbs.merging([
            "search": GraphQLQueryVerb(fieldWords: ["search"], defaultNoun: ["task"], number: .plural),
            "next": GraphQLQueryVerb(fieldWords: ["next"], defaultNoun: ["task"], number: .singular),
        ]) { standard, _ in standard }
    )

    /// The top-level mutations.
    static let mutations = [
        "initBoard", "updateBoard", "addTask", "updateTask", "moveTask", "completeTask", "tagTask", "untagTask",
        "deleteTask", "undeleteTask", "addColumn", "addTag", "renameTag", "addComment",
    ].map { name in candidate(name, in: .selection(type: "Mutation")) }

    /// The fields of the `Task` type, with their aliases.
    static let taskFields = [
        "id", "body", "shortId", "title", "column", "ordinal", "assignees", "tags", "dependsOn", "blockedBy",
        "ready", "comments",
    ].map { name in candidate(name, in: .selection(type: "Task")) }

    /// The fields of the `Board` type. It has `task` and `tasks`, which differ by one letter.
    static let boardFields = ["id", "body", "key", "name", "columns", "tags", "task", "tasks", "summary"]
        .map { name in candidate(name, in: .selection(type: "Board")) }

    /// The fields of the `Board` type that a root query field can find: ``boardFields`` with `nextTask`,
    /// `searchTasks`, and `history`.
    static let boardQueryFields = boardFields + ["nextTask", "searchTasks", "history"].map { name in
        candidate(name, in: .selection(type: "Board"))
    }

    /// The fields of the `input` object of `moveTask`.
    static let moveTaskInputFields = ["id", "column", "ordinal"].map { name in
        candidate(name, in: .inputField(type: "MoveTaskInput", coordinate: "Mutation.moveTask"))
    }

    /// Makes a candidate with the aliases of ``boardRules`` at a position.
    ///
    /// - Parameters:
    ///   - name: The canonical name.
    ///   - scope: The position.
    /// - Returns: The candidate.
    static func candidate(_ name: String, in scope: AliasScope) -> CanonicalName {
        CanonicalName(name: name, aliases: boardRules.aliases.aliases(of: name, in: scope))
    }

    /// Gives the match of a top-level mutation name.
    static func mutationMatch(for name: String, rules: GraphQLNameRules = boardRules) -> NameMatch {
        NameMatcher.match(for: name, among: mutations, at: .topLevelMutation, rules: rules)
    }

    /// Gives the match of a root query field name.
    static func queryMatch(for name: String, among candidates: [CanonicalName] = boardQueryFields) -> NameMatch {
        NameMatcher.match(for: name, among: candidates, at: .topLevelQuery, rules: boardRules)
    }

    /// Gives the match of a name at a position that is not a top-level field.
    static func fieldMatch(for name: String, among candidates: [CanonicalName]) -> NameMatch {
        NameMatcher.match(for: name, among: candidates, at: .anyOther, rules: boardRules)
    }

    @Test("the exact name gives itself")
    func exactNameGivesItself() {
        #expect(Self.mutationMatch(for: "addTask") == .found(canonical: "addTask"))
        #expect(Self.fieldMatch(for: "title", among: Self.taskFields) == .found(canonical: "title"))
    }

    @Test(
        "the same name in a different case or style gives the canonical name",
        arguments: [("Title", "title"), ("TITLE", "title"), ("short_id", "shortId"), ("short-id", "shortId"),
                    ("SHORTID", "shortId"), ("depends_on", "dependsOn")]
    )
    func caseAndStyleGiveCanonicalName(name: String, expected: String) {
        #expect(Self.fieldMatch(for: name, among: Self.taskFields) == .found(canonical: expected))
    }

    @Test(
        "the singular or plural form gives the canonical name",
        arguments: [("tag", "tags"), ("assignee", "assignees"), ("comment", "comments"), ("blockedBys", "blockedBy")]
    )
    func numberGivesCanonicalName(name: String, expected: String) {
        #expect(Self.fieldMatch(for: name, among: Self.taskFields) == .found(canonical: expected))
    }

    @Test("a plural that ends in ies gives the form that ends in y")
    func iesPluralGivesY() {
        #expect(
            Self.fieldMatch(for: "summaries", among: [CanonicalName(name: "summary", aliases: [])])
                == .found(canonical: "summary"))
    }

    @Test(
        "the other word order and the verb synonyms give the canonical mutation",
        arguments: [
            ("taskAdd", "addTask"), ("createTask", "addTask"), ("create_task", "addTask"), ("TaskCreate", "addTask"),
            ("removeTask", "deleteTask"), ("archiveTask", "deleteTask"), ("editTask", "updateTask"),
            ("mvTask", "moveTask"), ("doneTask", "completeTask"), ("labelTask", "tagTask"),
            ("restoreTask", "undeleteTask"), ("boardInit", "initBoard"), ("tag_rename", "renameTag"),
            ("createTasks", "addTask"),
        ]
    )
    func wordOrderAndSynonymsGiveMutation(name: String, expected: String) {
        #expect(Self.mutationMatch(for: name) == .found(canonical: expected))
    }

    @Test("the standard rules have the general verbs, and no verb of a package")
    func standardRulesHaveTheGeneralVerbs() {
        #expect(Self.mutationMatch(for: "createTask", rules: .standard) == .found(canonical: "addTask"))
        #expect(Self.mutationMatch(for: "archiveTask", rules: .standard) == .notFound)
        #expect(Self.mutationMatch(for: "createBoard", rules: .standard) == .notFound)
    }

    @Test("the word order and the verb synonyms apply only to a top-level mutation")
    func wordOrderOnlyForMutation() {
        let candidates = [CanonicalName(name: "addTask", aliases: [])]
        #expect(Self.fieldMatch(for: "taskAdd", among: candidates) == .notFound)
        #expect(Self.fieldMatch(for: "createTask", among: candidates) == .notFound)
    }

    @Test(
        "an alias of a field gives the field",
        arguments: [("description", "body"), ("desc", "body"), ("Desc", "body"), ("status", "column"),
                    ("labels", "tags"), ("label", "tags")]
    )
    func aliasGivesField(name: String, expected: String) {
        #expect(Self.fieldMatch(for: name, among: Self.taskFields) == .found(canonical: expected))
    }

    @Test("an alias of a field coordinate applies in the input of that field, in each case and style")
    func inputFieldAliases() {
        #expect(Self.fieldMatch(for: "task_id", among: Self.moveTaskInputFields) == .found(canonical: "id"))
        #expect(Self.fieldMatch(for: "status", among: Self.moveTaskInputFields) == .found(canonical: "column"))
    }

    @Test(
        "one changed, added, or removed letter gives the canonical name",
        arguments: [("titls", "title"), ("tite", "title"), ("titlex", "title"), ("ordnal", "ordinal")]
    )
    func closeSpellingGivesCanonicalName(name: String, expected: String) {
        #expect(Self.fieldMatch(for: name, among: Self.taskFields) == .found(canonical: expected))
    }

    @Test("a name of fewer than 4 letters, or with two wrong letters, does not match by close spelling")
    func closeSpellingHasLimits() {
        #expect(Self.fieldMatch(for: "nme", among: Self.boardFields) == .notFound)
        #expect(Self.fieldMatch(for: "tilte", among: Self.taskFields) == .notFound)
    }

    @Test("a tie at a step gives the list of matches, and an earlier step wins over a later step")
    func tiesAndStepOrder() {
        #expect(Self.fieldMatch(for: "taskz", among: Self.boardFields) == .tie(matches: ["task", "tasks"]))
        #expect(Self.fieldMatch(for: "tasks", among: Self.boardFields) == .found(canonical: "tasks"))
    }

    @Test(
        "create and new give init for the noun board, and add for each other noun",
        arguments: [("createBoard", "initBoard"), ("board_new", "initBoard"), ("createBoards", "initBoard"),
                    ("createColumn", "addColumn"), ("newTag", "addTag")]
    )
    func nounVerbs(name: String, expected: String) {
        #expect(Self.mutationMatch(for: name) == .found(canonical: expected))
    }

    @Test(
        "the root query verbs give the singular field, the plural field, or the field that lists the noun",
        arguments: [("getTask", "task"), ("getTasks", "task"), ("taskGet", "task"), ("FETCH_TASKS", "task"),
                    ("showColumn", "columns"), ("getSummary", "summary"), ("listTasks", "tasks"),
                    ("listTask", "tasks"), ("tasksList", "tasks"), ("findColumn", "columns")]
    )
    func queryVerbs(name: String, expected: String) {
        #expect(Self.queryMatch(for: name) == .found(canonical: expected))
    }

    @Test(
        "a query verb of the rules with a default noun gives its field",
        arguments: [("search", "searchTasks"), ("tasksSearch", "searchTasks"), ("next", "nextTask"),
                    ("getNext", "nextTask"), ("next_tasks", "nextTask")]
    )
    func queryVerbsWithDefaultNoun(name: String, expected: String) {
        #expect(Self.queryMatch(for: name) == .found(canonical: expected))
    }

    @Test("a query verb with no noun, or a noun with no field, gives no match, and applies only at the root")
    func queryVerbLimits() {
        #expect(Self.queryMatch(for: "get") == .notFound)
        #expect(Self.queryMatch(for: "getFrobnicate") == .notFound)
        #expect(Self.fieldMatch(for: "getTask", among: Self.boardQueryFields) == .notFound)
    }

    @Test("two names have the same words in each case and style")
    func sameWords() {
        #expect(NameMatcher.hasSameWords("exclude_done", as: "excludeDone"))
        #expect(NameMatcher.hasSameWords("EXCLUDE_DONE", as: "exclude-done"))
        #expect(!NameMatcher.hasSameWords("exclude", as: "excludeDone"))
    }
}

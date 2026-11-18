import FoundationModelsExtras
import Testing

/// ``SessionName`` gives the default name of a new session.
@Suite("SessionName: the default name of a new session")
struct SessionNameTests {
    @Test("with no used name, the default name is the slug of the agent name")
    func noUsedNameGivesTheAgentSlug() {
        #expect(SessionName.default(agentName: "claude-code", usedNames: []) == "claude-code")
    }

    @Test("when the agent slug is used, the default name ends with 2")
    func aUsedSlugGivesTheNumberTwo() {
        #expect(
            SessionName.default(agentName: "claude-code", usedNames: ["claude-code"])
                == "claude-code-2")
    }

    @Test("when the slug and the number 2 are used, the default name ends with 3")
    func twoUsedNamesGiveTheNumberThree() {
        #expect(
            SessionName.default(
                agentName: "claude-code", usedNames: ["claude-code", "claude-code-2"])
                == "claude-code-3")
    }

    @Test("the default name is the slug of an agent name with spaces and capitals")
    func anAgentNameWithSpacesGivesItsSlug() {
        #expect(SessionName.default(agentName: "Claude Code", usedNames: []) == "claude-code")
    }

    @Test("a used name is compared by its slug")
    func aUsedNameIsComparedBySlug() {
        #expect(
            SessionName.default(agentName: "claude-code", usedNames: ["Claude Code"])
                == "claude-code-2")
    }
}

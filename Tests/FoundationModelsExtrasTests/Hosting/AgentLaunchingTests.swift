@testable import FoundationModelsExtras
import FoundationModels
import Testing

/// Exercises ``AgentLaunching``: a host casts a tool it holds as `any Tool`
/// to `any AgentLaunching`, and reads the catalog entries that the tool can
/// start now.
@Suite("AgentLaunching: a tool tells which catalog agents it can start now")
struct AgentLaunchingTests {
    /// The arguments of each tool in this suite.
    @Generable
    struct LaunchArguments {
        /// The name of the agent to start.
        let agent: String
    }

    /// A tool that can start the agents of its grant.
    struct LaunchingTool: AgentLaunching {
        let name = "agents"
        let description = "starts an agent of the catalog"

        /// The catalog entries of the grant, in catalog order.
        let granted: [CatalogEntry]

        func call(arguments: LaunchArguments) async throws -> String {
            arguments.agent
        }

        func launchableAgents() async -> [CatalogEntry] {
            granted
        }
    }

    /// A tool that starts no agent and does not conform.
    struct PlainTool: Tool {
        let name = "plain"
        let description = "starts nothing"

        func call(arguments: LaunchArguments) async throws -> String {
            arguments.agent
        }
    }

    /// The entries of a grant, in catalog order.
    private static let grantedEntries = [
        CatalogEntry(name: "planner", description: "plans the work"),
        CatalogEntry(name: "reviewer", description: "reviews the work"),
        CatalogEntry(name: "tester", description: "tests the work"),
    ]

    @Test("a conforming tool held as any Tool casts to any AgentLaunching and gives its entries in order")
    func conformingToolGivesEntriesInOrder() async throws {
        let tool: any Tool = LaunchingTool(granted: Self.grantedEntries)

        let launching = try #require(tool as? any AgentLaunching)

        #expect(await launching.launchableAgents() == Self.grantedEntries)
    }

    @Test("a tool that does not conform fails the cast")
    func plainToolFailsTheCast() {
        let tool: any Tool = PlainTool()

        #expect(!(tool is any AgentLaunching))
    }

    @Test("an empty grant gives an empty list")
    func emptyGrantStaysEmpty() async throws {
        let tool: any Tool = LaunchingTool(granted: [])

        let launching = try #require(tool as? any AgentLaunching)

        #expect(await launching.launchableAgents().isEmpty)
    }
}

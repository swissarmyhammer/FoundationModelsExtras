import FoundationModels
import Operations
import Testing

/// The context of the mount fixtures. It holds no state.
private struct MountCompileContext: Sendable {}

/// The output of the mount fixtures. It holds no value.
private struct MountCompileOutput: Encodable, Sendable {}

/// A real `@Generable @Operation(...)` struct with a mount argument. It
/// proves that the generated code compiles under the real compiler.
@Generable
@Operation(verb: "start", noun: "job", description: "Start a job", mount: ToolMount(mode: .background))
private struct StartJobMountFixture {
    @Guide(description: "The job name")
    var name: String
}

extension StartJobMountFixture {
    func execute(in context: MountCompileContext) async throws -> MountCompileOutput {
        MountCompileOutput()
    }
}

/// A real `@Generable @Operation(...)` struct with no mount argument.
@Generable
@Operation(verb: "list", noun: "jobs", description: "List the jobs")
private struct ListJobsMountFixture {
    @Guide(description: "The job name filter")
    var filter: String?
}

extension ListJobsMountFixture {
    func execute(in context: MountCompileContext) async throws -> MountCompileOutput {
        MountCompileOutput()
    }
}

@Suite struct MountCompileTests {
    @Test func mountArgumentBecomesTheMountOfTheOperation() {
        #expect(StartJobMountFixture.mount == ToolMount(mode: .background))
    }

    @Test func operationWithNoMountArgumentIsSynchronous() {
        #expect(ListJobsMountFixture.mount == .synchronous)
    }
}

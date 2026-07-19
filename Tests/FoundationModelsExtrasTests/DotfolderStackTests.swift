import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import FoundationModelsExtras

/// Resolves `url` to its real, firmlink-free path via POSIX `realpath(3)`.
///
/// On macOS, `/var` (and thus `FileManager.default.temporaryDirectory`) is a
/// *firmlink* to `/private/var` — a construct `URL.resolvingSymlinksInPath()`
/// deliberately does not cross, but `FileManager.contentsOfDirectory` returns
/// paths that already have crossed it (via the kernel's own path resolution).
/// Fixture roots are canonicalized once at creation so every URL built from
/// them compares equal to what directory enumeration returns.
private func canonicalize(_ url: URL) -> URL {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url }
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let path = String(decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// Behavioral tests for `DotfolderStack`: layer precedence, `nearest`/
/// `locate`/`enumerate` lookups, source tracking, the `<NAME>_DEFAULTS_DIR`
/// dev override, and hermetic construction (plan.md §3). Every test builds
/// its own throwaway `defaults/`/`user/`/`project/` tree under a temp
/// directory so nothing ever touches the real home directory.
@Suite struct DotfolderStackTests {
    /// A throwaway three-layer directory tree, cleaned up when the test ends.
    struct Fixture {
        let root: URL
        let workingDirectory: URL
        let defaultsDirectory: URL
        let userDirectory: URL
        /// The project layer's root, `workingDirectory/.testagent`, matching
        /// exactly what `DotfolderStack` itself derives from `name` and
        /// `workingDirectory` — there is no separate override parameter for
        /// the project layer.
        let projectDirectory: URL

        init() {
            let uncanonicalRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("DotfolderStackTests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: uncanonicalRoot, withIntermediateDirectories: true)
            // Canonicalize once the root exists: on macOS `/var` (and thus
            // `FileManager.default.temporaryDirectory`) is a firmlink to
            // `/private/var/...` that `FileManager.contentsOfDirectory`
            // crosses but `URL.resolvingSymlinksInPath()` does not. Building
            // every fixture path from the canonical root keeps later URL
            // equality checks matching what directory enumeration returns.
            root = canonicalize(uncanonicalRoot)
            workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
            defaultsDirectory = root.appendingPathComponent("defaults", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            projectDirectory = workingDirectory.appendingPathComponent(".testagent", isDirectory: true)
            try! FileManager.default.createDirectory(at: defaultsDirectory, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        }

        /// Writes `contents` to `relativePath` under `directory`, creating any
        /// intermediate subdirectories.
        func write(_ contents: String, to relativePath: String, in directory: URL) {
            let fileURL = directory.appendingPathComponent(relativePath)
            try! FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        func makeStack(environment: [String: String] = [:]) -> DotfolderStack {
            DotfolderStack(
                name: "testagent",
                workingDirectory: workingDirectory,
                defaultsDirectory: defaultsDirectory,
                userDirectory: userDirectory,
                environment: environment
            )
        }
    }

    @Test func plansThreeArgumentCallShapeCompiles() {
        let workingDirectory = FileManager.default.temporaryDirectory
        let stack = DotfolderStack(
            name: "testagent",
            workingDirectory: workingDirectory,
            defaultsDirectory: nil
        )

        #expect(stack.layers.map(\.source) == [.user, .project])
    }

    @Test func layersAreOrderedDefaultsThenUserThenProject() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.layers.map(\.source) == [.defaults, .user, .project])
        #expect(stack.layers[0].root == fixture.defaultsDirectory)
        #expect(stack.layers[1].root == fixture.userDirectory)
    }

    @Test func nearestReturnsProjectCopyWhenAllThreeLayersHoldTheFile() {
        let fixture = Fixture()
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
        fixture.write("user", to: "config.yaml", in: fixture.userDirectory)
        fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)
        let stack = fixture.makeStack()

        let result = stack.nearest("config.yaml")

        #expect(result == fixture.projectDirectory.appendingPathComponent("config.yaml"))
    }

    @Test func nearestReturnsUserCopyWhenProjectLacksTheFile() {
        let fixture = Fixture()
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
        fixture.write("user", to: "config.yaml", in: fixture.userDirectory)
        let stack = fixture.makeStack()

        let result = stack.nearest("config.yaml")

        #expect(result == fixture.userDirectory.appendingPathComponent("config.yaml"))
    }

    @Test func nearestReturnsDefaultsCopyWhenOnlyDefaultsHasTheFile() {
        let fixture = Fixture()
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
        let stack = fixture.makeStack()

        let result = stack.nearest("config.yaml")

        #expect(result == fixture.defaultsDirectory.appendingPathComponent("config.yaml"))
    }

    @Test func nearestReturnsNilWhenNoLayerHasTheFile() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.nearest("config.yaml") == nil)
    }

    @Test func contentReturnsTheHighestPrecedenceCopysText() {
        let fixture = Fixture()
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
        fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)
        let stack = fixture.makeStack()

        #expect(stack.content("config.yaml") == "project")
    }

    @Test func contentReturnsNilWhenNoLayerHasTheFile() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.content("config.yaml") == nil)
    }

    @Test func locateReturnsCopiesLowestToHighest() {
        let fixture = Fixture()
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
        fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)
        let stack = fixture.makeStack()

        let results = stack.locate("config.yaml")

        #expect(
            results == [
                fixture.defaultsDirectory.appendingPathComponent("config.yaml"),
                fixture.projectDirectory.appendingPathComponent("config.yaml"),
            ])
    }

    @Test func locateReturnsEmptyArrayWhenNoLayerHasTheFile() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.locate("config.yaml").isEmpty)
    }

    @Test func enumerateShadowsAndReportsTheWinningLayerPerName() {
        let fixture = Fixture()
        fixture.write("# defaults help", to: "commands/help.md", in: fixture.defaultsDirectory)
        fixture.write("# defaults ps", to: "commands/ps.md", in: fixture.defaultsDirectory)
        fixture.write("# user help", to: "commands/help.md", in: fixture.userDirectory)
        fixture.write("# project ps", to: "commands/ps.md", in: fixture.projectDirectory)
        let stack = fixture.makeStack()

        let results = stack.enumerate("commands", suffix: ".md")

        #expect(results.count == 2)
        #expect(results["help"]?.url == fixture.userDirectory.appendingPathComponent("commands/help.md"))
        #expect(results["help"]?.layer.source == .user)
        #expect(results["ps"]?.url == fixture.projectDirectory.appendingPathComponent("commands/ps.md"))
        #expect(results["ps"]?.layer.source == .project)
    }

    @Test func enumerateIgnoresFilesWithoutTheGivenSuffix() {
        let fixture = Fixture()
        fixture.write("# help", to: "commands/help.md", in: fixture.defaultsDirectory)
        fixture.write("not a command", to: "commands/notes.txt", in: fixture.defaultsDirectory)
        let stack = fixture.makeStack()

        let results = stack.enumerate("commands", suffix: ".md")

        #expect(results.count == 1)
        #expect(results["help"] != nil)
    }

    @Test func defaultsDirEnvironmentOverrideRedirectsTheLowestLayer() {
        let fixture = Fixture()
        let overrideDirectory = fixture.root.appendingPathComponent("override", isDirectory: true)
        try! FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        fixture.write("overridden", to: "config.yaml", in: overrideDirectory)
        fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)

        let stack = fixture.makeStack(environment: ["TESTAGENT_DEFAULTS_DIR": overrideDirectory.path])

        #expect(stack.layers[0].root == overrideDirectory)
        #expect(stack.nearest("config.yaml") == overrideDirectory.appendingPathComponent("config.yaml"))
    }

    @Test func missingLayerDirectoriesAreSkippedWithoutError() {
        let fixture = Fixture()
        let missingDefaultsDirectory = fixture.root.appendingPathComponent("does-not-exist", isDirectory: true)
        fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)

        let stack = DotfolderStack(
            name: "testagent",
            workingDirectory: fixture.workingDirectory,
            defaultsDirectory: missingDefaultsDirectory,
            userDirectory: fixture.userDirectory,
            environment: [:]
        )

        #expect(stack.nearest("config.yaml") == fixture.projectDirectory.appendingPathComponent("config.yaml"))
        #expect(stack.enumerate("commands", suffix: ".md").isEmpty)
    }

    @Test func nearestRejectsPathTraversalWithParentDirectorySegments() {
        let fixture = Fixture()
        // A file that sits one level above every depth-1 layer root
        // (`defaultsDirectory`/`userDirectory`, both `fixture.root/<name>`).
        // Without traversal validation, `"../secret.txt"` resolves from
        // whichever such layer `nearest` checks first — `userDirectory`,
        // since it iterates `layers.reversed()` (project, user, defaults) —
        // to `fixture.root/secret.txt` and would be returned.
        fixture.write("secret", to: "secret.txt", in: fixture.root)
        let stack = fixture.makeStack()

        #expect(stack.nearest("../secret.txt") == nil)
    }

    @Test func nearestRejectsAbsolutePaths() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.nearest("/etc/passwd") == nil)
    }

    @Test func locateRejectsPathTraversalWithParentDirectorySegments() {
        let fixture = Fixture()
        fixture.write("secret", to: "secret.txt", in: fixture.root)
        let stack = fixture.makeStack()

        #expect(stack.locate("../secret.txt").isEmpty)
    }

    @Test func locateRejectsAbsolutePaths() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.locate("/etc/passwd").isEmpty)
    }

    @Test func enumerateRejectsPathTraversalInSubdirectory() {
        let fixture = Fixture()
        // A directory one level above every layer root, holding a file that
        // would otherwise be enumerated by escaping the layer root via
        // `"../escaped"`.
        let escapedDirectory = fixture.root.appendingPathComponent("escaped", isDirectory: true)
        try! FileManager.default.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        fixture.write("# escaped help", to: "help.md", in: escapedDirectory)
        let stack = fixture.makeStack()

        #expect(stack.enumerate("../escaped", suffix: ".md").isEmpty)
    }

    @Test func enumerateRejectsAbsoluteSubdirectory() {
        let fixture = Fixture()
        let stack = fixture.makeStack()

        #expect(stack.enumerate("/etc", suffix: ".conf").isEmpty)
    }

    @Test func nearestAndLocateAndEnumerateStillResolveLegitimateNestedRelativePaths() {
        let fixture = Fixture()
        fixture.write("# help", to: "commands/help.md", in: fixture.defaultsDirectory)
        let stack = fixture.makeStack()

        #expect(stack.nearest("commands/help.md") == fixture.defaultsDirectory.appendingPathComponent("commands/help.md"))
        #expect(stack.locate("commands/help.md") == [fixture.defaultsDirectory.appendingPathComponent("commands/help.md")])
        #expect(stack.enumerate("commands", suffix: ".md")["help"] != nil)
    }

    @Test func constructingAStackPerformsNoFileIO() {
        let fixture = Fixture()
        let missingDefaultsDirectory = fixture.root.appendingPathComponent("brand-new", isDirectory: true)

        _ = DotfolderStack(
            name: "testagent",
            workingDirectory: fixture.workingDirectory,
            defaultsDirectory: missingDefaultsDirectory,
            userDirectory: fixture.userDirectory,
            environment: [:]
        )

        #expect(!FileManager.default.fileExists(atPath: missingDefaultsDirectory.path))
    }
}

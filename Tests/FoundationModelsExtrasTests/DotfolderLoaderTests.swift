import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import FoundationModelsExtras

/// Resolves `url` to its real, firmlink-free path via POSIX `realpath(3)` —
/// mirrors `DotfolderStackTests`' helper of the same name, for the same
/// reason: on macOS `/var` (and thus `FileManager.default.temporaryDirectory`)
/// is a firmlink to `/private/var` that `FileManager.contentsOfDirectory`
/// crosses but `URL.resolvingSymlinksInPath()` does not. Fixture roots are
/// canonicalized once at creation so every URL built from them compares equal
/// to what directory enumeration (via `DotfolderStack.nearest`) returns.
private func canonicalize(_ url: URL) -> URL {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url }
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let path = String(decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// Behavioral tests for `DotfolderLoader`, exercised end-to-end through
/// `TemplateEngine.render`'s `{% include %}` support (plan.md §4): the
/// `_partials/` name-resolution scheme, layered nearest-wins/fall-through
/// resolution, nested includes, and the missing-partial facade error.
@Suite struct DotfolderLoaderTests {
    /// A throwaway three-layer directory tree, each layer holding its own
    /// `_partials/`, cleaned up when the test ends.
    struct Fixture {
        let workingDirectory: URL
        let defaultsDirectory: URL
        let userDirectory: URL
        let projectDirectory: URL

        init() {
            let uncanonicalRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("DotfolderLoaderTests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: uncanonicalRoot, withIntermediateDirectories: true)
            let root = canonicalize(uncanonicalRoot)
            workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
            defaultsDirectory = root.appendingPathComponent("defaults", isDirectory: true)
            userDirectory = root.appendingPathComponent("user", isDirectory: true)
            projectDirectory = workingDirectory.appendingPathComponent(".testagent", isDirectory: true)
            try! FileManager.default.createDirectory(at: defaultsDirectory, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        }

        /// Writes `contents` to `_partials/<name>` under `directory`.
        func writePartial(_ contents: String, named name: String, in directory: URL) {
            let fileURL = directory.appendingPathComponent("_partials").appendingPathComponent(name)
            try! FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        /// A stack rooted at this fixture's three layers.
        func makeStack() -> DotfolderStack {
            DotfolderStack(
                name: "testagent",
                workingDirectory: workingDirectory,
                defaultsDirectory: defaultsDirectory,
                userDirectory: userDirectory,
                environment: [:]
            )
        }

        /// An engine wired with this fixture's stack as `partials`.
        func makeEngine() -> TemplateEngine {
            TemplateEngine(partials: makeStack())
        }
    }

    @Test func projectPartialShadowsUserShadowsDefaultsForTheSameName() throws {
        let fixture = Fixture()
        fixture.writePartial("from defaults", named: "header.md", in: fixture.defaultsDirectory)
        fixture.writePartial("from user", named: "header.md", in: fixture.userDirectory)
        fixture.writePartial("from project", named: "header.md", in: fixture.projectDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"header.md\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "from project")
    }

    @Test func fallsThroughToUserLayerWhenProjectLacksThePartial() throws {
        let fixture = Fixture()
        fixture.writePartial("from defaults", named: "header.md", in: fixture.defaultsDirectory)
        fixture.writePartial("from user", named: "header.md", in: fixture.userDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"header.md\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "from user")
    }

    @Test func fallsThroughToDefaultsLayerWhenOnlyDefaultsHasThePartial() throws {
        let fixture = Fixture()
        fixture.writePartial("from defaults", named: "header.md", in: fixture.defaultsDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"header.md\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "from defaults")
    }

    @Test func extensionlessNameResolvesToTheMdFile() throws {
        let fixture = Fixture()
        fixture.writePartial(
            "extensionless content", named: "coding-standards.md", in: fixture.defaultsDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"coding-standards\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "extensionless content")
    }

    @Test func partialsPrefixedNameResolvesToTheSamePartial() throws {
        let fixture = Fixture()
        fixture.writePartial(
            "prefixed content", named: "coding-standards.md", in: fixture.defaultsDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"_partials/coding-standards\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "prefixed content")
    }

    @Test func nestedIncludeRendersThroughAnotherPartial() throws {
        let fixture = Fixture()
        fixture.writePartial(
            "outer:{% include \"inner.md\" %}", named: "outer.md", in: fixture.defaultsDirectory)
        fixture.writePartial("inner", named: "inner.md", in: fixture.defaultsDirectory)
        let engine = fixture.makeEngine()

        let rendered = try engine.render(
            "{% include \"outer.md\" %}", context: TemplateContext(), trust: .trusted)

        #expect(rendered == "outer:inner")
    }

    @Test func missingPartialThrowsTheFacadeErrorNamingTheInclude() {
        let fixture = Fixture()
        let engine = fixture.makeEngine()

        do {
            _ = try engine.render(
                "{% include \"missing.md\" %}", context: TemplateContext(), trust: .trusted)
            Issue.record("expected TemplateEngineError to be thrown")
        } catch let error as TemplateEngineError {
            #expect("\(error)".contains("missing.md"))
        } catch {
            Issue.record("expected TemplateEngineError, got \(error)")
        }
    }
}

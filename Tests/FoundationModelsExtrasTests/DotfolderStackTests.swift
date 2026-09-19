import FixtureSupport
import Foundation
import Testing

@testable import FoundationModelsExtras

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
      try! FileManager.default.createDirectory(
        at: uncanonicalRoot, withIntermediateDirectories: true)
      // Canonicalize once the root exists: on macOS `/var` (and thus
      // `FileManager.default.temporaryDirectory`) is a firmlink to
      // `/private/var/...` that `FileManager.contentsOfDirectory`
      // crosses but `URL.resolvingSymlinksInPath()` does not. Building
      // every fixture path from the canonical root keeps later URL
      // equality checks matching what directory enumeration returns.
      root = uncanonicalRoot.canonicalDirectory
      workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
      defaultsDirectory = root.appendingPathComponent("defaults", isDirectory: true)
      userDirectory = root.appendingPathComponent("user", isDirectory: true)
      projectDirectory = workingDirectory.appendingPathComponent(".testagent", isDirectory: true)
      try! FileManager.default.createDirectory(
        at: defaultsDirectory, withIntermediateDirectories: true)
      try! FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
      try! FileManager.default.createDirectory(
        at: projectDirectory, withIntermediateDirectories: true)
    }

    /// Writes `contents` to `relativePath` under `directory`, creating any
    /// intermediate subdirectories.
    func write(_ contents: String, to relativePath: String, in directory: URL) {
      write(Data(contents.utf8), to: relativePath, in: directory)
    }

    /// Writes the bytes of `contents` to `relativePath` under `directory`,
    /// creating any intermediate subdirectories.
    func write(_ contents: Data, to relativePath: String, in directory: URL) {
      let fileURL = directory.appendingPathComponent(relativePath)
      try! FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try! contents.write(to: fileURL, options: .atomic)
    }

    /// Creates a symbolic link at `relativePath` under `directory` that
    /// points to `destination`.
    func link(_ relativePath: String, in directory: URL, to destination: URL) {
      try! FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent(relativePath).path,
        withDestinationPath: destination.path)
    }

    func makeStack(environment: [String: String] = [:]) -> DotfolderStack {
      makeStack(defaultsDirectory: defaultsDirectory, environment: environment)
    }

    /// Builds the stack with `defaultsDirectory` as the root of the defaults
    /// layer, in place of the fixture's own `defaults/` directory.
    func makeStack(defaultsDirectory: URL, environment: [String: String] = [:]) -> DotfolderStack {
      DotfolderStack(
        name: "testagent",
        workingDirectory: workingDirectory,
        defaultsDirectory: defaultsDirectory,
        userDirectory: userDirectory,
        environment: environment
      )
    }

    /// Writes the three-layer `review/` example of the combined view:
    ///
    /// ```
    /// defaults/review/SKILL.md            user/review/SKILL.md        project/review/references/house-style.md
    /// defaults/review/references/rules.md user/review/scripts/lint.sh
    /// defaults/review/scripts/lint.sh
    /// defaults/review/scripts/report.sh
    /// ```
    func writeReviewTree() {
      write("defaults skill", to: "review/SKILL.md", in: defaultsDirectory)
      write("defaults rules", to: "review/references/rules.md", in: defaultsDirectory)
      write("defaults lint", to: "review/scripts/lint.sh", in: defaultsDirectory)
      write("defaults report", to: "review/scripts/report.sh", in: defaultsDirectory)
      write("user skill", to: "review/SKILL.md", in: userDirectory)
      write("user lint", to: "review/scripts/lint.sh", in: userDirectory)
      write("project house style", to: "review/references/house-style.md", in: projectDirectory)
    }
  }

  /// The paths that `isSafeRelativePath` rejects: empty, absolute, and a
  /// parent-directory segment.
  private static let unsafePaths = ["", "/etc", "../escaped"]

  @Test func plansThreeArgumentCallShapeCompiles() {
    let workingDirectory = FileManager.default.temporaryDirectory
    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: workingDirectory,
      defaultsDirectory: nil
    )

    #expect(stack.layers.map(\.source) == [.user, .project])
  }

  @Test func defaultInitNeverDerivesAMarketplaceLayer() {
    let workingDirectory = FileManager.default.temporaryDirectory
    let bareStack = DotfolderStack(name: "testagent", workingDirectory: workingDirectory)
    let overriddenStack = DotfolderStack(
      name: "testagent",
      workingDirectory: workingDirectory,
      environment: [
        "TESTAGENT_DEFAULTS_DIR": "/tmp/defaults",
        "XDG_CONFIG_HOME": "/tmp/config",
      ]
    )

    #expect(!bareStack.layers.contains { $0.source == .marketplace })
    #expect(!overriddenStack.layers.contains { $0.source == .marketplace })
    #expect(overriddenStack.layers.map(\.source) == [.defaults, .user, .project])
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
    #expect(
      results["help"]?.url == fixture.userDirectory.appendingPathComponent("commands/help.md"))
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

  @Test func enumerateAgreesWithTheTopLevelOfTree() {
    let fixture = Fixture()
    fixture.writeReviewTree()
    fixture.write("defaults notes", to: "review/NOTES.md", in: fixture.defaultsDirectory)
    let stack = fixture.makeStack()

    let enumerated = stack.enumerate("review", suffix: ".md")
    let topLevel = stack.tree("review").filter { !$0.key.contains("/") && $0.key.hasSuffix(".md") }

    #expect(Set(enumerated.keys) == ["SKILL", "NOTES"])
    #expect(enumerated.count == topLevel.count)
    for (path, item) in topLevel {
      let name = String(path.dropLast(".md".count))
      #expect(enumerated[name]?.url == item.url, "url of \(name)")
      #expect(enumerated[name]?.layer.source == item.layer.source, "layer of \(name)")
      #expect(enumerated[name]?.value == item.value, "value of \(name)")
    }
  }

  @Test func defaultsDirEnvironmentOverrideRedirectsTheLowestLayer() {
    let fixture = Fixture()
    let overrideDirectory = fixture.root.appendingPathComponent("override", isDirectory: true)
    try! FileManager.default.createDirectory(
      at: overrideDirectory, withIntermediateDirectories: true)
    fixture.write("overridden", to: "config.yaml", in: overrideDirectory)
    fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)

    let stack = fixture.makeStack(environment: ["TESTAGENT_DEFAULTS_DIR": overrideDirectory.path])

    #expect(stack.layers[0].root == overrideDirectory)
    #expect(stack.nearest("config.yaml") == overrideDirectory.appendingPathComponent("config.yaml"))
  }

  @Test func missingLayerDirectoriesAreSkippedWithoutError() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "does-not-exist", isDirectory: true)
    fixture.write("project", to: "config.yaml", in: fixture.projectDirectory)

    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: fixture.workingDirectory,
      defaultsDirectory: missingDefaultsDirectory,
      userDirectory: fixture.userDirectory,
      environment: [:]
    )

    #expect(
      stack.nearest("config.yaml") == fixture.projectDirectory.appendingPathComponent("config.yaml")
    )
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
    try! FileManager.default.createDirectory(
      at: escapedDirectory, withIntermediateDirectories: true)
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

    #expect(
      stack.nearest("commands/help.md")
        == fixture.defaultsDirectory.appendingPathComponent("commands/help.md"))
    #expect(
      stack.locate("commands/help.md") == [
        fixture.defaultsDirectory.appendingPathComponent("commands/help.md")
      ])
    #expect(stack.enumerate("commands", suffix: ".md")["help"] != nil)
  }

  @Test func initTrapsWhenNameContainsAPathSeparator() async {
    // A `name` like `"evil/../../etc"` would otherwise be appended as
    // `.evil/../../etc` onto the home/project directory, walking the
    // resolved path outside the intended dotfolder hierarchy entirely.
    await #expect(processExitsWith: .failure) {
      _ = DotfolderStack(name: "evil/../../etc", workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func initTrapsWhenNameIsASingleDot() async {
    // `name == "."` combines with the leading `.` this initializer
    // prepends to produce `".."`, the parent-directory reference.
    await #expect(processExitsWith: .failure) {
      _ = DotfolderStack(name: ".", workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func initTrapsWhenNameIsParentDirectoryReference() async {
    // `name == ".."` would be bare-joined under the user config
    // directory, deriving `$XDG_CONFIG_HOME/..` — the parent of the
    // config directory, escaping the intended hierarchy.
    await #expect(processExitsWith: .failure) {
      _ = DotfolderStack(name: "..", workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func initTrapsWhenNameIsEmpty() async {
    // `name == ""` combines with the leading `.` to produce `"."`, the
    // current-directory reference.
    await #expect(processExitsWith: .failure) {
      _ = DotfolderStack(name: "", workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func userLayerRootsAtXDGConfigHomeWhenSetToAnAbsolutePath() {
    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
      environment: ["XDG_CONFIG_HOME": "/custom/xdg"]
    )

    let userRoot = stack.layers.first { $0.source == .user }?.root

    #expect(userRoot?.path == "/custom/xdg/testagent")
  }

  @Test func userLayerFallsBackToHomeConfigWhenXDGConfigHomeIsUnset() {
    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
      environment: [:]
    )

    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/testagent", isDirectory: true)

    #expect(stack.layers.first { $0.source == .user }?.root.path == expected.path)
  }

  @Test func userLayerFallsBackToHomeConfigWhenXDGConfigHomeIsEmpty() {
    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
      environment: ["XDG_CONFIG_HOME": ""]
    )

    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/testagent", isDirectory: true)

    #expect(stack.layers.first { $0.source == .user }?.root.path == expected.path)
  }

  @Test func userLayerIgnoresARelativeXDGConfigHome() {
    // Per the XDG Base Directory spec, a relative XDG_CONFIG_HOME is
    // invalid and must be ignored in favor of the default.
    let stack = DotfolderStack(
      name: "testagent",
      workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
      environment: ["XDG_CONFIG_HOME": "relative/config"]
    )

    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/testagent", isDirectory: true)

    #expect(stack.layers.first { $0.source == .user }?.root.path == expected.path)
  }

  @Test func constructingAStackPerformsNoFileIO() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "brand-new", isDirectory: true)

    _ = DotfolderStack(
      name: "testagent",
      workingDirectory: fixture.workingDirectory,
      defaultsDirectory: missingDefaultsDirectory,
      userDirectory: fixture.userDirectory,
      environment: [:]
    )

    #expect(!FileManager.default.fileExists(atPath: missingDefaultsDirectory.path))
  }

  @Test func treeGivesTheUnionOfTheLayerFilesAndTheHighestCopyWins() {
    let fixture = Fixture()
    fixture.writeReviewTree()
    let stack = fixture.makeStack()

    let view = stack.tree("review")

    #expect(
      Set(view.keys) == [
        "SKILL.md", "scripts/lint.sh", "scripts/report.sh",
        "references/rules.md", "references/house-style.md",
      ])
    #expect(view["SKILL.md"]?.layer.source == .user)
    #expect(
      view["SKILL.md"]?.url == fixture.userDirectory.appendingPathComponent("review/SKILL.md"))
    #expect(view["scripts/lint.sh"]?.layer.source == .user)
    #expect(view["references/rules.md"]?.layer.source == .defaults)
    #expect(view["references/house-style.md"]?.layer.source == .project)
    #expect(
      view["references/house-style.md"]?.url
        == fixture.projectDirectory.appendingPathComponent("review/references/house-style.md"))
  }

  @Test func treeKeepsAFileOnlyTheLowestLayerHoldsBesideHigherFilesOfTheSameDirectory() {
    let fixture = Fixture()
    fixture.write("defaults report", to: "review/scripts/report.sh", in: fixture.defaultsDirectory)
    fixture.write("project lint", to: "review/scripts/lint.sh", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    let view = stack.tree("review")

    #expect(view["scripts/report.sh"]?.layer.source == .defaults)
    #expect(view["scripts/lint.sh"]?.layer.source == .project)
  }

  @Test func treeWithNoSubdirectoryViewsTheLayerRoots() {
    let fixture = Fixture()
    fixture.write("defaults", to: "config.yaml", in: fixture.defaultsDirectory)
    fixture.write("project", to: "skills/review/SKILL.md", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    let view = stack.tree()

    #expect(Set(view.keys) == ["config.yaml", "skills/review/SKILL.md"])
    #expect(view["skills/review/SKILL.md"]?.layer.source == .project)
  }

  @Test func childDirectoriesGivesTheLayersThatHoldEachNameLowestFirst() {
    let fixture = Fixture()
    fixture.write("defaults lint", to: "review/scripts/lint.sh", in: fixture.defaultsDirectory)
    fixture.write("user lint", to: "review/scripts/lint.sh", in: fixture.userDirectory)
    fixture.write("user logo", to: "review/assets/logo.svg", in: fixture.userDirectory)
    let stack = fixture.makeStack()

    let children = stack.childDirectories(of: "review")

    #expect(Set(children.keys) == ["scripts", "assets"])
    #expect(children["scripts"]?.map(\.source) == [.defaults, .user])
    #expect(children["assets"]?.map(\.source) == [.user])
  }

  @Test func childDirectoriesWithNoSubdirectoryListsTheChildrenOfTheLayerRoots() {
    let fixture = Fixture()
    fixture.write("defaults", to: "commands/help.md", in: fixture.defaultsDirectory)
    fixture.write("project", to: "skills/review/SKILL.md", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    let children = stack.childDirectories()

    #expect(children["commands"]?.map(\.source) == [.defaults])
    #expect(children["skills"]?.map(\.source) == [.project])
  }

  @Test func layerDirectoriesGivesTheLayersThatHoldTheDirectoryLowestFirst() {
    let fixture = Fixture()
    fixture.write("defaults", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    fixture.write("project", to: "review/SKILL.md", in: fixture.projectDirectory)
    let stack = fixture.makeStack()

    #expect(stack.layerDirectories("review").map(\.source) == [.defaults, .project])
  }

  @Test func layerDirectoriesGivesAnEmptyArrayWhenNoLayerHoldsTheDirectory() {
    let fixture = Fixture()
    let stack = fixture.makeStack()

    #expect(stack.layerDirectories("review").isEmpty)
  }

  @Test func layerDirectoriesWithNoDirectoryGivesEachLayerWhoseRootExists() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "does-not-exist", isDirectory: true)
    let stack = fixture.makeStack(defaultsDirectory: missingDefaultsDirectory)

    #expect(stack.layerDirectories().map(\.source) == [.user, .project])
  }

  @Test func aLayerRootThatIsASymbolicLinkIsWalked() {
    let fixture = Fixture()
    fixture.write("linked skill", to: "review/SKILL.md", in: fixture.defaultsDirectory)
    let linkURL = fixture.root.appendingPathComponent("defaults-link", isDirectory: true)
    fixture.link("defaults-link", in: fixture.root, to: fixture.defaultsDirectory)
    let stack = fixture.makeStack(defaultsDirectory: linkURL)

    let view = stack.tree("review")

    #expect(view["SKILL.md"]?.layer.source == .defaults)
    #expect(view["SKILL.md"]?.url.path == linkURL.appendingPathComponent("review/SKILL.md").path)
    #expect(stack.childDirectories(of: "review").isEmpty)
    #expect(stack.layerDirectories("review").map(\.source) == [.defaults])
  }

  @Test func aLayerRootThatDoesNotExistAddsNothingToTheView() {
    let fixture = Fixture()
    let missingDefaultsDirectory = fixture.root.appendingPathComponent(
      "does-not-exist", isDirectory: true)
    fixture.write("project", to: "review/SKILL.md", in: fixture.projectDirectory)
    let stack = fixture.makeStack(defaultsDirectory: missingDefaultsDirectory)

    let view = stack.tree("review")

    #expect(view.count == 1)
    #expect(view["SKILL.md"]?.layer.source == .project)
    #expect(stack.layerDirectories("review").map(\.source) == [.project])
  }

  @Test func treeRejectsUnsafePaths() {
    let fixture = Fixture()
    fixture.write("# escaped", to: "escaped/help.md", in: fixture.root)
    let stack = fixture.makeStack()

    for path in Self.unsafePaths {
      #expect(stack.tree(path).isEmpty, "tree(\(path))")
    }
  }

  @Test func childDirectoriesRejectsUnsafePaths() {
    let fixture = Fixture()
    fixture.write("# escaped", to: "escaped/nested/help.md", in: fixture.root)
    let stack = fixture.makeStack()

    for path in Self.unsafePaths {
      #expect(stack.childDirectories(of: path).isEmpty, "childDirectories(of: \(path))")
    }
  }

  @Test func layerDirectoriesRejectsUnsafePaths() {
    let fixture = Fixture()
    fixture.write("# escaped", to: "escaped/help.md", in: fixture.root)
    let stack = fixture.makeStack()

    for path in Self.unsafePaths {
      #expect(stack.layerDirectories(path).isEmpty, "layerDirectories(\(path))")
    }
  }
}

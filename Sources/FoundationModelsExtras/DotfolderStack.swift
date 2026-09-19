import Foundation

/// The layered dotfolder resolution stack shared across the family (plan.md
/// §3): shipped defaults, the user's XDG config directory, and the current
/// project's dotfolder, in increasing precedence — `defaults < user
/// ($XDG_CONFIG_HOME/<name>/, default ~/.config/<name>/) < project
/// (<cwd>/.<name>/)`.
///
/// `DotfolderStack` only **locates** files (and, via `content`, reads one
/// verbatim); it never merges their contents. Key-level config merging
/// (scalars/arrays replace wholesale, sections merge by key) is a consumer
/// concern — the consumer's codec policy, not this type's. The stack is the
/// only thing that touches disk, and only when `nearest`, `locate`,
/// `enumerate`, `content`, `tree`, `childDirectories`, or `layerDirectories`
/// is called: constructing a stack never performs file I/O, so consumers
/// stay constructible in tests with none.
public struct DotfolderStack: Sendable {
  /// Which layer of the stack a location resolved from.
  public enum Source: Sendable, Hashable {
    /// The consumer-shipped defaults directory — a real directory read
    /// at runtime, never compiled-in content.
    case defaults
    /// The user's XDG config directory for this name,
    /// `$XDG_CONFIG_HOME/<name>/` (default `~/.config/<name>/`).
    case user
    /// The current project's dotfolder, `<workingDirectory>/.<name>/`.
    case project
    /// A cached remote skill marketplace layer. A host adds this layer
    /// itself, below the local `defaults < user < project` layers.
    /// It is never trusted. `init(name:workingDirectory:...)` never
    /// derives it.
    case marketplace
  }

  /// One layer of the stack: a source kind and the directory it roots.
  public struct Layer: Sendable {
    /// Which layer this is.
    public var source: Source
    /// The directory this layer roots. May not exist on disk; lookups
    /// skip layers whose root is missing.
    public var root: URL

    /// Creates a layer. Exposed publicly so consumers can build fixtures
    /// and fakes (e.g. for their own tests) with a plain
    /// `import FoundationModelsExtras`, no `@testable` access required.
    public init(source: Source, root: URL) {
      self.source = source
      self.root = root
    }
  }

  /// A resolved location together with the layer that won it — the
  /// swissarmyhammer `FileSource` idea, so consumers can surface "where did
  /// this come from" in diagnostics (`/status`, `/memory` headers).
  public struct Located: Sendable {
    /// The winning file's URL.
    public var url: URL
    /// The layer that won.
    public var layer: Layer

    /// Creates a located value. Exposed publicly so consumers can build
    /// fixtures and fakes (e.g. for their own tests) with a plain
    /// `import FoundationModelsExtras`, no `@testable` access required.
    public init(url: URL, layer: Layer) {
      self.url = url
      self.layer = layer
    }
  }

  /// The stack's layers, `defaults < user < project`, lowest to highest
  /// precedence. Omits the `defaults` layer entirely when the consumer
  /// supplied no `defaultsDirectory` and no `<NAME>_DEFAULTS_DIR` override
  /// was set — there is no shipped-defaults directory to root it at.
  public var layers: [Layer]

  /// Derives a stack's layers from a bare name.
  ///
  /// - Parameters:
  ///   - name: The dotfolder name, e.g. `"myagent"` for
  ///     `~/.config/myagent` and `<workingDirectory>/.myagent`. Must be
  ///     non-empty, contain no `/`, and be neither `"."` nor `".."` — a
  ///     precondition failure otherwise, since any of those would let the
  ///     resulting path component escape the intended hierarchy when
  ///     appended onto the user config or project directory.
  ///   - workingDirectory: The current project directory; the project
  ///     layer roots at `<workingDirectory>/.<name>/`.
  ///   - defaultsDirectory: The lowest layer: a real, consumer-shipped
  ///     directory of shipped defaults. `nil` omits the defaults layer.
  ///     Overridden at runtime by the `<NAME>_DEFAULTS_DIR` environment
  ///     variable (`name` uppercased), the dev-override seam that lets
  ///     shipped defaults be repointed at a source checkout with no
  ///     rebuild.
  ///   - userDirectory: The user layer's root. `nil` derives the XDG
  ///     location: `$XDG_CONFIG_HOME/<name>/` when `environment` carries a
  ///     non-empty, absolute `XDG_CONFIG_HOME`, otherwise
  ///     `~/.config/<name>/` from the current user's home directory.
  ///     Callers that must never touch the real home directory (tests,
  ///     demos) pass an explicit value.
  ///   - environment: The environment dictionary consulted for the
  ///     `<NAME>_DEFAULTS_DIR` override and `XDG_CONFIG_HOME`. Defaults to
  ///     the process environment; tests inject a fake dictionary to prove
  ///     the overrides work without depending on real process state.
  public init(
    name: String,
    workingDirectory: URL,
    defaultsDirectory: URL? = nil,
    userDirectory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    precondition(
      Self.isSafeDotfolderName(name),
      """
      DotfolderStack: name "\(name)" is not a safe dotfolder name. It must be \
      non-empty, contain no "/", and be neither "." nor ".." — any of which \
      would let the resulting path component escape the intended hierarchy \
      when appended onto the user config or project directory.
      """
    )

    var layers: [Layer] = []

    let overrideKey = "\(name.uppercased())_DEFAULTS_DIR"
    if let overridePath = environment[overrideKey], !overridePath.isEmpty {
      layers.append(Layer(source: .defaults, root: URL(fileURLWithPath: overridePath)))
    } else if let defaultsDirectory {
      layers.append(Layer(source: .defaults, root: defaultsDirectory))
    }

    let resolvedUserDirectory =
      userDirectory ?? Self.xdgUserDirectory(name: name, environment: environment)
    layers.append(Layer(source: .user, root: resolvedUserDirectory))

    layers.append(
      Layer(
        source: .project,
        root: workingDirectory.appendingPathComponent(".\(name)", isDirectory: true)))

    self.layers = layers
  }

  /// Reports whether `name` is safe to embed in a layer path (bare
  /// `<name>` appended under the user config directory, `.<name>` appended
  /// onto `workingDirectory` for the project layer): non-empty, a single
  /// path component (contains no `/`), and neither `"."` nor `".."`.
  ///
  /// A `name` containing `/` could otherwise introduce extra path
  /// components — including a literal `".."` among them — once joined onto
  /// a layer root, walking the resolved directory outside the intended
  /// hierarchy. A `name` of exactly `"."` combines with the leading `.`
  /// the project layer prepends to produce `".."`, the parent-directory
  /// reference; a `name` of exactly `".."` is that reference already, and
  /// bare-joined under the user config directory would resolve to the
  /// config directory's parent.
  ///
  /// - Parameter name: The dotfolder name passed to `init(name:...)`.
  /// - Returns: `true` if `name` is safe to embed in a layer path.
  private static func isSafeDotfolderName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && name != "." && name != ".."
  }

  /// The user layer's default root per the XDG Base Directory spec:
  /// `<XDG_CONFIG_HOME>/<name>/` when the injected environment carries a
  /// non-empty, absolute `XDG_CONFIG_HOME`; otherwise `~/.config/<name>/`.
  ///
  /// The spec requires `XDG_CONFIG_HOME` to be an absolute path — a
  /// relative value is invalid and ignored, falling back to the default.
  /// Note the bare `<name>` (no leading dot): under a config directory the
  /// hidden-file convention does not apply.
  ///
  /// - Parameters:
  ///   - name: The dotfolder name passed to `init(name:...)`, already
  ///     validated by `isSafeDotfolderName`.
  ///   - environment: The environment dictionary consulted for
  ///     `XDG_CONFIG_HOME`.
  /// - Returns: The derived user-layer root directory.
  private static func xdgUserDirectory(name: String, environment: [String: String]) -> URL {
    if let configHome = environment["XDG_CONFIG_HOME"], configHome.hasPrefix("/") {
      return URL(fileURLWithPath: configHome, isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/\(name)", isDirectory: true)
  }

  /// Reports whether `path` is safe to join onto a layer root: non-empty,
  /// not rooted (no leading `/`), and free of `..` traversal components.
  ///
  /// Every entry point that joins a caller-supplied path onto a layer's
  /// root (`nearest`, `locate`, `enumerate`, `tree`, `childDirectories`,
  /// `layerDirectories`) routes through this check first, so none of them
  /// can be walked outside the layer root via a `"../"` segment or an
  /// absolute path.
  ///
  /// - Parameter path: The caller-supplied relative path or subdirectory
  ///   name to validate.
  /// - Returns: `true` if `path` is safe to join onto a layer root.
  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false)
      .contains("..")
  }

  /// The highest-precedence existing copy of `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, e.g.
  ///   `"config.yaml"` or `"_partials/header.md"`. Rejected (returns
  ///   `nil`) if it is empty, absolute, or contains a `..` component —
  ///   such paths could otherwise escape the layer root.
  /// - Returns: The winning layer's file URL, or `nil` if no layer has it.
  public func nearest(_ relativePath: String) -> URL? {
    guard Self.isSafeRelativePath(relativePath) else { return nil }
    for layer in layers.reversed() {
      let candidate = layer.root.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  /// The text content of the highest-precedence existing copy of
  /// `relativePath` — the read counterpart to `nearest`, so consumers that
  /// want a file's text (not just its location, e.g. a template partial)
  /// never need to touch `FileManager` themselves; the stack stays the
  /// only thing that touches disk.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, as
  ///   accepted by `nearest`. Rejected (returns `nil`) under the same
  ///   rules `nearest` applies.
  /// - Returns: The winning layer's file content decoded as UTF-8, or
  ///   `nil` if no layer has `relativePath` or its content cannot be
  ///   decoded as UTF-8 text.
  public func content(_ relativePath: String) -> String? {
    guard let url = nearest(relativePath) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Every existing copy of `relativePath` across the stack.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  ///   Rejected (returns an empty array) if it is empty, absolute, or
  ///   contains a `..` component — such paths could otherwise escape the
  ///   layer root.
  /// - Returns: File URLs for each layer that has `relativePath`, ordered
  ///   lowest to highest precedence.
  public func locate(_ relativePath: String) -> [URL] {
    guard Self.isSafeRelativePath(relativePath) else { return [] }
    return layers.compactMap { layer in
      let candidate = layer.root.appendingPathComponent(relativePath)
      return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
  }

  /// Lists every file matching `suffix` under `subdirectory` in each layer,
  /// keyed by name with `suffix` stripped, with higher layers shadowing
  /// lower ones by name.
  ///
  /// - Parameters:
  ///   - subdirectory: A directory relative to a layer's root, e.g.
  ///     `"commands"`. Rejected (returns an empty dictionary) if it is
  ///     empty, absolute, or contains a `..` component — such paths could
  ///     otherwise escape the layer root.
  ///   - suffix: The filename suffix to match and strip, e.g. `".md"`.
  ///     Files without this suffix are ignored.
  /// - Returns: A dictionary from name (without `suffix`) to the winning
  ///   file's location and the layer that won it.
  public func enumerate(_ subdirectory: String, suffix: String) -> [String: Located] {
    guard Self.isSafeRelativePath(subdirectory) else { return [:] }
    var results: [String: Located] = [:]
    for layer in layers {
      let directoryURL = layer.root.appendingPathComponent(subdirectory, isDirectory: true)
      guard
        let contents = try? FileManager.default.contentsOfDirectory(
          at: directoryURL, includingPropertiesForKeys: nil)
      else {
        continue
      }
      for fileURL in contents {
        let fileName = fileURL.lastPathComponent
        guard fileName.hasSuffix(suffix) else { continue }
        let name = String(fileName.dropLast(suffix.count))
        results[name] = Located(url: fileURL, layer: layer)
      }
    }
    return results
  }

  /// The combined view of the directory trees of all the layers.
  ///
  /// The unit of override is the file. For each file path relative to
  /// `subdirectory`, the copy in the highest layer that holds that path
  /// wins, and each lower copy is hidden. A directory is never replaced: a
  /// file that only a lower layer holds stays in the view when a higher
  /// layer holds other files of the same directory. The view is computed
  /// at the time of the call; the stack holds no cache.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, e.g.
  ///   `"review"`. `nil` means the layer root itself. Rejected (returns an
  ///   empty dictionary) if it is empty, absolute, or contains a `..`
  ///   component, because such a path could escape the layer root.
  /// - Returns: A dictionary from the file path relative to `subdirectory`,
  ///   at every depth, to the winning copy and the layer that holds it. A
  ///   layer root that does not exist or that cannot be read adds nothing.
  public func tree(_ subdirectory: String? = nil) -> [String: Located] {
    guard let directories = layerDirectoryURLs(subdirectory) else { return [:] }
    let entries = directories.flatMap { layer, directoryURL in
      Self.filePaths(under: directoryURL).map { relativePath in
        let url = directoryURL.appendingPathComponent(relativePath)
        return (relativePath, Located(url: url, layer: layer))
      }
    }
    return Dictionary(entries, uniquingKeysWith: { _, higher in higher })
  }

  /// The immediate child directories of `subdirectory` in the union of all
  /// the layers, with the layers that hold each one.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, as
  ///   accepted by `tree`. `nil` means the layer root itself. Rejected
  ///   (returns an empty dictionary) under the same rules `tree` applies.
  /// - Returns: A dictionary from the child directory name to the layers
  ///   that hold that name, lowest precedence first. A layer root that does
  ///   not exist or that cannot be read adds nothing.
  public func childDirectories(of subdirectory: String? = nil) -> [String: [Layer]] {
    guard let directories = layerDirectoryURLs(subdirectory) else { return [:] }
    let entries = directories.flatMap { layer, directoryURL in
      Self.childDirectoryNames(of: directoryURL).map { name in (name, [layer]) }
    }
    return Dictionary(entries, uniquingKeysWith: +)
  }

  /// The layers that hold `relativeDirectory`.
  ///
  /// A consumer uses this to know which layer gave a file, for example
  /// before it runs a script from that directory.
  ///
  /// - Parameter relativeDirectory: A directory relative to a layer's root,
  ///   as accepted by `tree`. `nil` means the layer root itself. Rejected
  ///   (returns an empty array) under the same rules `tree` applies.
  /// - Returns: The layers whose root holds `relativeDirectory` as a
  ///   directory, lowest precedence first. Empty when no layer holds it.
  public func layerDirectories(_ relativeDirectory: String? = nil) -> [Layer] {
    guard let directories = layerDirectoryURLs(relativeDirectory) else { return [] }
    return directories.filter { Self.isDirectory(atPath: $0.url.path) }.map(\.layer)
  }

  /// The directory that `subdirectory` names under each layer root, lowest
  /// precedence first.
  ///
  /// The three view functions (`tree`, `childDirectories`,
  /// `layerDirectories`) route through this helper, so each of them applies
  /// the same `isSafeRelativePath` check and the same meaning of `nil`.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: One `(layer, url)` pair for each layer, or `nil` when
  ///   `subdirectory` is not safe to join onto a layer root.
  private func layerDirectoryURLs(_ subdirectory: String?) -> [(layer: Layer, url: URL)]? {
    guard let subdirectory else {
      return layers.map { ($0, $0.root) }
    }
    guard Self.isSafeRelativePath(subdirectory) else { return nil }
    return layers.map { ($0, $0.root.appendingPathComponent(subdirectory, isDirectory: true)) }
  }

  /// Every file under `directoryURL`, at every depth, as a path relative to
  /// `directoryURL`.
  ///
  /// The walk reads the **path** of the directory, not the URL, so a layer
  /// root that is a symbolic link to a directory is followed. No name is
  /// skipped: which names to ignore (`.git`, `node_modules`) is the policy
  /// of the consumer, not of the stack.
  ///
  /// - Parameter directoryURL: The directory to walk.
  /// - Returns: The relative file paths, or an empty array when the
  ///   directory does not exist or cannot be read.
  private static func filePaths(under directoryURL: URL) -> [String] {
    let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: directoryURL.path)) ?? []
    return subpaths.filter { !isDirectory(atPath: directoryURL.appendingPathComponent($0).path) }
  }

  /// The names of the immediate child directories of `directoryURL`.
  ///
  /// - Parameter directoryURL: The directory to list.
  /// - Returns: The child directory names, or an empty array when the
  ///   directory does not exist or cannot be read.
  private static func childDirectoryNames(of directoryURL: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    return names.filter { isDirectory(atPath: directoryURL.appendingPathComponent($0).path) }
  }

  /// Reports whether a directory exists at `path`. A symbolic link to a
  /// directory counts as a directory.
  ///
  /// - Parameter path: The filesystem path to test.
  /// - Returns: `true` if `path` resolves to a directory.
  private static func isDirectory(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

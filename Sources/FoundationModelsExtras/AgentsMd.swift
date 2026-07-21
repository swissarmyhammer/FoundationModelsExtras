import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Errors thrown by `AgentsMd.documents(from:upTo:)` — the package's own
/// error type, mirroring the facade-error style of `IgnoreProcessorError`:
/// no `Foundation`-internal error (e.g. `CocoaError`) ever crosses this
/// boundary, only this documented, `CustomStringConvertible` type.
public enum AgentsMdError: Error, Sendable, CustomStringConvertible {
  /// A matched alias file (`AGENTS.md`, `AGENT.md`, or `CLAUDE.md`) exists
  /// as a directory entry at `path` but could not be read as valid UTF-8
  /// text.
  case fileNotReadable(path: String)

  /// A human-readable description naming the unreadable path.
  public var description: String {
    switch self {
    case .fileNotReadable(let path):
      return "agent-instructions file not found or unreadable: \(path)"
    }
  }
}

/// Discovery of `AGENTS.md` agent-instructions files
/// ([agents.md](https://agents.md/)), plan.md §10 (Pillar 4).
///
/// [agents.md](https://agents.md/) defines `AGENTS.md` as "a README for
/// agents: a dedicated, predictable place to provide the context and
/// instructions to help AI coding agents work on your project." It is
/// **instructions and context — not memory**; nothing in the format
/// remembers anything across sessions, so this type is deliberately named
/// after the file, never "memory."
///
/// `AgentsMd` is **discovery only — no policy**: it returns raw text with
/// provenance (which file, which directory it governs). How a consumer uses
/// that is theirs — concatenate into session instructions, render
/// `untrusted` through `TemplateEngine` first, or filter by directory. It
/// deliberately has no user-level layer; the spec has none, and a consumer
/// that wants `~/.config/<name>/AGENTS.md` composes it themselves via
/// `DotfolderStack.content("AGENTS.md")` and prepends it (most-general
/// first, so project files still win).
public enum AgentsMd {
  /// One discovered agent-instructions file, with the provenance needed to
  /// attribute and order it.
  public struct Document: Sendable, Equatable {
    /// The file that was read — the alias's actual path (never a resolved
    /// symlink target), so a consumer that surfaces "where did this come
    /// from" reports what is actually on disk at that directory level.
    public var url: URL
    /// The directory level this document governs — the directory `url`
    /// was found in, not necessarily `url`'s own resolved location.
    public var directory: URL
    /// The file's raw text content, exactly as read — no templating, no
    /// trimming, no policy applied.
    public var text: String

    /// Creates a document. Exposed publicly so consumers can build fixtures
    /// and fakes (e.g. for their own tests) with a plain
    /// `import FoundationModelsExtras`, no `@testable` access required.
    public init(url: URL, directory: URL, text: String) {
      self.url = url
      self.directory = directory
      self.text = text
    }
  }

  /// The alias file names tried at each directory level, in preference
  /// order: `AGENTS.md` is the format per <https://agents.md/>; `AGENT.md`
  /// is the spec's own migration alias; `CLAUDE.md` is the ecosystem-
  /// compatibility alias (Claude Code).
  private static let aliasNames = ["AGENTS.md", "AGENT.md", "CLAUDE.md"]

  /// Walks from `workingDirectory` up to `root`, reading at each level the
  /// first alias present (`AGENTS.md` > `AGENT.md` > `CLAUDE.md`, one file
  /// per directory).
  ///
  /// - Parameters:
  ///   - workingDirectory: The directory to start the walk from — usually
  ///     the current session's working directory. Always included as the
  ///     nearest level, whether or not it holds an alias file itself.
  ///   - root: The outermost directory to walk to and include. Defaults to
  ///     `nil`, which resolves to the nearest ancestor of
  ///     `workingDirectory` (including `workingDirectory` itself) that
  ///     contains a `.git` directory entry — detected by checking for that
  ///     entry's existence, never by running `git` — or, if no such
  ///     ancestor exists, `workingDirectory` itself.
  /// - Returns: One `Document` per directory level that held an alias
  ///   file, **outermost-first** (`root`'s document, if any, comes first;
  ///   `workingDirectory`'s comes last). Concatenating in this order gives
  ///   the nearest file the last word — the spec's "the closest one takes
  ///   precedence." Symlinked aliases that resolve to a path already
  ///   included (the spec's suggested migration, `ln -s AGENTS.md
  ///   AGENT.md`, and any other symlink arrangement that ends up pointing
  ///   at an already-included file) are deduped: only the nearest
  ///   occurrence is kept.
  /// - Throws: `AgentsMdError.fileNotReadable` if a matched alias file
  ///   exists but cannot be read as valid UTF-8 text.
  public static func documents(
    from workingDirectory: URL, upTo root: URL? = nil
  ) throws -> [Document] {
    let start = canonicalize(workingDirectory)
    let resolvedRoot = canonicalize(root ?? gitRoot(from: start) ?? start)

    var directories: [URL] = []
    var current = start
    while true {
      directories.append(current)
      if current.path == resolvedRoot.path {
        break
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        // Reached the filesystem root without matching `resolvedRoot` —
        // stop rather than loop forever. Only possible when the caller
        // passes a `root` that is not an ancestor of `workingDirectory`.
        break
      }
      current = parent
    }
    // `directories` is nearest-first (workingDirectory ... root).

    var documents: [Document] = []
    var seenResolvedPaths: Set<String> = []
    for directory in directories {
      guard let (fileURL, text) = try firstAlias(in: directory) else { continue }
      let resolvedPath = realPath(of: fileURL)
      guard !seenResolvedPaths.contains(resolvedPath) else { continue }
      seenResolvedPaths.insert(resolvedPath)
      documents.append(Document(url: fileURL, directory: directory, text: text))
    }

    return documents.reversed()
  }

  /// Reads the first alias present in `directory`, per `aliasNames`'
  /// preference order.
  ///
  /// - Parameter directory: The directory to look in.
  /// - Returns: The matched alias's URL and text content, or `nil` if
  ///   `directory` holds none of `aliasNames`.
  /// - Throws: `AgentsMdError.fileNotReadable` if the matched alias exists
  ///   but cannot be read as valid UTF-8 text.
  private static func firstAlias(in directory: URL) throws -> (url: URL, text: String)? {
    for name in aliasNames {
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      guard let text = try? String(contentsOf: candidate, encoding: .utf8) else {
        throw AgentsMdError.fileNotReadable(path: candidate.path)
      }
      return (candidate, text)
    }
    return nil
  }

  /// The nearest ancestor of `directory` (including `directory` itself)
  /// that contains a `.git` directory entry, detected purely by that
  /// entry's existence — never by running `git` or reading `.git`'s
  /// contents (which, for a worktree, is a file rather than a directory;
  /// either counts).
  ///
  /// - Parameter directory: The directory to start looking from.
  /// - Returns: The detected repository root, or `nil` if no ancestor up
  ///   to the filesystem root contains a `.git` entry.
  private static func gitRoot(from directory: URL) -> URL? {
    var current = directory
    while true {
      let gitEntry = current.appendingPathComponent(".git", isDirectory: false)
      if FileManager.default.fileExists(atPath: gitEntry.path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        return nil
      }
      current = parent
    }
  }

  /// Resolves `url` to its real, symlink- and firmlink-free path via POSIX
  /// `realpath(3)` — the dedupe key `documents(from:upTo:)` uses to detect
  /// two alias files (possibly at different directory levels, possibly via
  /// the spec's suggested `ln -s AGENTS.md AGENT.md` migration) that
  /// resolve to the same physical file.
  ///
  /// - Parameter url: The file URL to resolve.
  /// - Returns: The resolved path, or `url`'s own path unchanged if
  ///   `realpath(3)` fails (e.g. the file was removed between the
  ///   existence check and this call).
  private static func realPath(of url: URL) -> String {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url.path }
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
    return String(
      decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  /// Resolves `url` to its real, firmlink-free directory path via POSIX
  /// `realpath(3)`, falling back to `url` unchanged if resolution fails
  /// (e.g. the directory does not exist). Canonicalizing `workingDirectory`
  /// and `root` once up front keeps every later path comparison (the walk's
  /// stopping condition, `.git` detection) working over a single consistent
  /// path form, regardless of how the caller's URL was constructed.
  ///
  /// - Parameter url: The directory URL to resolve.
  /// - Returns: The resolved directory URL.
  private static func canonicalize(_ url: URL) -> URL {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url }
    let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let path = String(
      decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}

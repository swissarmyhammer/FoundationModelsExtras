import Foundation

/// The confinement rule that each lookup of `DotfolderStack` applies to a
/// candidate under a layer root: the candidate, with its symbolic links
/// resolved, must be the root itself or a location under the root.
///
/// The text check `isSafeRelativePath` rejects a path that names an escape
/// (`..`, an absolute path). This rule rejects a path that escapes through
/// the filesystem: a symbolic link inside the root that points outside it.
/// The rule came from the `PathConfinement` type of `FoundationModelsSkills`,
/// where each resource operation applied it to a skill directory. It lives
/// here now, so that the stack is the only thing that opens a file and a
/// consumer never needs `FileManager` for the check. The marketplace local
/// file source applies the same rule to a marketplace folder, thus the rule
/// is public and there is one copy.
public enum PathConfinement {
  /// Reports whether `candidate` resolves to `root` or to a location under
  /// `root`.
  ///
  /// Both paths go through the same resolution, so a root that is itself a
  /// symbolic link, or that sits under a macOS firmlink such as `/var`,
  /// compares equal to a candidate found under it.
  ///
  /// - Parameters:
  ///   - candidate: The path to test, usually `root` joined with a relative
  ///     path.
  ///   - root: The layer root that must contain `candidate`.
  /// - Returns: `true` if the resolved `candidate` is the resolved `root` or
  ///   is under it.
  public static func isConfined(_ candidate: URL, to root: URL) -> Bool {
    componentsBelow(root, of: candidate) != nil
  }

  /// The path of `candidate` relative to `root`, after the symbolic links of
  /// both are resolved.
  ///
  /// Both paths go through the same resolution as `isConfined(_:to:)`, thus
  /// `/tmp/x` and `/private/tmp/x` give the same result, and so do
  /// `/var/folders/...` and `/private/var/folders/...`. The compare is on
  /// whole path components, thus `release-notes-extra/x` is not under
  /// `release-notes`.
  ///
  /// - Parameters:
  ///   - candidate: The path to make relative, for example the absolute path
  ///     of a file of a skill.
  ///   - root: The folder that must contain `candidate`.
  /// - Returns: The relative path, with `/` between its components, for
  ///   example `references/changelog.md`. `nil` when `candidate` is `root`
  ///   itself, when it is outside `root`, when its `..` components go out of
  ///   `root`, or when a symbolic link in `root` takes it outside `root`.
  public static func relativePath(of candidate: URL, in root: URL) -> String? {
    guard let components = componentsBelow(root, of: candidate), !components.isEmpty else {
      return nil
    }
    return components.joined(separator: "/")
  }

  /// The path components of the resolved `candidate` that come after the
  /// path components of the resolved `root`.
  ///
  /// This is the one compare that `isConfined(_:to:)` and
  /// `relativePath(of:in:)` share. It compares whole components, never a
  /// text prefix, so a sibling folder whose name starts with the name of
  /// `root` is not under `root`.
  ///
  /// - Parameters:
  ///   - root: The root directory.
  ///   - candidate: The path to test.
  /// - Returns: The components below `root`: empty when `candidate` is
  ///   `root` itself, and `nil` when `candidate` is not `root` and not under
  ///   it.
  private static func componentsBelow(_ root: URL, of candidate: URL) -> ArraySlice<String>? {
    let rootComponents = resolvingSymlinksOfExistingPrefix(root).pathComponents
    let candidateComponents = resolvingSymlinksOfExistingPrefix(candidate).pathComponents
    guard candidateComponents.starts(with: rootComponents) else { return nil }
    return candidateComponents.dropFirst(rootComponents.count)
  }

  /// Resolves the symbolic links of the longest prefix of `url` that exists,
  /// and appends the remaining components unchanged.
  ///
  /// `resolvingSymlinksInPath()` normalizes a path that exists (on macOS it
  /// removes the `/private` prefix) but leaves a path that does not exist
  /// (a missing file, a dangling symbolic link) untouched. A root and a
  /// candidate must go through the same normalization, or the two paths do
  /// not share a prefix and every missing path reads as an escape.
  ///
  /// - Parameter url: The candidate URL.
  /// - Returns: The resolved, standardized URL.
  private static func resolvingSymlinksOfExistingPrefix(_ url: URL) -> URL {
    var existing = url.standardizedFileURL
    var trailingComponents: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
      trailingComponents.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    return trailingComponents
      .reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
      .standardizedFileURL
  }
}

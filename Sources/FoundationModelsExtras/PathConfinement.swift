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
    let resolvedRoot = resolvingSymlinksOfExistingPrefix(root)
    let resolvedCandidate = resolvingSymlinksOfExistingPrefix(candidate)
    return isContained(resolvedCandidate, in: resolvedRoot)
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

  /// Reports whether `candidate` is `root` itself or is somewhere under it,
  /// comparing already resolved and standardized paths.
  ///
  /// - Parameters:
  ///   - candidate: The resolved candidate path.
  ///   - root: The resolved root directory.
  /// - Returns: `true` if `candidate` is contained in `root`.
  private static func isContained(_ candidate: URL, in root: URL) -> Bool {
    let rootPath = root.path
    let candidatePath = candidate.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }
}

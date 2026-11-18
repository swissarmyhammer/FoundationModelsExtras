import Foundation

extension URL {
    /// The path of this file URL in one form, so that two URLs of the same
    /// folder or file give the same path.
    ///
    /// The path has the symbolic links resolved and no `.` or `..`
    /// components. The `path` of a file URL has no trailing `/`, thus `/a/b/`
    /// and `/a/b` give the same path.
    var comparablePath: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }
}

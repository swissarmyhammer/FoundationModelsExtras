import Foundation
import ULID

/// Finds the session that a typed reference names, for example `@fix-the-build`.
public enum SessionReference {
    /// The character that can start a reference.
    private static let marker: Character = "@"

    /// The keys of a session that a short reference can name, in the order
    /// that the resolver tries them: the short id first, then the slug.
    private static let shortKeys: [KeyPath<SessionSummary, String>] = [\.shortID, \.slug]

    /// Finds the session that `text` names.
    ///
    /// The rules:
    /// - The resolver removes the white space around `text`, then one
    ///   leading `@`. A text that is then empty gives ``SessionReferenceResolution/none``.
    /// - A session with the state ``SessionState/archived`` never matches.
    /// - When the text is a full session id, in any letter case, only the
    ///   session with that id matches. The resolver then does not look at
    ///   short ids or slugs: an id with no session gives
    ///   ``SessionReferenceResolution/none``.
    /// - Then the resolver compares the text with the ``SessionSummary/shortID``
    ///   of each session, and then with the ``SessionSummary/slug`` of each
    ///   session. These compares are in lower case.
    /// - For a short id and for a slug, the resolver looks first at the
    ///   sessions whose working folder is `sourceFolder`. It compares the
    ///   folders with symbolic links resolved and with no trailing `/`. When
    ///   no session there matches, it looks at all the sessions.
    /// - Two or more matches in the first scope that has a match give
    ///   ``SessionReferenceResolution/ambiguous(_:)``, in the order of
    ///   `summaries`.
    ///
    /// The function reads only its arguments. It does not start an agent.
    ///
    /// - Parameters:
    ///   - text: The reference that a person or a session typed.
    ///   - sourceFolder: The working folder of the place that sends the
    ///     reference, or `nil` when it has no folder.
    ///   - summaries: The sessions that the reference can name.
    /// - Returns: The session, the sessions that match, or
    ///   ``SessionReferenceResolution/none``.
    public static func resolve(
        _ text: String,
        sourceFolder: URL?,
        among summaries: [SessionSummary]
    ) -> SessionReferenceResolution {
        let key = normalizedKey(of: text)
        guard !key.isEmpty else { return .none }
        let candidates = summaries.filter { $0.state != .archived }
        if let id = ULID(ulidString: key.uppercased()) {
            return resolution(of: candidates.filter { $0.id == id })
        }
        let scopes = searchScopes(of: candidates, sourceFolder: sourceFolder)
        for keyPath in shortKeys {
            for scope in scopes {
                let matches = scope.filter { $0[keyPath: keyPath].lowercased() == key }
                if !matches.isEmpty { return resolution(of: matches) }
            }
        }
        return .none
    }

    /// Removes the white space around `text` and one leading `@`, and makes
    /// the result lower case.
    ///
    /// - Parameter text: The typed reference.
    /// - Returns: The key to compare.
    private static func normalizedKey(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.first == marker ? trimmed.dropFirst() : Substring(trimmed)
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Gives the scopes that a short id or a slug looks at, in order.
    ///
    /// - Parameters:
    ///   - candidates: The sessions that can match.
    ///   - sourceFolder: The working folder of the source, if it has one.
    /// - Returns: The sessions in the source folder, then all the sessions.
    ///   With no source folder, only all the sessions.
    private static func searchScopes(
        of candidates: [SessionSummary],
        sourceFolder: URL?
    ) -> [[SessionSummary]] {
        guard let sourceFolder else { return [candidates] }
        let sourcePath = comparablePath(of: sourceFolder)
        let local = candidates.filter { comparablePath(of: $0.workingDirectory) == sourcePath }
        return [local, candidates]
    }

    /// Gives the path of `folder` with symbolic links resolved. The `path`
    /// of a file URL has no trailing `/`, thus `/a/b/` and `/a/b` give the
    /// same path.
    ///
    /// - Parameter folder: A folder.
    /// - Returns: The path to compare.
    private static func comparablePath(of folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Gives the resolution for the sessions that match.
    ///
    /// - Parameter matches: The sessions that match, in the order of the
    ///   summaries.
    /// - Returns: The resolution.
    private static func resolution(of matches: [SessionSummary]) -> SessionReferenceResolution {
        switch matches.count {
        case 0: .none
        case 1: .session(matches[0])
        default: .ambiguous(matches)
        }
    }
}

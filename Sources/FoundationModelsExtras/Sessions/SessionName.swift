/// Gives the name of a new session.
public enum SessionName {
    /// The number of the first name after the base name.
    private static let firstNumber = 2

    /// The base of the name when the slug of the agent name or of the source
    /// name is empty.
    private static let fallbackBase = "session"

    /// The text that the name of a fork adds to the slug of its source name.
    private static let forkSuffix = "-fork"

    /// Gives the default name of a new session of an agent.
    ///
    /// The name is the slug of `agentName`, for example `claude-code`. When
    /// `agentName` has no letter and no digit, its slug is empty, and the
    /// name is `session` in its place. When a used name has that base, the
    /// name is the base with the first free number, from 2: `claude-code-2`,
    /// then `claude-code-3`. The names are compared by their slugs. A used
    /// name with an empty slug cannot be equal to a default name, thus it has
    /// no effect.
    ///
    /// - Parameters:
    ///   - agentName: The name of the agent of the new session.
    ///   - usedNames: The names, or the slugs, of the sessions in the same
    ///     folder that are not archived.
    /// - Returns: The default name. It is always a slug, and it is never
    ///   empty.
    public static func `default`(agentName: String, usedNames: Set<String>) -> String {
        firstFreeName(from: base(of: agentName), usedNames: usedNames)
    }

    /// Gives the default name of a fork.
    ///
    /// The name is the slug of `sourceName` with `-fork`, for example
    /// `fix-the-build-fork`. When `sourceName` has no letter and no digit,
    /// its slug is empty, and the name is `session-fork`. When a used name
    /// has that base, the name is the base with the first free number, from
    /// 2: `fix-the-build-fork-2`, then `fix-the-build-fork-3`. The names are
    /// compared by their slugs, as in ``default(agentName:usedNames:)``.
    ///
    /// - Parameters:
    ///   - sourceName: The name of the source session, for example its
    ///     ``SessionSummary/slug``.
    ///   - usedNames: The names, or the slugs, of the sessions in the folder
    ///     of the source that are not archived.
    /// - Returns: The default name of the fork. It is always a slug.
    public static func fork(sourceName: String, usedNames: Set<String>) -> String {
        firstFreeName(from: base(of: sourceName) + forkSuffix, usedNames: usedNames)
    }

    /// The slug of a name, or `session` when that slug is empty.
    ///
    /// - Parameter name: The name.
    /// - Returns: A slug that is not empty.
    private static func base(of name: String) -> String {
        let slug = SessionSlug.make(from: name)
        return slug.isEmpty ? fallbackBase : slug
    }

    /// The first name from `base` that no used name has: `base`, else `base`
    /// with the first free number, from 2. The used names are compared by
    /// their slugs, and a used name with an empty slug has no effect.
    ///
    /// - Parameters:
    ///   - base: The slug that the name starts with.
    ///   - usedNames: The names, or the slugs, that are used.
    /// - Returns: The first free name.
    private static func firstFreeName(from base: String, usedNames: Set<String>) -> String {
        let usedSlugs = Set(usedNames.map(SessionSlug.make(from:)).filter { !$0.isEmpty })
        guard usedSlugs.contains(base) else { return base }
        var number = firstNumber
        while usedSlugs.contains("\(base)-\(number)") {
            number += 1
        }
        return "\(base)-\(number)"
    }
}

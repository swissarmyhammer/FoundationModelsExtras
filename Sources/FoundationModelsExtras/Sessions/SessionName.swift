/// Gives the name of a new session.
public enum SessionName {
    /// The number of the first name after the base name.
    private static let firstNumber = 2

    /// The base of the name when the slug of the agent name is empty.
    private static let fallbackBase = "session"

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
        let agentSlug = SessionSlug.make(from: agentName)
        let base = agentSlug.isEmpty ? fallbackBase : agentSlug
        let usedSlugs = Set(usedNames.map(SessionSlug.make(from:)).filter { !$0.isEmpty })
        guard usedSlugs.contains(base) else { return base }
        var number = firstNumber
        while usedSlugs.contains("\(base)-\(number)") {
            number += 1
        }
        return "\(base)-\(number)"
    }
}

/// Gives the name of a new session.
public enum SessionName {
    /// The number of the first name after the slug of the agent name.
    private static let firstNumber = 2

    /// Gives the default name of a new session of an agent.
    ///
    /// The name is the slug of `agentName`, for example `claude-code`. When
    /// a used name has that slug, the name is the slug with the first free
    /// number, from 2: `claude-code-2`, then `claude-code-3`. The names are
    /// compared by their slugs.
    ///
    /// - Parameters:
    ///   - agentName: The name of the agent of the new session.
    ///   - usedNames: The names, or the slugs, of the sessions in the same
    ///     folder that are not archived.
    /// - Returns: The default name, as a slug.
    public static func `default`(agentName: String, usedNames: Set<String>) -> String {
        let base = SessionSlug.make(from: agentName)
        let usedSlugs = Set(usedNames.map(SessionSlug.make(from:)))
        guard usedSlugs.contains(base) else { return base }
        var number = firstNumber
        while usedSlugs.contains("\(base)-\(number)") {
            number += 1
        }
        return "\(base)-\(number)"
    }
}

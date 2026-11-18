/// Makes the slug of a session name: a short text that a person can type to
/// find the session.
public enum SessionSlug {
    /// Makes the slug of `name`.
    ///
    /// The slug is in lower case. Each run of characters that are not
    /// letters or digits becomes one hyphen, and no hyphen is at the start
    /// or at the end. Letters with accents stay letters, thus
    /// `"Café Ünïcode"` gives `"café-ünïcode"`.
    ///
    /// - Parameter name: The name of the session, for example its title.
    /// - Returns: The slug. It is empty when `name` has no letter and no
    ///   digit.
    public static func make(from name: String) -> String {
        name.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: "-")
    }
}

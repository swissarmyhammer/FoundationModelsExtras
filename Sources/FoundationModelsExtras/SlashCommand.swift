import Foundation

/// A user-invocable `/name` command contributed to a harness session
/// (plan.md §2).
///
/// Nothing harness-shaped appears in this type or its neighbors — this
/// package sits below the harness in the family's dependency diamond, and
/// that constraint keeps command handlers honest.
public struct SlashCommand: Sendable {
  /// The command's bare name, surfaced as `/name` — no leading slash.
  public var name: String
  /// A one-line description, shown in pickers and `/help`.
  public var description: String
  /// An input hint shown alongside the command, e.g. `"<pid>"`. `nil` if
  /// the command takes no arguments worth hinting.
  public var argumentHint: String?
  /// What running this command does.
  public var body: Body

  /// Creates a slash command.
  ///
  /// - Parameters:
  ///   - name: The command's bare name (no leading slash).
  ///   - description: A one-line description for pickers and `/help`.
  ///   - argumentHint: An input hint, e.g. `"<pid>"`. Defaults to `nil`.
  ///   - body: What running this command does.
  public init(name: String, description: String, argumentHint: String? = nil, body: Body) {
    self.name = name
    self.description = description
    self.argumentHint = argumentHint
    self.body = body
  }

  /// What running a `SlashCommand` does.
  ///
  /// This is the package's whole security story for slash commands:
  /// `.action` bodies require linked Swift — only a conformer already
  /// compiled into the process can construct one, so the code is trusted
  /// because it is already in-process — while data channels (template
  /// files, MCP prompts) may only ever produce `.prompt` bodies.
  public enum Body: Sendable {
    /// Expands into an ordinary model turn: the template (rendered by
    /// Pillar 3, untrusted) plus the user's arguments become the turn's
    /// prompt. The only body kind data sources may produce.
    case prompt(template: String)
    /// Runs code, streams text output, never touches the model. Only
    /// linked Swift conformers can construct this.
    case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)
  }

  /// The context a `.action` body runs with: the arguments the user typed
  /// after the command's name, and the session's working directory.
  public struct Invocation: Sendable {
    /// The raw text after `"/name "` — whatever the user typed, unparsed.
    public var arguments: String
    /// The session's current working directory.
    public var workingDirectory: URL

    /// Creates an invocation.
    ///
    /// - Parameters:
    ///   - arguments: The raw text after `"/name "`.
    ///   - workingDirectory: The session's current working directory.
    public init(arguments: String, workingDirectory: URL) {
      self.arguments = arguments
      self.workingDirectory = workingDirectory
    }
  }
}

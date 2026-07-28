import Foundation

/// A user-invocable `/name` command contributed to an agent session
/// (plan.md §2).
///
/// Nothing consumer-shaped appears in this type or its neighbors — this
/// package sits below every consumer in the family's dependency diamond, and
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
  /// This is the package's whole security story for slash commands, and it
  /// tiers by producer:
  ///
  /// - **Data sources** (template files, MCP prompts) may only ever produce
  ///   `.prompt` — untrusted text stays confined to the templating pillar's
  ///   rendering rules.
  /// - **Linked Swift conformers** — already trusted because they are
  ///   compiled into the process — may additionally produce `.action`
  ///   (streams text, never touches the model) or `.rendered` (renders a
  ///   prompt with the conformer's own pipeline, then takes a normal model
  ///   turn). Neither closure-based case can be constructed by untrusted
  ///   data, so this adds no new authority: anything a conformer could put
  ///   in a `.rendered` string it could equally have put in a `.prompt`
  ///   template.
  public enum Body: Sendable {
    /// Expands into an ordinary model turn: the template (rendered by
    /// Pillar 3, untrusted) plus the user's arguments become the turn's
    /// prompt. The only body kind data sources may produce.
    case prompt(template: String)
    /// Runs code, streams text output, never touches the model. Only
    /// linked Swift conformers can construct this.
    case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)
    /// Renders a prompt with the conformer's own pipeline, then feeds the
    /// result to the model exactly as the dispatcher would a `.prompt`'s
    /// rendered template. For providers — skills-style commands foremost
    /// among them — whose substitution model, partials, or trust tiering
    /// don't match Extras' Stencil engine, so they cannot render through
    /// `.prompt(template:)` without producing silently wrong prompt text.
    /// A throwing render propagates the thrown error to the caller instead
    /// of resolving to an empty or partial prompt, so a broken render
    /// surfaces as a diagnosable error rather than silently wrong model
    /// input. Only linked Swift conformers can construct this.
    case rendered(@Sendable (Invocation) async throws -> String)
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

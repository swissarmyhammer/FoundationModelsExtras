import ArgumentParser
import FoundationModels
import Operations

/// The result of one `OperationCLIDriver.run(arguments:)` invocation.
///
/// Deliberately a value the caller prints and exits with, rather than
/// `OperationCLIDriver` printing to standard output/error and calling
/// `exit()` itself: that keeps `run(arguments:)` a plain, testable async function.
public struct CLIResult: Sendable, Equatable {
    /// The text to print — the dispatched operation's JSON output, a
    /// corrective/terminal message from the fused tool's resolver, or
    /// ArgumentParser's own help/usage/error/completion-script text.
    public let output: String

    /// The process exit code a real executable should return.
    public let exitCode: Int32
}

/// Assembles a runtime `ParsableCommand` tree from one or more
/// `OperationTool`s' operations and drives parsing/dispatch over it.
///
/// Per plan.md's "Dual-use CLI": the tree is `<executable> <noun> <verb>`
/// with exactly one tool, or `<executable> <tool> <noun> <verb>` with more
/// than one — nouns never merge across tools. Leaves are the
/// macro-generated `Command` for a macro-based operation, or a synthesized
/// `FallbackOperationCommand` built from `ParamMeta` for the manual escape
/// hatch. Every leaf's parsed payload dispatches through the identical
/// `OperationTool.call(arguments:)` path a model call uses — see
/// `dispatch(command:)`.
public struct OperationCLIDriver: Sendable {
    private let registry: CLIRegistry

    /// Assembles a driver over a single tool: the collapsed `<executable>
    /// <noun> <verb>` grammar.
    ///
    /// - Parameters:
    ///   - tool: The tool to drive.
    ///   - executableName: The name shown in usage/help text as this CLI's
    ///     own name (e.g. `"notes"`). Defaults to `nil`, which falls back
    ///     to ArgumentParser's own default — the internal root command
    ///     type's name, rarely what a real executable wants to show.
    /// - Throws: `OperationCLIDriverError.emptyTool` if `tool` has no
    ///   operations.
    public init<Context>(tool: OperationTool<Context>, executableName: String? = nil) throws {
        try self.init(tools: [AnyOperationTool(tool)], executableName: executableName)
    }

    /// Assembles a driver over one or more tools: `<executable> <tool>
    /// <noun> <verb>` with more than one, collapsed to `<executable> <noun>
    /// <verb>` with exactly one.
    ///
    /// - Parameters:
    ///   - tools: The tools to drive.
    ///   - executableName: The name shown in usage/help text as this CLI's
    ///     own name (e.g. `"notes"`). Defaults to `nil`, which falls back
    ///     to ArgumentParser's own default — the internal root command
    ///     type's name, rarely what a real executable wants to show.
    /// - Throws: `OperationCLIDriverError` on a duplicate tool name, an
    ///   empty tool, or two operations in the same tool sharing an
    ///   `opString`.
    public init(tools: [AnyOperationTool], executableName: String? = nil) throws {
        registry = try CLIRegistryBuilder.build(tools: tools, executableName: executableName)
    }

    /// Parses `arguments` against the assembled tree and dispatches to the
    /// matched operation, or handles `--help`/`--generate-completion-script`
    /// /parse errors the same way a real executable's `main()` would.
    ///
    /// - Parameter arguments: The command's arguments, excluding the
    ///   executable name (i.e. `CommandLine.arguments.dropFirst()`).
    /// - Returns: The dispatched operation's JSON output (or a corrective
    ///   message from the fused tool's resolver) on success; ArgumentParser's
    ///   own help, usage, completion-script, or error text otherwise.
    public func run(arguments: [String]) async -> CLIResult {
        await CLIRuntime.$current.withValue(registry) {
            if let completionResult = Self.completionScriptResult(for: arguments) {
                return completionResult
            }
            return await Self.parseAndDispatch(arguments: arguments)
        }
    }

    /// Parses `arguments` and dispatches, translating a parse failure or
    /// help/version request into the same text/exit code ArgumentParser's
    /// own `exit(withError:)` would produce.
    private static func parseAndDispatch(arguments: [String]) async -> CLIResult {
        do {
            let parsed = try await RootCommand.asyncParseAsRoot(arguments)
            return await dispatch(command: parsed)
        } catch {
            return errorResult(for: error)
        }
    }

    /// Dispatches a successfully parsed command: `operationPayload()` +
    /// the owning tool's `call(arguments:)` for a leaf conforming to
    /// `OperationCommand`, or ArgumentParser's own `run()` for anything else
    /// (a help/version request, or an intermediate node's default
    /// help-throwing `run()`).
    private static func dispatch(command: ParsableCommand) async -> CLIResult {
        guard let opCommand = command as? any OperationCommand else {
            return await runNonOperationCommand(command: command)
        }
        guard let dispatch = CLIRuntime.current?.dispatchByCommandType[ObjectIdentifier(type(of: opCommand))] else {
            return CLIResult(output: "Internal error: no dispatcher registered for '\(type(of: opCommand))'.", exitCode: 1)
        }
        do {
            let output = try await dispatch(opCommand.operationPayload())
            return CLIResult(output: output, exitCode: 0)
        } catch {
            return errorResult(for: error)
        }
    }

    /// Runs a parsed command that isn't an `OperationCommand` leaf (a
    /// help/version request, or an intermediate node reached with no
    /// further subcommand), mirroring `AsyncParsableCommand.main(_:)`'s own
    /// sync/async dispatch.
    private static func runNonOperationCommand(command: ParsableCommand) async -> CLIResult {
        var mutableCommand = command
        do {
            if var asyncCommand = mutableCommand as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try mutableCommand.run()
            }
            return CLIResult(output: "", exitCode: 0)
        } catch {
            return errorResult(for: error)
        }
    }

    /// Renders `error` the way `RootCommand.exit(withError:)` would,
    /// without terminating the process.
    private static func errorResult(for error: Error) -> CLIResult {
        CLIResult(output: RootCommand.fullMessage(for: error), exitCode: RootCommand.exitCode(for: error).rawValue)
    }

    /// Handles `--generate-completion-script <shell>` (and `=<shell>`)
    /// itself, appending the macro-less fallback leaves' flags — which
    /// exist only in `ParamMeta`, never as real `@Option`/`@Flag`
    /// declarations ArgumentParser's own `CompletionsGenerator` can walk —
    /// to the script it produces from the real tree.
    ///
    /// - Returns: `nil` if `arguments` doesn't request a completion script,
    ///   so `run(arguments:)` falls through to normal parsing (which recognizes the
    ///   same flag and would otherwise produce the un-augmented script).
    private static func completionScriptResult(for arguments: [String]) -> CLIResult? {
        guard let shellName = generateCompletionScriptShellArgument(in: arguments),
            let shell = CompletionShell(rawValue: shellName)
        else {
            return nil
        }
        let script = RootCommand.completionScript(for: shell)
        let augmented = FallbackCompletionAugmenter.augment(script: script, fallbackParameterLines: CLIRuntime.current?.fallbackParameterLines ?? [])
        return CLIResult(output: augmented, exitCode: 0)
    }

    /// The shell name following a `--generate-completion-script` flag in
    /// `arguments`, in either `--generate-completion-script zsh` or
    /// `--generate-completion-script=zsh` form.
    private static func generateCompletionScriptShellArgument(in arguments: [String]) -> String? {
        let flagName = "--generate-completion-script"
        let inlinePrefix = "\(flagName)="
        for (index, argument) in arguments.enumerated() {
            if argument == flagName {
                let nextIndex = index + 1
                return nextIndex < arguments.count ? arguments[nextIndex] : nil
            }
            if argument.hasPrefix(inlinePrefix) {
                return String(argument.dropFirst(inlinePrefix.count))
            }
        }
        return nil
    }
}

/// Appends `--generate-completion-script`'s macro-less-fallback
/// augmentation lines to ArgumentParser's own generated script, as shell
/// comments — see `OperationCLIDriver.completionScriptResult(for:)`.
internal enum FallbackCompletionAugmenter {
    /// Returns `script` unchanged if `fallbackParameterLines` is empty
    /// (every operation is macro-generated); otherwise `script` with
    /// `fallbackParameterLines` appended under a comment header.
    internal static func augment(script: String, fallbackParameterLines: [String]) -> String {
        guard !fallbackParameterLines.isEmpty else { return script }
        let header = "# Fallback (macro-less) operation flags, not tracked by native shell completion:"
        return script + "\n" + ([header] + fallbackParameterLines).joined(separator: "\n") + "\n"
    }
}

import FoundationModels

/// Fuses a set of operations sharing a `Context` into one FoundationModels
/// `Tool`: `parameters` is the flat-union schema `SchemaFusion` builds, and
/// `call(arguments:)` forgivingly resolves a payload to the matching
/// operation and dispatches to it.
///
/// **Error handling — return, don't throw.** Per plan.md: when a `Tool.call`
/// throws, FoundationModels does not feed the error back to the model for
/// self-correction — `LanguageModelSession.respond` rethrows it, aborting
/// the turn. So resolver and validation failures (unknown op, missing
/// required parameters, unparseable values) are returned as this tool's
/// `String` output — a corrective message the model can act on within the
/// turn — and `throw` is reserved for genuinely fatal conditions (the
/// dispatched operation's own execution or output-encoding failure) the
/// host app must handle.
///
/// **Retry cap.** Corrective feedback can send an on-device model into
/// retry loops, and every retry still costs context. `call(arguments:)`
/// tracks consecutive corrective failures and, once `retryCap` of them have
/// been returned in a row, returns a terminal "stop retrying" message
/// instead of another correction — resetting the count either way, so both
/// a subsequent success and the terminal message itself start the next run
/// of failures fresh.
public struct OperationTool<Context: Sendable>: Tool {
    /// The raw payload `call(arguments:)` receives: the model- or
    /// CLI-supplied `op` plus every operation's parameters, fused per
    /// `SchemaFusion`.
    public typealias Arguments = GeneratedContent

    /// The dispatched operation's JSON-encoded result, or a corrective/
    /// terminal message — see `call(arguments:)`.
    public typealias Output = String

    /// The tool's model- and CLI-facing name.
    public let name: String

    /// A human- and model-facing summary of what the fused tool does.
    public let description: String

    /// The flat-union schema fusing every operation's parameters, built once
    /// at init by `SchemaFusion.fuse`.
    public let parameters: GenerationSchema

    /// Whether FoundationModels injects `parameters` into the prompt.
    /// Defaults to `true`; per plan.md, this is the dominant context cost
    /// for a many-op fused tool, hence the knob.
    public let includesSchemaInInstructions: Bool

    /// Every operation fused into this tool, in the order passed to `init`.
    ///
    /// `OperationsCLI`'s driver reads this to assemble its runtime command
    /// tree from the identical metadata schema fusion and dispatch use —
    /// `verb`/`noun`/`opString` for the tree shape, `parameters` for help
    /// and the macro-less fallback leaf, `commandType` for the
    /// macro-generated leaf when one exists.
    public let operations: [AnyOperation<Context>]

    private let context: Context
    private let resolver: OperationResolver
    private let retryCap: Int
    private let retryState: RetryState

    /// Fuses `operations`, sharing `context`, into a tool named `name`.
    ///
    /// - Parameters:
    ///   - name: The tool's model- and CLI-facing name.
    ///   - description: A human- and model-facing summary of the fused tool.
    ///   - context: The shared environment every operation's `execute(in:)`
    ///     runs against.
    ///   - operations: The operations to fuse. Expected to be non-empty
    ///     with pairwise-distinct `opString`s; the resolver matches the
    ///     first one found on a collision.
    ///   - resolver: The forgiving resolver used to match payloads to
    ///     operations. Defaults to `OperationResolver()`.
    ///   - retryCap: How many consecutive corrective messages
    ///     `call(arguments:)` returns before switching to the terminal
    ///     message. Defaults to `2`.
    ///   - includesSchemaInInstructions: Whether FoundationModels injects
    ///     `parameters` into the prompt. Defaults to `true`.
    /// - Throws: `SchemaFusionError.reservedParameterName` if any operation
    ///   declares a parameter whose name normalizes to `"op"`; rethrows
    ///   `GenerationSchema.SchemaError` if schema fusion fails for a reason
    ///   this initializer does not itself guard against.
    public init(
        name: String,
        description: String,
        context: Context,
        operations: [AnyOperation<Context>],
        resolver: OperationResolver = OperationResolver(),
        retryCap: Int = 2,
        includesSchemaInInstructions: Bool = true
    ) throws {
        self.init(
            name: name,
            description: description,
            parameters: try SchemaFusion.fuse(operations, name: name, description: description),
            includesSchemaInInstructions: includesSchemaInInstructions,
            context: context,
            operations: operations,
            resolver: resolver,
            retryCap: retryCap,
            retryState: RetryState()
        )
    }

    /// Non-throwing internal copy path: builds a tool directly from
    /// already-known fields, reusing an already-fused `parameters` schema
    /// rather than rerunning `SchemaFusion.fuse` — the shared plumbing
    /// behind `copy(context:)`, so neither `connecting(_:)` nor `forked()`
    /// can throw or re-fuse the schema.
    private init(
        name: String,
        description: String,
        parameters: GenerationSchema,
        includesSchemaInInstructions: Bool,
        context: Context,
        operations: [AnyOperation<Context>],
        resolver: OperationResolver,
        retryCap: Int,
        retryState: RetryState
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.includesSchemaInInstructions = includesSchemaInInstructions
        self.context = context
        self.operations = operations
        self.resolver = resolver
        self.retryCap = retryCap
        self.retryState = retryState
    }

    /// Returns a copy of this tool with `context` replaced, sharing every
    /// other field — in particular the already-fused `parameters` schema,
    /// so neither re-runs `SchemaFusion.fuse`. The shared copy path behind
    /// both `EventEmittingTool.connecting(_:)` and `ForkableTool.forked()`.
    ///
    /// - Parameter context: The replacement context.
    /// - Returns: A copy of this tool over `context`.
    private func copy(context: Context) -> OperationTool<Context> {
        OperationTool(
            name: name,
            description: description,
            parameters: parameters,
            includesSchemaInInstructions: includesSchemaInInstructions,
            context: context,
            operations: operations,
            resolver: resolver,
            retryCap: retryCap,
            retryState: retryState
        )
    }

    /// Resolves `arguments` to a registered operation and dispatches to it.
    ///
    /// Pipeline: forgiving-resolve `op` → look up the matching
    /// `AnyOperation` → resolve and validate its required parameters →
    /// `run(content, context)`.
    ///
    /// - Parameter arguments: The model- or CLI-supplied payload: an `op`
    ///   string (or a value `resolver.inferOp` can derive one from) plus the
    ///   resolved operation's parameters, under canonical or aliased names.
    /// - Returns: The dispatched operation's JSON-encoded output on success;
    ///   otherwise a corrective message (unknown op, missing required
    ///   parameters, or unparseable values) — or, once `retryCap`
    ///   consecutive corrective messages have already been returned, the
    ///   terminal message instead of another one.
    /// - Throws: Rethrows `OperationError.executionFailed` or
    ///   `.encodingFailed` from the dispatched operation: failures in the
    ///   operation's own logic or output, not the resolver, which the host
    ///   app must handle.
    public func call(arguments: GeneratedContent) async throws -> String {
        guard let operation = matchOperation(for: arguments) else {
            return await recordCorrective(OperationError.unknownOperation(valid: operations.map(\.opString)).description)
        }

        let resolution = resolver.resolveParameters(arguments, matching: operation.parameters)
        guard resolution.missingRequired.isEmpty else {
            return await recordCorrective(OperationError.missingRequired(resolution.missingRequired).description)
        }

        do {
            let json = try await operation.run(resolution.content, context)
            await retryState.reset()
            return json
        } catch OperationError.decodingFailed {
            return await recordCorrective(OperationError.decodingFailed.description)
        }
    }

    /// Extracts and matches `arguments`' op string against `operations`, via
    /// `resolver`'s explicit-field/inference extraction and
    /// alias/reordering-tolerant matching.
    private func matchOperation(for arguments: GeneratedContent) -> AnyOperation<Context>? {
        guard let candidate = resolver.extractedOpString(from: arguments) else { return nil }
        let candidates = operations.map { OperationResolver.OpCandidate(verb: $0.verb, noun: $0.noun, opString: $0.opString) }
        guard let matchedOpString = resolver.matchOpString(candidate, against: candidates) else { return nil }
        return operations.first { $0.opString == matchedOpString }
    }

    /// Records a corrective failure and returns either `message` or, once
    /// `retryCap` consecutive corrective messages have already been
    /// returned, the terminal message.
    private func recordCorrective(_ message: String) async -> String {
        let exceeded = await retryState.recordFailure(cap: retryCap)
        return exceeded ? Self.terminalMessage : message
    }

    /// Returned instead of another correction once `retryCap` consecutive
    /// corrective messages have already been returned in a row.
    private static var terminalMessage: String {
        "Too many invalid operation attempts in a row; stopping without further corrective retries. "
            + "Review this tool's valid operations and required parameters before trying again."
    }
}

/// Turns `OperationTool<Context>` into an `EventEmittingTool` whenever its
/// `Context` opts in by conforming to `EventEmittingContext`. A `Context`
/// that doesn't conform leaves `OperationTool` with no such conformance at
/// all, so `tool as? any EventEmittingTool` simply fails for it — there is
/// no runtime "is this connected" flag to check separately.
extension OperationTool: EventEmittingTool where Context: EventEmittingContext {
    /// Returns a copy of this tool wired to post events through `sink` —
    /// see `EventEmittingContext` (the opt-in sink every operation's
    /// `execute(in:)` posts through) and `EventEmittingTool`'s "hosts
    /// connect, users don't" contract.
    ///
    /// - Parameter sink: The sink the returned tool's events are posted to.
    /// - Returns: A copy of this tool sharing `context`'s other state,
    ///   routed to `sink`.
    public func connecting(_ sink: any OperationEventSink) -> any Tool {
        copy(context: context.connecting(sink))
    }
}

/// `OperationTool` conforms to `ForkableTool` unconditionally — forking is
/// always safe, whether or not `Context` opts into event emission: it's
/// always the receiver's own `context`, forked if `Context` opts in via
/// `ForkableContext`, shared unchanged otherwise.
extension OperationTool: ForkableTool {
    /// Returns a copy of this tool for a child session, forking `context`
    /// if it conforms to `ForkableContext` — otherwise the same `context`,
    /// shared unchanged (still sharing any reference-typed state it holds).
    ///
    /// - Returns: The forked tool instance.
    public func forked() -> any Tool {
        let forkedContext = (context as? any ForkableContext)?.forked() as? Context
        return copy(context: forkedContext ?? context)
    }
}

/// A thread-safe consecutive-failure counter for `OperationTool`'s retry
/// cap.
///
/// `OperationTool` is a value type, but `Tool.call(arguments:)` may run
/// concurrently across invocations (`@concurrent`), so the counter needs a
/// single shared, synchronized home rather than a stored `Int` on the
/// struct — an `actor` gives it both.
private actor RetryState {
    private var consecutiveFailures = 0

    /// Records a corrective failure and reports whether it was the one that
    /// pushed the count past `cap`, resetting to zero either way.
    ///
    /// - Parameter cap: The number of consecutive corrective failures
    ///   allowed before the caller should switch to a terminal message.
    /// - Returns: `true` once this failure is the `cap + 1`th in a row.
    fileprivate func recordFailure(cap: Int) -> Bool {
        consecutiveFailures += 1
        let exceeded = consecutiveFailures > cap
        if exceeded {
            consecutiveFailures = 0
        }
        return exceeded
    }

    /// Resets the counter to zero, e.g. after a successful dispatch.
    fileprivate func reset() {
        consecutiveFailures = 0
    }
}

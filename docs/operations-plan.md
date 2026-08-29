# FoundationModels Operation Tools — Plan

Bring the swissarmyhammer *Operation-based tool* pattern to Swift as a package that
targets Apple's **FoundationModels** framework, with a dual-use declarative CLI derived
from the same declarations.

## Goals

1. **Declare operations once.** A struct's fields ARE the parameters. A macro attaches
   verb + noun + description metadata. Optionality of fields derives requiredness.
2. **Fuse many operations into one `Tool`.** An `OperationTool` combines a set of
   operations sharing a context into a single FoundationModels `Tool` whose parameter
   schema is a fused union discriminated by an `op` field (`"verb noun"`), exactly like
   the sah MCP tools (`files`, `kanban`, `code_context`, …).
3. **Dual use.** The same declarations drive a declarative command-line interface:
   `mytool <noun> <verb> --param value` parses to the *identical* argument payload the
   model would produce, and flows through the identical dispatch path.
4. **Idiomatic Swift.** Lean on Apple's `@Generable`/`@Guide` for typed argument parsing
   and per-field descriptions instead of reinventing them; use Swift macros only for
   what `@Generable` doesn't give us (verb/noun metadata, parameter metadata table).

## Background: the Rust pattern we are porting

Reference implementation lives in `../swissarmyhammer` (see its `ARCHITECTURE.md`,
"Operation" section). The load-bearing decisions:

| Rust (swissarmyhammer) | Role |
|---|---|
| `#[operation(verb, noun, description)]` proc macro on a plain struct | Single source of metadata; fields are parameters; doc comments are descriptions; `Option<T>`/`#[serde(default)]` ⇒ optional |
| `trait Operation { verb, noun, description, parameters: &[ParamMeta], op_string() = "verb noun" }` | Metadata trait, object-safe, registry-friendly |
| `trait Execute<Ctx, Err> { async fn execute(&self, ctx) -> ExecutionResult<Value, Err> }` | Behavior, separate from metadata |
| `static OPERATIONS: Vec<&'static dyn Operation>` per tool | One registry drives MCP schema, CLI tree, docs |
| `generate_mcp_schema_wire` / `_full` | Two schema surfaces: slim for the model, full for CLI/docs |
| Forgiving parser (op aliases, verb aliases like `create→add`, key normalization, inference from present keys) | Layered per-tool leniency, not baked into the macro |
| `cli_gen::build_commands_from_schema` → clap noun→verb tree; `extract_noun_verb_arguments` inverts matches back to the JSON the MCP tool executes | CLI and model calls converge on an identical argument map |

Two deliberate **departures** for the Swift/FoundationModels port:

1. **No slim "wire" schema.** FoundationModels guided generation constrains token
   sampling to the schema — `additionalProperties: true` with no declared properties
   would prevent the model from emitting parameters at all. The real invariant: **every
   parameter must be a declared property** in the fused schema (built with
   `DynamicGenerationSchema`) — realized as a flat declared-property object (see the
   decided Schema fusion section). The wire/full split collapses to one fused schema
   for the model plus per-op metadata for the CLI.
2. **ArgumentParser via macro-generated commands + a runtime registry.** clap builds
   commands at runtime; swift-argument-parser's per-command options are compile-time
   property wrappers — but its command *tree* is an ordinary runtime value
   (`CommandConfiguration(subcommands: [ParsableCommand.Type])` behind a computed
   static property), and parsing, help, error text, and **completion-script
   generation** all walk that tree at invocation time (verified against the 1.8.2
   source; SwiftPM's `swift package` and Tuist assemble their trees exactly this way).
   Since `@Operation` sees the fields at macro-expansion time anyway, it also emits a
   real `ParsableCommand` per operation; `OperationTool` assembly populates a
   freeze-once registry the root command's computed configuration reads. Full
   ArgumentParser polish over a runtime-assembled tree.

## Architecture

### Package layout

Swift package `FoundationModelsOperations` in this repo, Swift 6.2 tools, platforms
macOS 26+ / iOS 26+ (FoundationModels availability). Targets:

```
Sources/
  Operations/            # core: protocols, ParamMeta, registry, OperationTool, parsing
  OperationsMacros/      # @Operation / @OperationParam macro implementations (SwiftSyntax)
  OperationsCLI/         # ArgumentParser registry driver (noun→verb tree assembly)
Examples/
  NotesTool/             # demo: a "notes" tool (add/get/list/delete note) exercised
                         #   both via LanguageModelSession and via CLI
Tests/
  OperationsTests/       # protocol, registry, dispatch, schema-fusion tests
  OperationsMacrosTests/ # assertMacroExpansion tests
  OperationsCLITests/    # CLI parse → payload round-trip tests
```

Dependencies: `swift-syntax` (macros target only), `swift-argument-parser` 1.8+
(`OperationsCLI` and macro-generated command types). FoundationModels is a system
framework.

### Declaring an operation

```swift
import FoundationModels
import Operations

@Generable
@Operation(verb: "add", noun: "note", description: "Create a new note")
struct AddNote {
    @Guide(description: "The note title")
    var title: String

    @Guide(description: "Markdown body of the note")
    var body: String?

    @Guide(description: "Tags to attach")
    var tags: [String]?
}

extension AddNote {
    func execute(in context: NotesContext) async throws -> Note {
        try await context.store.insert(title: title, body: body, tags: tags ?? [])
    }
}
```

- **`@Generable` (Apple)** supplies `GenerationSchema` + `ConvertibleFromGeneratedContent`
  (typed parsing of model output) and `@Guide` field descriptions. We do not replace it.
- **`@Operation` (ours)** is an attached extension+member macro that:
  - adds conformance to our `OperationDefinition` protocol,
  - emits `static var verb/noun/operationDescription`,
  - walks the stored properties and emits `static var parameterMetadata: [ParamMeta]` —
    name, `ParamType` (string/int/number/bool/array-of), required (`Optional` ⇒ no),
    description (extracted from the `@Guide(description:)` argument when present, else
    from the doc comment trivia), plus CLI affordances from an optional
    `@OperationParam(short: "t", aliases: ["name"])` peer attribute.
- Behavior lives in a plain `execute(in:)` method required by the protocol — mirrors the
  Rust `Operation` (metadata) / `Execute` (behavior) split without a second trait.

Core protocol sketch:

```swift
public protocol OperationDefinition: Generable, Sendable {
    associatedtype Context: Sendable
    associatedtype Output: Encodable & Sendable

    static var verb: String { get }
    static var noun: String { get }
    static var operationDescription: String { get }
    static var parameterMetadata: [ParamMeta] { get }
    static var opString: String { get }            // default: "\(verb) \(noun)"

    func execute(in context: Context) async throws -> Output
}
```

`Output: Encodable` keeps results JSON-serializable for both surfaces: the fused tool
returns the JSON string to the model (a valid `PromptRepresentable`), and the CLI prints
it. (A later enhancement can special-case `Output: Generable` to return structured
`GeneratedContent`.)

**Manual escape hatch** (parity with sah's hand-written `ReadFile`): conform to
`OperationDefinition` directly with a hand-rolled `parameterMetadata` array — the macro
is sugar, never a requirement.

### Type erasure and registry

`OperationDefinition` has associated types, so the registry stores erased entries:

```swift
public struct AnyOperation<Context: Sendable>: Sendable {
    public let verb, noun, description: String
    public let parameters: [ParamMeta]
    let run: @Sendable (GeneratedContent, Context) async throws -> String  // JSON out

    public init<O: OperationDefinition>(_ type: O.Type) where O.Context == Context
}
```

`run` constructs the typed struct via `O(GeneratedContent)` (from `@Generable`) and
calls `execute(in:)` — dispatch always flows through the typed struct, never through
raw dictionaries, matching the Rust design.

### Fusing into one Tool

```swift
public struct OperationTool<Context: Sendable>: FoundationModels.Tool {
    public typealias Arguments = GeneratedContent   // GeneratedContent is Generable
    public typealias Output = String

    public init(name: String, description: String, context: Context,
                operations: [AnyOperation<Context>])

    public var parameters: GenerationSchema        // fused, built once at init
    public func call(arguments: GeneratedContent) async throws -> String
}
```

**Schema fusion — DECIDED: flat union with an `op` discriminator** (sah `_full`
shape). Resolved during planning from primary-source research; the rejected
discriminated-`anyOf` shape is in Alternatives. One object schema: `op` is a required
string enum (the `DynamicGenerationSchema(anyOf: [String])` overload) of all op
strings, plus the union of every operation's fields, all optional; first description
wins on collisions.

The evidence that decided it:

- **Apple-confirmed, still-unfixed bug: enum values are not enforced on tool
  arguments.** The model can emit values outside an `anyOf` list (Apple forums 812501 —
  staff: "fairly confident it's a bug on our end" — and 811620; unresolved as of
  mid-2026). A discriminated `anyOf`-of-objects design hangs its *entire arm-selection
  mechanism* on exactly this broken enforcement, and behavior when the model targets a
  nonexistent arm is publicly undefined. The flat union treats `op` as advisory and
  validates at dispatch — which is Apple's own recommended workaround for this bug.
- **Token budget is the binding constraint.** Tool schemas are injected verbatim into
  the prompt and count against the on-device context window (fixed 4,096 tokens on the
  iOS 26 model, 8,192 on newer — query `SystemLanguageModel.contextSize`; TN3193). The
  flat union is strictly smaller than a per-arm union repeating shared fields across
  10–55 arm wrappers.
- **Structural enforcement (shape, not enum membership) appears intact** — no public
  report of the on-device model producing structurally invalid tool arguments — so the
  flat schema's declared properties are respected; only the discriminator needs
  server-side validation, which dispatch does anyway.
- The `op` enum stays in the schema regardless: it documents the choices in the prompt
  today and becomes load-bearing if Apple ships the enforcement fix.
- (If typed per-op requiredness is ever revisited: the settling micro-experiment is a
  ~1-hour anyOf-of-N-object-arms probe at N=3/10/25 measuring build success, arm
  selection, and `tokenCount(for:)` — documented here so it isn't re-researched.)

**Scale guidance** (consequence of the same evidence): TN3193 says "provide maximum
3–5 tools" with small types and short names. A fused tool should carry roughly 5–15
ops on-device, not 55 — partition big domains into a few `OperationTool`s. Prune the
flat field union by sharing identically-named fields across ops where semantics match;
keep names short and *distinct* (practitioner reports show the model confuses
similarly-named string fields). The example measures the rendered tool definition with
`tokenCount(for:)`.

`call(arguments:)` pipeline: forgiving-resolve `op` → look up `AnyOperation` → validate
required params → `run(content, context)`.

**Error handling — return, don't throw.** When a `Tool.call` throws, FoundationModels
does *not* feed the error back to the model for self-correction: `session.respond`
rethrows it to the caller as `LanguageModelSession.ToolCallError`, aborting the turn.
So resolver and validation failures (unknown op, missing required params, unparseable
values) are **returned as the tool's `String` output** — a corrective message listing
valid ops / missing params — mirroring sah's MCP `is_error` content pattern, so the
model can retry within the turn. `throw` is reserved for genuinely fatal conditions
(context failure, cancellation) the host app must handle. **Retry cap:** corrective
feedback can send the on-device model into retry loops (reported alongside the enum
bug), and every retry burns context — `OperationTool` caps corrective retries per
session turn (default 2), then returns a terminal "invalid operation, stopping" message.

**Schema-in-prompt cost.** The framework injects the tool schema into the prompt by
default (`includesSchemaInInstructions`); for a many-op fused schema this is the
dominant context cost. `OperationTool` exposes this knob, and task 7 measures rendered
prompt size (`tokenCount(for:)`) alongside call accuracy.

### Forgiving input (layered, like the Rust side)

An `OperationResolver` owned by `OperationTool`, with defaults and per-tool hooks:

1. Explicit `op` ("add note"), case-insensitive, tolerant of `"note add"` order and
   `_`/`-` separators.
2. Verb aliases via a shared table (`create/new → add`, `show/read/fetch → get`,
   `remove/rm/del → delete`, …), extensible per tool.
3. Parameter key aliases from `ParamMeta.aliases` + camelCase/snake_case normalization,
   never clobbering an explicitly present canonical key.
4. Optional per-tool inference closure (`(GeneratedContent) -> String?`) for op-less
   payloads — opt-in, not baked into the macro (matches Rust: forgiveness is layered,
   per-domain).

### Dual-use CLI

`OperationsCLI` consumes the same `AnyOperation` metadata:

```swift
let cli = OperationCLIDriver(tool: notesTool)         // or multiple tools
try await cli.run(CommandLine.arguments)              // notes note add --title "Hi" --tags a --tags b
```

- Command tree is **noun → verb** (`notes note add …`), from `opString` split, same as
  sah's `cli_gen`. With multiple tools the grammar is `<executable> <tool-name> <noun>
  <verb> …`; with exactly one tool the tool level collapses. Nouns never merge across
  tools, so cross-tool noun collisions are impossible; on the session side each
  `OperationTool` resolves ops only within its own registry, and tool `name` uniqueness
  is the host app's responsibility (asserted at driver init).
- **Leaves are macro-generated ArgumentParser commands.** `@Operation` emits a nested
  `Command: AsyncParsableCommand` with genuine `@Option`/`@Flag`/`@Argument`
  declarations derived from the same stored properties (`Bool` ⇒ flag, arrays ⇒
  repeatable, `Optional` ⇒ not required; help text from `@Guide` descriptions,
  shorts/aliases from `@OperationParam`). Its `run()` serializes the parsed values into
  the canonical payload (`op` + fields, via `GeneratedContent(json:)`) — **the same
  shape the model sends** — and executes through the exact same `AnyOperation.run`
  path. This convergence is the contract, and a round-trip test pins it.
- **The tree is assembled at runtime.** `OperationCLIDriver` populates a freeze-once
  registry (Swift 6: `Mutex`-guarded set-then-seal before first parse), groups verb
  command metatypes by noun, and the root command's *computed*
  `static var configuration` reads it. Noun-level nodes are a generic `NounNode`
  instantiated per noun via opened existentials, so the whole tree is stock
  ArgumentParser — which means `--help` at every level, did-you-mean suggestions,
  `--opt=value`, combined short flags, `--` termination, and
  `--generate-completion-script` all work over the runtime-assembled tree (completion
  generation walks the tree at invocation time; verified in 1.8.2's `CommandParser`).
- **Known trade-offs** (accepted): tree validation happens at first parse rather than
  compile time — mitigated by a startup assertion pass over the registry plus a help
  snapshot test; correct `tool noun verb` prefixes in leaf help use the
  underscored-but-stable `_superCommandName` (SwiftPM ships on it) or an explicit
  `usage:` string; the registry pattern is exercised by SwiftPM/Tuist but not
  documented in DocC.

## Alternatives considered

1. **One FoundationModels `Tool` per operation, no fusion.** Simplest; but 50+ tools per
   domain (kanban has ~55 ops) bloats the session's tool list and per-turn overhead —
   precisely the economics the Operation pattern exists to fix. Rejected as the primary
   shape; note that each op *could* still be trivially wrapped as a standalone `Tool`
   later since it's `@Generable` already.
2. **Macro-generated fused `@Generable` enum** (one enum, case per op with associated
   values). Attractive in theory (`anyOf` for free) but freezes the operation set at
   compile time in a single declaration, prevents mixing operations across
   modules/registries, and produces an unwieldy macro. Rejected.
3. **Pure runtime DSL, no macros** (ParamMeta builders only, like sah's hand-written
   files ops). Kept as the escape hatch, not the main path — losing `@Generable` typed
   parsing would be un-idiomatic. (Note: an op declared this way has no macro-generated
   CLI command; the driver synthesizes a fallback leaf from `ParamMeta` for it.)
4. **Hand-rolled metadata-driven CLI parser** (the original plan; also what SwiftPM
   plugins/Tuist do for dynamic commands). Researched and dropped: that prior art
   exists because those tools' command *parameters* are unknown at compile time —
   external plugin binaries. Ours are visible to the macro, so ArgumentParser leaves
   over a runtime registry win: hardened tokenizer, polished help, and shell
   completions, none of which the hand-rolled path (or any surveyed third-party
   library — ConsoleKit's command layer is EOL in v5, Commander/SwiftCLI dormant since
   2021-22, argtree is a 2-star bus-factor-1 project) provides together.
5. **Discriminated `anyOf`-of-objects schema** (per-op arms, each
   `{op: single-value enum, …typed fields with true requiredness}`). API-supported
   (`DynamicGenerationSchema(name:anyOf: [DynamicGenerationSchema])`, and Apple's own
   CoreSpotlight `SpotlightSearchTool` ships a discriminated-union tool schema), but
   rejected on evidence: arm selection would ride the Apple-confirmed, unfixed
   enum-enforcement bug (forums 812501/811620); the shape is strictly larger against a
   4,096/8,192-token window; and no public source demonstrates a many-armed object
   union working on the tool path. Revisit if Apple fixes enforcement — the ~1-hour
   micro-experiment is recorded in the Schema fusion section.

## Tasks

Ordering is a dependency graph, not phases; each task is independently implementable
and verifiable with automated tests (`swift test`).

### 1. Package scaffolding
**What:** `Package.swift` (swift-tools 6.2, macOS 26/iOS 26 platforms, swift-syntax +
swift-argument-parser dependencies), empty targets per layout above, CI-runnable
`swift build && swift test`.
**Accept:** package builds; one placeholder test passes in each test target.

### 2. Core metadata types + protocol (no macro yet)
**What:** `ParamType`, `ParamMeta` (name, type, required, description, short, aliases,
allowedValues), `OperationDefinition`, `AnyOperation`, `OperationError`. Hand-conform a
fixture op to prove the manual path.
**Tests:** unit tests for `opString` default, `AnyOperation.run` happy/`throws` paths
against a fake context; JSON output shape.

### 3. `@Operation` macro (+ `@OperationParam`)
**What:** attached extension+member macro in `OperationsMacros`; conformance, statics,
`parameterMetadata` synthesis from stored properties; description extraction from
`@Guide` argument (fallback: doc comment trivia); `Optional` ⇒ not required; diagnostics
for unsupported field types, missing verb/noun, and the reserved parameter name `op`
(including names that normalize to `op`). Extraction contract: only *literal*
`@Guide(description:)` strings are read; `allowedValues` comes from `@OperationParam`
or a recognized literal `@Guide(.anyOf([...]))`; other `@Guide` constraint forms are
left to Apple's schema and ignored in `ParamMeta`. Also emits a nested
`Command: AsyncParsableCommand` (ArgumentParser leaf): `@Option`/`@Flag`/`@Argument`
per field, `CommandConfiguration(commandName: verb, abstract: description)`, and a
`run()` that serializes parsed values to the canonical payload and dispatches through
`AnyOperation.run`.
**Tests:** `assertMacroExpansion` fixtures — simple op, optional/array fields, unit
struct (no fields), `@OperationParam` short/aliases, `@Guide` with constraint
arguments, reserved-name `op` diagnostic, error diagnostics, generated `Command`
shape (flag vs option vs repeatable mapping).
**Depends on:** 2.

### 4. Schema fusion (flat union)
**What:** build the flat-union `GenerationSchema` from `[AnyOperation]` via
`DynamicGenerationSchema` — required `op` string enum (`anyOf: [String]` overload) +
all-optional field union; collision policy (first description wins; a parameter named
`op` is a fusion-time error); deterministic property order; shared-field dedup by name.
**Tests:** structural assertions on the fused schema for a 3-op fixture set — property
names present, op-enum membership, everything-but-`op` optional, deterministic order,
shared fields appear once — not byte-level snapshots of Apple's encoding (which may
shift across OS releases). Collision tests, including the reserved-`op` error. A small
`#available`-guarded executable check against the live model is part of the example
task (7), not CI.
**Depends on:** 2.

### 5. `OperationTool` + dispatch + forgiving resolver
**What:** `Tool` conformance, `call` pipeline, `OperationResolver` (op normalization,
verb-alias table, key aliasing, optional inference hook), corrective error messages
listing valid ops / missing required params.
**Tests:** dispatch to correct op from exact/aliased/reordered op strings; unknown-op
and missing-required cases assert the corrective message is *returned* as output, not
thrown; key-alias normalization; inference hook; extra-`op`-key tolerance of the typed
init (or stripping fallback); retry cap — third consecutive corrective failure in a
turn returns the terminal message, not another correction.
**Depends on:** 2, 4.

### 6. CLI driver (ArgumentParser registry)
**What:** `OperationCLIDriver` in `OperationsCLI`: freeze-once registry
(`Mutex`-guarded set-then-seal), generic `NounNode` via opened existentials, root
command with computed `configuration`, startup assertion pass over the registry
(duplicate names, malformed tree), JSON output printing, exit codes; fallback leaf
synthesis from `ParamMeta` for manually-conformed (macro-less) operations.
**Tests:** argv → payload round-trip equals the payload the resolver accepts (the
convergence contract, including `--opt=value`, combined short flags, repeated options,
`--`); help snapshots at tool/noun/verb levels (correct `tool noun verb` prefixes);
`--generate-completion-script` output contains every noun, verb, and flag from a
runtime-assembled registry; multi-tool grammar (tool level present with two tools,
collapsed with one; duplicate tool names rejected at init); error cases (unknown
noun/verb with did-you-mean, missing required, bad int).
**Depends on:** 2, 3 (generated leaf commands), 5 (shares dispatch).

### 7. Example: NotesTool (dual-use, end-to-end)
**What:** `Examples/NotesTool` — 4–5 ops over an in-memory store via macro declarations;
executable with two modes: `notes …` CLI, and a `--chat` mode registering the
`OperationTool` on a `LanguageModelSession` (guarded by model availability; skips
gracefully off-device). The live-model run validates the decided flat-union schema:
measure op-call accuracy over a scripted prompt set, rendered tool-definition size via
`tokenCount(for:)` (including the `includesSchemaInInstructions` on/off delta), and
observe the retry-cap behavior on deliberately invalid prompts.
**Tests:** integration tests exercising every op through `AnyOperation` and through the
CLI driver; the live-model path is manual-run but scripted (`swift run notes --chat`).
**Depends on:** 3, 5, 6.

### 8. Docs
**What:** README (declare → fuse → serve → CLI in four code blocks), DocC comments on
public API, note the departures from the Rust design and why.
**Accept:** README examples compile (doc-snippet test or included in example target).
**Depends on:** 7.

## Risks & verification points

- **Enum enforcement bug** (Apple forums 812501/811620): `op` enum values are not
  constrained at prediction time — mitigated by dispatch validation + retry cap
  (already the design); revisit schema strategy if Apple ships the fix.
- **All-optional flat schemas are untested territory in public writing**: practitioner
  reports say the model may omit or blank optional fields in larger structs. Mitigated
  by dispatch-time required-param validation and the scale guidance (5–15 ops); task
  7's live run is the check.
- **`GeneratedContent` behavior with extra keys**: tolerated with medium-high
  confidence (the `@Generable` init reads only declared properties via
  `value(forProperty:)`; nothing enumerates leftovers) but not documented by Apple. If
  it ever breaks, the resolver strips `op` (and any non-parameter keys) before
  constructing the op. Pinned by a test in task 5.
- ~~`GeneratedContent(json:)` availability~~ — **resolved**: `init(json:) throws` is
  documented, and deliberately *lenient* ("may be incomplete"), so the CLI path must
  serialize well-formed JSON itself rather than lean on validation.
- **Macro reading `@Guide` descriptions**: attached macros see sibling attribute syntax,
  so the argument literal is extractable; doc-comment trivia is the fallback. Pinned by
  task 3's expansion tests.
- **ArgumentParser registry pattern**: stable public API but undocumented in DocC
  (SwiftPM/Tuist are the prior art); `_superCommandName` is underscored (SwiftPM ships
  on it — fallback is explicit `usage:` strings); registry must be sealed before the
  first parse on *every* invocation, including completion callbacks. Covered by task
  6's assertion pass and completion-script test.
- **Toolchain**: requires Xcode 26 / macOS 26 SDK to build, and — because tasks 4–7's
  tests construct `GenerationSchema`/`GeneratedContent` at runtime — **macOS 26 CI
  runners** to execute `swift test`, even for non-model tests. Live-model runs
  additionally need an Apple-silicon Mac with Apple Intelligence enabled; CI scope is
  build + non-model tests.

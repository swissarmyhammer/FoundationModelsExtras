# Design notes

This document records where the shipped implementation departs from a stated design —
either from the Rust `swissarmyhammer` pattern this package ports, or from this
project's own [`plan.md`](plan.md) as written before implementation began — and why.
`plan.md` is the design record of record; this document is the changelog against it.

## Departures from the Rust `swissarmyhammer` design

`plan.md`'s "Background" section names two deliberate departures from the Rust pattern,
decided during planning from primary-source research before any Swift code was written.
They're summarized here; `plan.md` has the full evidence trail.

### 1. Flat-union schema instead of a slim "wire" schema

The Rust side generates two schema surfaces per tool: a slim one for the model
(`generate_mcp_schema_wire`) and a full one for the CLI/docs (`_full`). FoundationModels'
guided generation constrains token sampling to the declared schema, so a slim schema with
no declared properties would prevent the model from emitting any tool parameters at all —
there is no equivalent of a permissive `additionalProperties: true`. The real invariant
carried over instead: **every parameter must be a declared property** in the schema
`OperationTool` presents. Rather than a discriminated `anyOf`-of-objects (one arm per
operation, each with true per-field requiredness), the schema is a **flat union**: one
object with a required `op` string enum plus the union of every operation's fields, all
declared optional. `Sources/Operations/SchemaFusion.swift` implements this; the fields
are validated for real requiredness at dispatch time in
`Sources/Operations/OperationTool.swift`, not by the schema.

Two pieces of evidence decided this over the discriminated-union alternative:

- An Apple-confirmed, unfixed bug means enum values are not enforced on tool arguments —
  a discriminated schema's entire arm-selection mechanism would ride exactly that broken
  enforcement.
- Tool schemas are injected into the prompt and count against a fixed, small context
  window; the flat union is strictly smaller than a per-arm union that repeats shared
  fields across every operation's wrapper.

See `plan.md`'s "Schema fusion — DECIDED" section for the full citations and the
rejected-alternative writeup (`plan.md`, "Alternatives considered", #5).

### 2. ArgumentParser via macro-generated commands over a runtime registry

The Rust CLI builds its `clap` command tree at runtime from a schema
(`cli_gen::build_commands_from_schema`). swift-argument-parser's per-command options are
compile-time property wrappers, but its command *tree* — `CommandConfiguration(subcommands:)`
behind a computed `static var` — is an ordinary runtime value; SwiftPM's own `swift package`
and Tuist assemble their command trees exactly this way. `@Operation` sees a struct's
fields at macro-expansion time, so it emits a real `ParsableCommand` leaf per operation;
`Sources/OperationsCLI/CLIRegistryBuilder.swift` then assembles those leaves into a
freeze-once runtime registry the root command's computed configuration reads
(`Sources/OperationsCLI/CommandTree.swift`). This gets real ArgumentParser polish —
`--help` at every level, did-you-mean suggestions, combined short flags, and
`--generate-completion-script` — over a tree that's still built at runtime, rather than
either a hand-rolled parser (the original alternative surveyed and dropped — see
`plan.md`, "Alternatives considered", #4) or one fixed at compile time.

## Departures discovered during implementation

These weren't anticipated in `plan.md`; each was found and resolved while implementing a
specific task, and is recorded here (and, in more detail, in that task's kanban comment
history) so a future change doesn't accidentally "fix" it back to the original plan text.

### `GeneratedContent` construction: `properties:` initializer, not `GeneratedContent(json:)`

`plan.md`'s "Dual-use CLI" section describes the macro-generated CLI leaf serializing
parsed values "via `GeneratedContent(json:)`". The shipped
`Command.operationPayload()` (in `@Operation`'s macro expansion,
`Sources/OperationsMacros/OperationsMacros.swift`) instead builds the payload with
`GeneratedContent(properties: [(String, any ConvertibleToGeneratedContent)],
uniquingKeysWith:)`. Round-tripping through `JSONSerialization` +
`GeneratedContent(json:)` would require every file that applies `@Operation` to add an
explicit `import Foundation` — confirmed by a real compile failure
(`"cannot find 'JSONSerialization' in scope"`) against a fixture that only imports
`FoundationModels`. The `properties:` initializer needs no such import, since every
`@Operation`-supported field type already conforms to `ConvertibleToGeneratedContent`,
and produces the identical canonical `op` + fields payload shape.
`Sources/OperationsCLI/FallbackOperationCommand.swift`'s `FallbackPayloadBuilder` (the
macro-less escape hatch's equivalent) uses the same initializer for the same reason.

### `Command.run()` stays print-only; the CLI driver dispatches, not the leaf

`plan.md`'s CLI leaf description says `run()` both serializes the payload *and*
"dispatch[es] through the shared `AnyOperation.run` execution path". In practice, the
macro-generated `Command.run()` has no way to obtain a live `Context` instance —
`Context` is an associated type resolved per concrete operation struct, and nothing at
the macro-expansion site owns one. `Command.run()` stays
`print(operationPayload().jsonString)`; `operationPayload() -> GeneratedContent`
(declared by the `OperationCommand` protocol, `Sources/Operations/OperationCommand.swift`)
is the stable extension point instead. `OperationCLIDriver.dispatch(command:)`
(`Sources/OperationsCLI/OperationCLIDriver.swift`) intercepts a parsed command *before*
calling its `run()`, extracts `operationPayload()`, and dispatches it through the owning
`OperationTool.call(arguments:)` itself — the same path a model call uses. A leaf's own
`run()` only prints when driven directly, outside `OperationCLIDriver` (which never
happens in the CLI executable's normal path).

### `OperationError.encodingFailed`, split from `.decodingFailed`

Not in `plan.md`'s original four-case sketch. `AnyOperation.run`
(`Sources/Operations/AnyOperation.swift`) has two independent failure points after a
successful decode: JSON-encoding the operation's `Output`, and UTF-8-decoding the
resulting bytes. Both originally reused `.decodingFailed`, which was surfacing an
output-side failure under an input-side name — added as a real bug fix during the core
metadata-types task and caught by review. `.decodingFailed` is now reserved for
`OperationDefinition.init(_:)` failures (the payload didn't parse into the target
operation type); `.encodingFailed` covers everything downstream of a successful decode.

### Required array fields must serialize as `[]`, not be omitted

The macro's original payload-assignment rule only included a repeatable field's `@Option`
value in the payload when it was non-empty — reasonable for an *optional* array, but
wrong for a *required* one: `Generable`'s synthesized decoder throws when a required
property's key is missing at all, even to represent an empty array. Found via TDD while
building the CLI driver (a required `scores: [Int]` fixture field, left empty on the
command line, failed to decode). Fixed in `payloadAssignmentText`
(`Sources/OperationsMacros/OperationsMacros.swift`): a required array field is always
included, as `[]` when empty — matching how a required scalar field was already handled.

### Extra-key tolerance is enforced by construction, not left to `@Generable`

`plan.md`'s "Risks & verification points" flags an open question: does `@Generable`'s
synthesized `init(_:)` tolerate extra keys in a `GeneratedContent` payload (e.g. the `op`
discriminator itself, which isn't one of an operation's own fields) with only
"medium-high confidence", and proposes stripping `op` before construction "if it ever
breaks". The shipped `OperationResolver.resolveParameters(_:matching:)`
(`Sources/Operations/OperationResolver.swift`) doesn't wait to find out: it always
rebuilds a fresh, canonically-keyed `GeneratedContent` containing only an operation's
declared parameters, dropping `op` and any other unrecognized key unconditionally. This
sidesteps the open question by construction rather than resolving it empirically.

### Retry-cap state lives in a private `actor`, not a stored counter

`OperationTool` is a value type (a `struct`), but `Tool.call(arguments:)` may run
concurrently across invocations. A plain stored `Int` counter for the retry cap would
race; the shipped design (`Sources/Operations/OperationTool.swift`) puts the counter in a
private `actor RetryState` instead, giving it a single synchronized home independent of
`OperationTool`'s own value semantics. Not mentioned as a mechanism in `plan.md`, which
only specifies the retry-cap *behavior*.

### `OperationKeys`: one shared home for the `op` key and its normalization rule

Not called out as a distinct type in `plan.md`. `SchemaFusion` (checking whether a
parameter name collides with the reserved `op` discriminator, at fusion time) and
`OperationResolver` (matching payload keys against declared parameter names and aliases,
at dispatch time) both need an identical definition of "the same name, ignoring case and
`_`/`-` separators" — originally duplicated as a private implementation detail of
`SchemaFusion.swift`. Extracted to `Sources/Operations/OperationKeys.swift` once a second
call site needed it, so the two layers can't drift apart on what counts as a collision.

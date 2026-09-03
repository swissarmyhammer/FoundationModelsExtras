# Doctor Plan — `Doctorable`

This plan adds one small module to this package: a health-check protocol,
a registry, and a terminal renderer. It stands on its own. `plan.md` does
not change.

## 1. Purpose

Every CLI in the family needs one command that answers a single question:

> Will this configuration actually work?

The answer must not be a stack trace. It must be a list of named checks,
each with a status, a message, and — when something is wrong — **the
command that fixes it**.

This package holds the protocol and the renderer, because it is the
lowest package that every CLI already depends on. The checks themselves
stay in the packages that know the subject matter.

## 2. The model, from the Rust original

The design is a port of the `swissarmyhammer` Rust CLI, which has run
this pattern for a long time. Its parts:

| Rust | Where | Job |
|---|---|---|
| `Doctorable` trait: `name`, `category`, `run_health_checks`, `is_applicable` | `swissarmyhammer-common/src/health.rs` | A component reports its own health. |
| `HealthCheck { name, status, message, fix, category }` | same | One finding. |
| `HealthStatus { Ok, Warning, Error }` | same | Three levels, and no more. |
| `HealthCheckRegistry` | same | Collects components, skips the ones that do not apply, flattens the results. |
| `DoctorRunner`, `ExitCode`, `print_table` | `swissarmyhammer-doctor` | The runner and the table. |

Two lessons from that code, which this plan keeps:

- **`fix` is not optional in practice.** A check that reports a problem
  and gives no fix makes a person search. Every `Warning` and every
  `Error` carries a fix line.
- **`is_applicable` matters.** A check for a component that is turned off
  must not report a failure. It must report nothing.

## 3. What changes for Swift

Two changes, and both are because Swift is not Rust:

1. **`runHealthChecks() async`.** The Rust trait is synchronous, so its
   CLI needed a separate asynchronous collection step. Our checks reach
   the disk and the network — a model repository, an MCP server, a
   subprocess — so the protocol is asynchronous from the start.
2. **A `DoctorReport` value, and not a `checks_mut()` accessor.** The
   Rust `DoctorRunner` hands out a mutable vector. A protocol that vends
   mutable storage is not Swift. A runner returns a value, and the value
   computes the exit code.

## 4. The surface

```swift
public enum HealthStatus: Sendable { case ok, warning, error }

public struct HealthCheck: Sendable, Equatable {
    public let name: String
    public let status: HealthStatus
    public let message: String
    /// The command or the action that fixes it. Required for
    /// `.warning` and `.error`; `nil` for `.ok`.
    public let fix: String?
    public let category: String
}

public protocol Doctorable: Sendable {
    var doctorName: String { get }
    var doctorCategory: String { get }
    var isApplicable: Bool { get }          // default: true
    func runHealthChecks() async -> [HealthCheck]
}

public struct DoctorReport: Sendable {
    public let checks: [HealthCheck]
    public var worstStatus: HealthStatus { get }
    public var exitCode: Int32 { get }
}

public struct DoctorRunner: Sendable {
    public init(components: [any Doctorable])
    public func run() async -> DoctorReport
}
```

`runHealthChecks()` returns and does not throw. A check that cannot run
is a finding, and not an error: it reports `.error` with the reason in
its message. One broken check must never stop the other checks.

The components run **concurrently**, in a task group. A doctor that
reaches four MCP servers one after the other is slow for no reason. The
output keeps the order the components were registered in, so the report
is stable.

## 5. Exit codes

| Code | Meaning |
|---|---|
| 0 | Every check is `.ok` |
| 1 | At least one `.error` |
| 5 | At least one `.warning`, and no `.error` |

**This differs from the Rust original, on purpose.** That CLI exits 2 for
errors. The family's Swift CLIs already use 2 for a usage error, so a
script would read a broken configuration as a typing mistake. Error moves
to 1, and warnings take a code of their own.

## 6. The renderer

The renderer writes the report as a table: status, name, message. A
`.warning` or an `.error` prints its fix line under the row.

- The renderer writes to **stderr**, not stdout. A doctor report is a
  diagnostic.
- `--json` writes the report to **stdout** as one JSON array, so a script
  can read it. `HealthCheck` is `Codable` for this reason.
- Color and box drawing only when the destination is a terminal. A pipe
  gets plain text, in a stable, testable form.

The table itself comes from the terminal package each CLI already uses
(see the CLI plans: `Noora`, after its spike). This package does **not**
declare that dependency. It vends the report, and it vends a plain-text
renderer with no dependency. A CLI that wants a decorated table renders
`DoctorReport` itself.

That split is the important one: **this package must stay free of a
terminal dependency**, because it is a library that also runs inside a
Mac app.

## 7. Who implements `Doctorable`

| Package | Component | Reports |
|---|---|---|
| `FoundationModelsACPAgent` | The configuration | The load result, the layer paths, the unknown-key warnings |
| | The profile | Each model reference resolves; the trio fits the machine's memory; the free disk against the download |
| | The tool roster | The transcripts directory is writable; the sandbox works; each MCP server answers |
| `FoundationModelsACPClient` | The agent command | The command exists, it starts, `initialize` answers, and the protocol version matches |
| `FoundationModelsMultitool` | Each capability | Its own preconditions |

Each package writes its own checks. This package never knows what a model
or an MCP server is.

## 8. Testing

| Test | Why |
|---|---|
| A `Doctorable` with only `doctorName` and `doctorCategory` gives one `.ok` check. | The default implementation, as the Rust test pins it. |
| `isApplicable == false` contributes no checks, and stays in the registry. | A disabled component must be silent, not failing. |
| The exit code of §5, for each of the three cases. | The contract a script reads. |
| One component that takes a long time does not delay the others. | The concurrency claim of §4. |
| The report order matches the registration order. | A stable report. |
| The plain renderer output holds no ANSI escape when the destination is not a terminal. | The pipe rule of §6. |
| `HealthCheck` round-trips through JSON. | The `--json` contract. |

## 9. Milestones

| ID | Work |
|---|---|
| D1 | `HealthStatus`, `HealthCheck`, `Doctorable`, and the default implementations. |
| D2 | `DoctorRunner` and `DoctorReport`: concurrent run, stable order, exit codes. |
| D3 | The plain-text renderer, and the JSON encoding. |

D1 to D3 are small, and they are in order. They block the `doctor`
subcommand in both CLIs.

---
assignees:
- claude-code
depends_on:
- 01M4NXYSFK4SHNDB2YFVSVB1HX
position_column: todo
position_ordinal: '8e80'
title: 'Tool hosting: nested mounts in ToolContext keep the session tracer'
---
## What

A nested mount loses the tracer. `ToolContext.mount(_:op:as:)` (`Sources/FoundationModelsExtras/Hosting/ToolContext.swift:345`) and `mount(_:op:as:postingTo:)` (`:383`) make a `MountSite` with `tracer: nil`. Thus an inner call uses `InstrumentationSystem.tracer`, and ignores the tracer that the host gave to `MountSite` (`Sources/FoundationModelsExtras/Hosting/ToolMounting.swift:66`). `ToolContext` keeps no tracer now.

Change:
- Keep `site.tracer` in `ToolContext` when the context is made (`Sources/FoundationModelsExtras/Hosting/ToolRun.swift:54`, `Sources/FoundationModelsExtras/Hosting/ContextBindingTool.swift:55`).
- Pass that tracer to the `MountSite` at `ToolContext.swift:345` and `:383`, not `nil`.

This task was part (c) of task `vsvb1hx`.

## Acceptance Criteria
- [ ] A tool that `ToolContext.mount` mounts uses the tracer of the session, for both `mount` overloads.
- [ ] A context made at `ToolRun.swift:54` and at `ContextBindingTool.swift:55` keeps `site.tracer`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift`: with `W3CInMemoryTracer`, an inner call of a mounted tool records its span on the tracer of the host `MountSite`, for both overloads.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug
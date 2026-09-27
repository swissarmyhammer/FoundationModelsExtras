---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3j2qkbd0f548mp8sbr350dr
  text: |-
    ### finish iteration 1 — review clean

    - implement: Added the fixture `SchemaOmittingTool` (its `includesSchemaInInstructions` is `false`) in MountingFixtures.swift. Added the parameterized test `runnerForwardsTheMetadataOfTheWrappedTool(mode:)` in ToolMountingTests.swift, with one case for the background mode and one case for the run-to-completion mode. No change to Sources.
    - test: `swift build --build-tests` completed with 0 compiler warnings. `swift test` ran 739 tests in 72 suites, and all passed.
    - commit: 17af87f "test(hosting): test the metadata that a mount runner gives from its tool". The commit also holds the kanban changes of task ^kr6ya6v.
    - review: `review sha HEAD~1..HEAD` gave 0 findings. The task moves to `done`.
  timestamp: 2026-09-27T18:41:11.021132+00:00
position_column: done
position_ordinal: cd80
title: 'Add tests for the MountRunner forwarders: name, description, parameters and includesSchemaInInstructions'
---
Sources/FoundationModelsExtras/Hosting/ToolMounting.swift:121-130

Coverage: 93.0% (66/71 lines)

Uncovered lines: 121, 124, 127, 130

`var name: String`, `var description: String`, `var parameters: GenerationSchema`, `var includesSchemaInInstructions: Bool` in `extension MountRunner`

The shared extension of `BackgroundToolRunner` and `RunToCompletionRunner` forwards the metadata of the wrapped tool. The model sees these values, so a wrong forwarder breaks the tool call. No test reads them.

What to test:
- Wrap a tool with `ToolMounting` in the background mode and in the run-to-completion mode. For each wrapped tool, `name`, `description`, `parameters` and `includesSchemaInInstructions` are equal to the values of the original tool. Use a tool where `includesSchemaInInstructions` is `false`, so that the test can find a forwarder that returns a default. #coverage-gap

## Review Findings (2026-09-27 13:38)

Scope: `review sha HEAD~1..HEAD` (commit 17af87f). The review examined 2 files. It found 0 findings. The `.reviewignore` rule excluded the 4 `.kanban/` files.

No finding to correct.
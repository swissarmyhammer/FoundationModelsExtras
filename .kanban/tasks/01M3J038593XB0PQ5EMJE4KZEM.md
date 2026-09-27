---
assignees:
- claude-code
position_column: review
position_ordinal: '80'
title: 'Add tests for the MountRunner forwarders: name, description, parameters and includesSchemaInInstructions'
---
Sources/FoundationModelsExtras/Hosting/ToolMounting.swift:121-130

Coverage: 93.0% (66/71 lines)

Uncovered lines: 121, 124, 127, 130

`var name: String`, `var description: String`, `var parameters: GenerationSchema`, `var includesSchemaInInstructions: Bool` in `extension MountRunner`

The shared extension of `BackgroundToolRunner` and `RunToCompletionRunner` forwards the metadata of the wrapped tool. The model sees these values, so a wrong forwarder breaks the tool call. No test reads them.

What to test:
- Wrap a tool with `ToolMounting` in the background mode and in the run-to-completion mode. For each wrapped tool, `name`, `description`, `parameters` and `includesSchemaInInstructions` are equal to the values of the original tool. Use a tool where `includesSchemaInInstructions` is `false`, so that the test can find a forwarder that returns a default. #coverage-gap
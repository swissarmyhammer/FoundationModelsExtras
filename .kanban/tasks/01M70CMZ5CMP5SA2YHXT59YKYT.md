---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'GGUF: add FoundationModelsLlamaCpp dependency; settle C++ interop'
---
Add git@github.com:swissarmyhammer/FoundationModelsLlamaCpp.git (branch main). Find whether a target that imports FoundationModelsLlamaCpp needs `.interoperabilityMode(.Cxx)` (its manifest says yes), and whether that spreads to every consumer of FoundationModelsExtras. Report to foundationmodelsrouter-4b. If it spreads, consider a separate product/target for the GGUF loader so MLX-only consumers stay without C++ interop. #gguf
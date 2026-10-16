---
assignees:
- claude-code
position_column: done
position_ordinal: ffa280
title: 'Make the D-1 text rules public: ElicitationValidation.patternMatches and codePointLength'
---
Add a public enum ElicitationValidation with `patternMatches(_ text: String, pattern: String) -> Bool?` (the ECMA-262 search, not anchored; nil when the pattern does not compile) and `codePointLength(_ text: String) -> Int` (the count of Unicode code points). validationFailure(of:) calls the same functions, so there is one implementation. AgentViewKit uses them through an ACPClient bridge. Additive only. Tests use the D-1 examples with a plain import.
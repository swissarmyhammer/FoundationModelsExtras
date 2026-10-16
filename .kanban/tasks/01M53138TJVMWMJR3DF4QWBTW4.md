---
assignees:
- claude-code
position_column: done
position_ordinal: ffa180
title: 'Docs: elicit throws, duplicate id and accept to endElicitation'
---
- `elicit` is declared `async throws`, but an answer never throws. Write in the doc what throws, if anything.
- A duplicate `elicitationId` gets a cancel, not a throw. Write it in the doc of `elicit`.
- An accept given to `endElicitation(_:with:)` stops at a precondition. Write it in the docs that tell of that call. #docs
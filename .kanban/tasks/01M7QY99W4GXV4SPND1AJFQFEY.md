---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Fork cut at a turn: afterTurn and beforeTurn'
---
Add `SessionForkCut.afterTurn(Int)` and `.beforeTurn(Int)`. A turn is one `prompt` entry in the recorded history of the source and all entries up to the next `prompt` entry. The index is 0-based. An index that does not exist, or `.afterTurn(n)` of a turn that still runs, is out of range. The in-memory directory counts the turns that each session starts and checks the cut with that count.

- [x] The two cases, with the turn rule in the DocC.
- [x] The in-memory check.
- [x] Tests: an existing turn, a missing turn, a turn that runs, a second turn, and the Codable round trip. #fork
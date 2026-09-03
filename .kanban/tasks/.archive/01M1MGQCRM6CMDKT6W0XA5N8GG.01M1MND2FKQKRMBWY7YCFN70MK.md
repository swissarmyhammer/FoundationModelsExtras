---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1mncy90yqsjc19014zhnrrp
  text: The user states no preference on the exit codes (2026-09-03). The codes stay as built — 0, 1, 5 — and no doc comment repeats the claim of doctor-plan.md §5 about a usage-exit code. Archived without work.
  timestamp: 2026-09-03T22:14:29.920203+00:00
position_column: todo
position_ordinal: '8680'
title: Correct the wrong usage-exit-code claim in doctor-plan.md §5
---
## What

`doctor-plan.md` §5 states:

> **This differs from the Rust original, on purpose.** That CLI exits 2 for
> errors. The family's Swift CLIs already use 2 for a usage error, so a
> script would read a broken configuration as a typing mistake.

The claim "The family's Swift CLIs already use 2 for a usage error" is
wrong. Every CLI in this family is an ArgumentParser CLI, and
ArgumentParser exits **64** for a usage error, not 2.

Found while task ^y0e0057 wrote `DoctorReport.exitCode`. That task text
told the implementer not to repeat the claim in the doc comment, and the
doc comment does not repeat it. The plan document itself still holds it.

The decision §5 records — `0` for pass, `1` for error, `5` for warning —
stays as it is. Only the reason given for it is wrong.

## Acceptance Criteria

- [ ] `doctor-plan.md` §5 no longer states that a CLI in this family exits
      `2` for a usage error.
- [ ] The paragraph states the true reason: the Rust original exits `2`,
      and the Swift codes `1` and `5` keep the doctor codes clear of the
      exit codes an ArgumentParser CLI already spends (ArgumentParser
      exits `64` for a usage error).
- [ ] The table of the three codes does not change.
- [ ] The doc comment of `DoctorReport.exitCode` still makes no claim
      about the usage-exit code of the family's CLIs.

## Tests

None. This is a document correction, and no code reads §5.
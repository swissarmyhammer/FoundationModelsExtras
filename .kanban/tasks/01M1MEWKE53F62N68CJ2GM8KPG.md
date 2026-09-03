---
assignees:
- claude-code
depends_on:
- 01M1MEGMGC421AP2VD3H7W4N8R
position_column: todo
position_ordinal: '8580'
title: Document Doctorable in README
---
## What

Give the doctor surface its README section, as
`Document IgnoreProcessor in README` did for `IgnoreProcessor`.

Change `README.md`: add a section `## Health checks: Doctorable` before
`## Install`. Keep the style and the length of the
`## Ignoring files: IgnoreProcessor` section that is there now.

The section holds:

- One short paragraph: a CLI has one command that answers one question —
  will this configuration work? — and the answer is a list of named checks,
  each with a status, a message, and, when something is wrong, the command
  that fixes it.
- A short Swift block: a `Doctorable` conformance with one check made with
  `HealthCheck.error(name:message:fix:category:)`, then a `DoctorRunner`
  built over it, then `await runner.run()`, then the exit code.
- The exit-code table of `doctor-plan.md` §5: `0` all checks are `.ok`,
  `1` one `.error` or more, `5` a `.warning` and no `.error`.
- Two sentences on the split of §6: the table goes to stderr, `--json` goes
  to stdout, and the package holds no terminal dependency, so a CLI that
  wants a decorated table renders the `DoctorReport` itself.
- The command `swift run extras-demo doctor --scenario mixed`, as the
  runnable example.

## Acceptance Criteria

- [ ] `README.md` holds the new section, before `## Install`.
- [ ] The section names `Doctorable`, `HealthCheck`, `DoctorRunner`, and
      `DoctorReport`, and it gives the three exit codes.
- [ ] The Swift block compiles against the public surface: the names, the
      argument labels, and the `await` match the code that was written.
- [ ] The `swift run` command in the section runs and gives the exit code
      the section states.

## Tests

- [ ] Run the command that the section gives:
      `swift run extras-demo doctor --scenario mixed`. Expect exit code `1`,
      because the mixed scenario holds an `.error`.
- [ ] Run `swift build` and `swift test`. Expect no failure, so the section
      cannot name a surface that is not there.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
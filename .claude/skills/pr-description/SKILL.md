---
name: pr-description
description: Draft a pull request description from the branch's diff and verification evidence, in this repo's PR format. Stops before pushing or opening the PR.
disable-model-invocation: true
---

# PR description

## 1. Gather

- `git log --oneline main..HEAD` and `git diff main...HEAD --stat`, then read the diff itself
- The evidence table from `verify-change`, if it ran in this session. If it didn't, run it first or write
  "not verified" in Testing. Never fill in numbers you didn't see
- ADRs added or changed under `docs/decisions/`

## 2. Write

Follow [template.md](template.md), the format of PRs #11–#16. Keep sections that apply; drop the rest.

- **What**: a table of models or files with grain or purpose, not a list of edits
- **Design decisions**: the why, in business terms. Link the ADR when there is one
- **Suggested review order**: follows the data flow, smallest and foundational first
- **Tests that add reassurance**: each test with why it could fail; say which tests were dropped as true by
  construction
- **Breaking changes / risks**: contract changes, renamed columns, anything consumers notice
- **Testing**: the build summary (`PASS / WARN / ERROR`, with `--no-partial-parse`), SQLFluff, and which CI
  will run. dbt CI only runs for changes under `transform/`, `.sqlfluff*`, `pyproject.toml`, `uv.lock` or its
  own workflow

End with the attribution line the session's instructions give for PR descriptions.

## 3. Stop

Save the draft to a file in the scratchpad, show the title and where it is, and summarize what pushing and
opening the PR will make visible. **Push and `gh pr create` only after the user says yes.** Never merge.

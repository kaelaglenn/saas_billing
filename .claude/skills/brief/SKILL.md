---
name: brief
description: Give the user a short, ranked status brief of what needs their decision, what was decided without them, what changed, and what's verified. Use before any outward action (push, PR, Snowflake or GitHub changes), when a decision that's costly to reverse comes up, and when a unit of work is finished (a model built, a check done). Also /brief on request.
---

# Brief

A snapshot of where the work stands, ranked by what needs the user's attention. Build it fresh each time from
the diff (`git diff main...HEAD` plus uncommitted changes), this conversation, and the verification done so far.
Write nothing to disk. Lasting records belong in ADRs and the PR description.

## Rank by consequence

- **One-way door**: costly to undo. A grain, a contract or published column, a metric definition, a naming
  convention, an exception to a rule or check, anything in Snowflake or GitHub settings, anything outward.
- **Two-way door**: cheap to undo. Internal CTEs, intermediate refactors, test additions.
- **Blast radius**: what's downstream (dbt MCP `get_lineage_dev` for models; who sees it for outward actions).

One-way doors always need the user's confirmation; they never go under "Decided on my own". If one was made
without asking, it moves to "Needs your decision" until confirmed. Two-way doors with a small blast radius get
one line at most. Style and formatting never appear.

## Sections

Omit empty sections. Keep the whole brief to one screen.

**Needs your decision**: each item with the options, a recommendation, and whether it's a one-way door. Work
that depends on it waits. For a one-way door that meets the `adr` skill's criteria, ask both questions together:
"Confirm X? Record it as an ADR?", so the user isn't asked twice.

**Decided on my own**: two-way-door defaults and assumptions chosen without asking, with the one-line reason
and what would change the choice.

**What changed**: in data terms, not file lists. New or changed models with their grain; contract changes;
metric definitions; row counts before → after where known.

**Evidence**: what's verified (with the numbers) and what isn't yet. Never imply something was checked when it
wasn't.

**Watch**: risks, assumptions to revisit, anything that would change the plan.

## Then

If anything is in "Needs your decision", stop and wait for the answer. Otherwise continue with the task.

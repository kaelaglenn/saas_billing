---
name: verify-change
description: Verify a dbt change with evidence independent of the code under test, and produce an evidence table. Use before reporting results, declaring a model done, or writing a PR description; also before changing a mart, to list what depends on it.
---

# Verify a change

Passing tests aren't the goal; evidence that the output is right is. Work through the steps in order and keep
the numbers for the evidence table.

## 0. Impact (only when a mart or contracted column changes)

Before editing, use the dbt MCP tools (`get_lineage_dev`, `get_node_details_dev`) to list the model's downstream
models, its contract, and its tests. A renamed, removed or retyped column under an enforced contract is a
breaking change: say so up front, and it goes in the PR's risks.

## 1. Name the independent evidence

Before writing any query, say what you'll compare against and why it doesn't depend on the code under test.
[evidence-sources.md](evidence-sources.md) lists what this project has. If nothing independent exists, say so;
don't substitute a check that's true by construction.

## 2. Reconcile

Run the comparison with `dbt show --inline … --target dev`. Compare in both directions where it matters (rows we
derived that the source disagrees with, and source rows we failed to derive). Report counts, not just "matches".

## 3. Confirm the tests compared rows

For each new or changed singular test, count the rows its join or filter actually compares (run its query
without the failure condition). Zero compared rows means it passes on nothing. Flag any test that can't fail
(e.g. a total compared with a sum of itself).

## 4. Mutation check (new singular tests and reconciliations only)

Skip for other changes. Otherwise, prove the check can fail:

1. Make one small, deliberate break in the model it guards (e.g. remove the dedup, drop a filter)
2. Build that model and run the check: `uv run --no-sync dbt build --select <model> <test> --target dev`
3. The check must fail. Record how many rows it flagged
4. Restore with `git restore <file>` and show `git diff -- <file>` is empty. Never commit a mutation
5. Rebuild the model so the dev schema is clean again

## 5. Full rebuild

From `transform/` and the repo root respectively:

```bash
uv run --no-sync dbt build --no-partial-parse --target dev
uv run sqlfluff lint transform/models
```

Report `PASS / WARN / ERROR` counts and explain every warning (today: the two raw-source duplicate tests).

## 6. Evidence table

| Check | Why it's independent | Result |
|---|---|---|
| … | … | numbers |

Then the build summary line. This table feeds the `pr-description` skill.

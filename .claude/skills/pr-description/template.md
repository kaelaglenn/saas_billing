## What

<One sentence on the change.>

| Model / file | Type | Grain / purpose |
|---|---|---|
| | | |

## Design decisions

- **<Decision>.** <Why, in business terms.> See [ADR NNNN](docs/decisions/NNNN-title.md).

## Suggested review order

1. <Foundational piece first>
2. <…>

## Tests that add reassurance

| Test | Why it can fail | Result |
|---|---|---|
| | | |

Dropped as true by construction: <…, or "none">.

## Breaking changes and risks

<Contract changes, renamed columns, assumptions to revisit. Or "None.">

## Testing

Full local `dbt build --no-partial-parse` (dev target): **PASS=… WARN=… ERROR=…** (<explain each warning>).
`dbt_project_evaluator` clean; SQLFluff clean. <Which CI runs on this PR.>

# Architecture decision records

One file per decision: the context, what we chose, what we rejected, and the consequences. Accepted records
aren't rewritten; a new record supersedes an old one. Write new ones with the `/adr` skill.

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-renewals-as-checkpoints-in-event-replay.md) | Renewals as checkpoints when replaying subscription events | Accepted | 2026-10-22 |
| [0002](0002-report-in-eastern-time-store-in-utc.md) | Report in Eastern Time; store and compute in UTC | Accepted | 2026-10-23 |
| [0003](0003-trial-conversion-on-matured-trials.md) | Measure trial conversion on matured trials only | Accepted | 2026-10-25 |
| [0004](0004-conformed-calendar-evaluator-exception.md) | Let facts and their rollups join the reporting calendar directly | Accepted | 2026-10-23 |
| [0005](0005-month-end-ar-evaluator-exception.md) | Let month-end AR read payments directly and through the invoice summary | Accepted | 2026-11-17 |
| [0006](0006-production-deploy-in-place-with-repo-secret.md) | Deploy production in place, with the key as a repository secret until the repo is public | Accepted | 2026-11-18 |
| [0007](0007-slim-ci-against-prod-manifest.md) | Slim CI against the production manifest, with full-build fallbacks | Accepted | 2026-11-19 |
| [0008](0008-mrr-bridge-counts-month-end-states.md) | The MRR bridge counts subscriptions at month-ends; a same-month convert-and-lapse is neither new nor churned | Accepted | 2026-11-19 |
| [0009](0009-semantic-layer-on-finest-grain-marts.md) | Build the Semantic Layer on the finest-grain marts, with balances semi-additive and time in Eastern Time | Accepted | 2026-11-20 |

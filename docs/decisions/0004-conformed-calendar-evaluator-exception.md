# 0004. Let facts and their rollups join the reporting calendar directly

- **Status:** Accepted
- **Date:** 2026-10-23
- **Related:** [PR #14](https://github.com/kaelaglenn/saas_billing/pull/14),
  `seeds/dbt_project_evaluator_exceptions.csv`, `dbt_project.yml` (`flags.warn_error_options`)

## Context

`dbt_project_evaluator` flags `fct_rejoining_of_upstream_concepts` when a model reads a parent both directly and
through another model. `fct_mrr_bridge` reads `dim_reporting_months` directly and through
`fct_subscription_months`. The calendar is a conformed dimension (shared by every fact that reports by month),
and both models need it for month labels and completeness flags.

Earlier, in PR #13, the same rule flagged the calendar reading subscription history just to find the first data
date. That one was a real problem: it was fixed by reading the start date from `int_data_watermark` instead.

## Decision

We record a documented exception for `parent = dim_reporting_months` in this project's exceptions seed, following
the package's documented setup. That setup makes dbt report `PackageNodeDependsOnRootProjectNode` on every full
parse, so we silence only that event in `warn_error_options`.

## Alternatives considered

- **Route the bridge through the fact only.** Rejected: a fact and its rollup joining a conformed dimension is
  the intended star-schema pattern.
- **`require_ref_searches_node_package_before_root`.** Tried first; it doesn't silence the event, and setting it
  to `true` would bypass the exceptions seed.

## Consequences

- Other rejoins are still flagged; the exception covers only this parent.
- Revisit the silenced event when upgrading dbt or the evaluator: dbt may later search the package first, which
  would bypass the exceptions seed.

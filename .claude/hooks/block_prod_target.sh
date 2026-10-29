#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash): refuse dbt commands aimed at the prod or ci target.
# Those targets belong to GitHub Actions; local work uses --target dev. This backs up the deny rules in
# settings.json, which only match fixed command shapes. Neither is the real boundary: locally there is no key for
# DBT_PROD_SVC, and the DEVELOPER role can't write to ANALYTICS.
set -uo pipefail

command=$(jq -r '.tool_input.command // empty')

calls_dbt='(^|[^[:alnum:]_-])dbt([[:space:]]|$)'
names_target='(--target[=[:space:]]+|(^|[[:space:]])-t[[:space:]]+|DBT_TARGET=)["'\'']?(prod|ci)(["'\'']|[^[:alnum:]_]|$)'

if grep -Eq "$calls_dbt" <<<"$command" && grep -Eq -- "$names_target" <<<"$command"; then
    echo "Blocked: dbt with the prod or ci target. Use --target dev; prod and ci run only in GitHub Actions." >&2
    exit 2
fi

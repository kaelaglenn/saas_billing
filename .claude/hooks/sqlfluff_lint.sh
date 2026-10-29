#!/usr/bin/env bash
# Claude Code PostToolUse hook (Edit|Write): lint the file Claude just edited with SQLFluff, if it's dbt SQL.
# Same files as the sqlfluff-lint pre-commit hook. The edit has already happened; exiting 2 shows the violations
# to Claude so it fixes them. Lints only: fixes stay explicit (uv run sqlfluff fix <file>).
set -uo pipefail

file=$(jq -r '.tool_input.file_path // empty')
[[ -n "$file" ]] || exit 0

cd "$CLAUDE_PROJECT_DIR" || exit 0
rel=${file#"$CLAUDE_PROJECT_DIR"/}
[[ "$rel" =~ ^transform/(models|tests|analyses|snapshots)/.*\.sql$ && -f "$rel" ]] || exit 0

# The dbt templater compiles through Snowflake, so it needs the variables direnv normally loads from .env.
if [[ -z "${SNOWFLAKE_ACCOUNT:-}" && -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

if ! output=$(uv run --no-sync sqlfluff lint "$rel" 2>&1); then
    echo "SQLFluff found problems in $rel. Fix them before moving on:" >&2
    echo "$output" >&2
    exit 2
fi

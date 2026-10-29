---
name: adr
description: Write an architecture decision record (ADR) in docs/decisions/ from the current conversation.
disable-model-invocation: true
argument-hint: "[decision title]"
---

# Architecture decision record

An ADR records one decision: the situation, what we chose, what we rejected and why, and what follows from it.
It's written once and not rewritten; a later decision supersedes it with a new ADR.

## 1. Number and name

List `docs/decisions/`. The new file is the next number, zero-padded to four digits, with a kebab-case title:
`docs/decisions/NNNN-<title>.md`, from `$ARGUMENTS`.

## 2. Draft

Use [template.md](template.md). Take the content from this conversation and the PRs or code it refers to.

- **Context**: the facts that forced a choice, with numbers where we have them
- **Decision**: one or two sentences, active voice ("We model …")
- **Alternatives**: each with the concrete reason it lost
- **Consequences**: what gets easier, what gets harder, what to revisit and when

If the reasoning for any part isn't in the conversation or the PRs, **ask; don't invent it**. A thin ADR with
a question in it is better than a plausible one that's wrong.

## 3. Index and supersede

Add a line to the table in `docs/decisions/README.md`. If this decision replaces an earlier one, set the old
ADR's status to `Superseded by NNNN` (the only edit an accepted ADR gets) and link both ways.

New ADRs start as `Proposed`; they become `Accepted` when the PR that adds them merges.

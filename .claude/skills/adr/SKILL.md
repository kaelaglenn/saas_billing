---
name: adr
description: Offer to record an architecture decision record (ADR) in docs/decisions/, then write it if the user agrees. Use when a design or modeling decision has just been made that chose between real alternatives and would be costly to reverse or puzzling later, e.g. a grain or modeling approach, a metric definition, a convention, an exception to a rule or check, or an assumption to revisit.
argument-hint: "[decision title]"
---

# Architecture decision record

An ADR records one decision: the situation, what we chose, what we rejected and why, and what follows from it.
It's written once and not rewritten; a later decision supersedes it with a new ADR.

## 0. Offer first (when not started with `/adr`)

When this skill starts on its own, write nothing yet. Name the decision in one line, say why it seems worth
recording, and ask the user whether to document it. Worth recording:

- It chose between real alternatives, and the reason isn't obvious from the code
- It's costly to reverse: a grain, a contract, a metric definition, a naming convention
- It makes an exception to a rule, test, or check
- It rests on an assumption that should be revisited (a threshold, a buffer, a cutoff)

Not worth recording: following an existing convention or ADR, routine fixes, choices with no real alternative.
Offer at a natural pause (after the decision is settled, not mid-discussion), and offer each decision once. If
the user says no or later, continue with the task. If yes, go on to step 1. If a `brief` already asked "Record
it as an ADR?" for this decision, that was the offer: don't ask again.

When the user typed `/adr`, skip this step.

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

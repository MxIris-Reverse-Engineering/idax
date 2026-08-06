# Fork-local agent records

Everything in this directory belongs to this fork. The files one level up —
`.agents/roadmap.md`, `progress_ledger.md`, and the rest — track
[`19h/idax`](https://github.com/19h/idax) byte for byte and **must not be
edited here**.

## Why

Those seven ledgers are append-only and both sides append to them, so every
upstream sync conflicted on all seven. Worse than the conflict was what the
union resolution did to them: upstream numbers its work `Phase N` / `PN.M`,
and so did this fork, against the same counter. By August 2026 upstream's
`P23.1` was an ida-trida port while this fork's `P23.1` was the Swift dyld
cache tool, and both sat in one file under the same number.

Moving fork entries out drops those seven files from the conflict surface
entirely, and removes any chance of two unrelated tasks sharing a number.

## Layout

Each file mirrors the upstream ledger it was split from:

| File | Mirrors |
|---|---|
| `roadmap.md` | `.agents/roadmap.md` |
| `progress_ledger.md` | `.agents/progress_ledger.md` |
| `decision_log.md` | `.agents/decision_log.md` |
| `findings.md` | `.agents/findings.md` |
| `knowledge_base.md` | `.agents/knowledge_base.md` |
| `api_catalog.md` | `.agents/api_catalog.md` |
| `active_work.md` | `.agents/active_work.md` |

## Numbering

Entries moved here in August 2026 kept whatever number they had, so some of
them collide with upstream numbers that mean something else entirely. That is
tolerable now only because the files are separate — read a number here as
scoped to this directory and nothing else.

**New entries use an `F` prefix**: `F1`, `F2.3`, `FS1.4`. Upstream will never
issue those, so a number stays unambiguous even if these records are ever
merged back or offered upstream.

## Working rule

Upstream's `agents.md` states a mandatory update protocol — roadmap status,
progress ledger, findings plus knowledge base, decision log, active work. That
protocol still applies to this fork; only the destination changes. Record fork
work here, and touch the upstream ledgers only when a change is genuinely
upstream's (fixing its typo, or preparing a pull request that has to follow
its numbering).

See `docs/UpstreamSyncPlaybook.md` for the sync procedure that relies on this
separation.

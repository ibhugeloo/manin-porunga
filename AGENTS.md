# AGENTS.md — Manin Porunga (Public Curated Mirror)

Entry point for **any** coding agent (Claude Code, Antigravity CLI, Codex, Grok, Cursor, Amp, …)
working in this repository, conforming to the [agents.md](https://agents.md) standard.

## What this is

**Manin Porunga** is the curated public showcase of **Porunga**, the personal AI agent
control room created by Idriss Bhugeloo (Manin Studio).

It demonstrates a reliable, production-grade autonomous agent architecture built on top of LLMs:
- **Durable Markdown memory** with strict **HOT / WARM / COLD** tiers.
- **Multi-agent role & model diversity** (Jarvis on Claude Code/Antigravity, Leo on Hermes, Alfred on homelab).
- **Offline LLM-evaluation harness** (`tests/doctrine/`) with 14 graded behavioural scenarios gating CI.
- **Notable Delivery Contract** (`bin/jarvis-ship-check.py`): mechanical gating requiring structured hypotheses, observable vertical slices, and independent fresh-context review.
- **Mechanical guardrails**: `PreToolUse` bash hook blocking batch mutating git commands and rm -rf, memory file caps, and dumb-zone context watchers.
- **Hybrid RAG & the Post-RAG pivot**: local vector retrieval (`sqlite-vec` + e5 + FTS5 + RRF) showcase, and the architectural lesson of why production evolved to deterministic structured indexes (`_vault-index.md` + ripgrep).

## Source of truth & hierarchy

| Tier / Location | Role | Authority |
|---|---|---|
| **Git repo (here)** | Curated public mirror, sanitized doctrine, eval harness, tools | Versioned & tested in CI |
| **Private canon** | Real private Git repo + Obsidian vault (atelier) | Absolute source of truth for private system |
| **Notion** | Disposable mobile mirror | Never a source of truth |

## Hard rules — read before touching anything

1. **Deterministic validation**: every change to doctrine or scenarios must keep `python3 tests/doctrine/runner.py` at **100% pass rate** (14/14 pass, 8/8 critical).
2. **Never commit secrets**: no API keys, private tokens, private client names, or personal finance details. This repository is public.
3. **Commit by explicit pathspec only**: `git commit <file1> <file2> -m "..."`. Never `git add -A`, `-a/-am`, or `git commit .`.
4. **Sequential state operations**: one mutating git/deploy command at a time, followed by isolated verification. Never batch mutating commands.
5. **Shell scripts use `set -uo pipefail` without `-e`**: deliberate design to avoid SIGPIPE breakage on early-exit pipes (`grep -q`, `head`).
6. **No fluff / No theater**: documentation and code must be dense, clear, and actionable.

## Key directories

- `bin/`: executable guardrails (`jarvis-bash-guard.sh`, `jarvis-memory-guard.sh`), delivery gate tools (`jarvis-ship-check.py`, `jarvis-ship-template.py`), token observability (`jarvis-token-report`), multi-agent bridges (`jarvis-antigravity-bridge`, `jarvis-codex-bridge`), and retrieval engine (`vault-search-v2.py`, `jarvis-vault-index.py`).
- `claude-config/`: path-scoped rules (`rules/`) demonstrating contextual loading based on active workspace path.
- `memory/`: sanitized templates of the HOT doctrine (`jarvis_soul.example.md`, `profil.example.md`, `decisions.example.md`, `agents.example.md`).
- `tests/doctrine/`: the 14-scenario behavioural eval harness (`runner.py`, `scenarios/`, `fixtures/`).
- `showcase/semantic-vault-search/`: runnable standalone hybrid RAG demo on a public sample corpus.
- `docs/`: recruiter-facing signals and competence mapping (`ai-engineer-signals.md`).
- `BEST-PRACTICES.md`: complete operating doctrine distilled from real production incidents.

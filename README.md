<p align="center">
  <img src="docs/assets/logo-manin.png" width="140" alt="Manin Control Room" />
</p>

<h1 align="center">Manin Control Room</h1>

<p align="center">
  <strong>A personal AI butler engine — one brain, many runtimes, zero hidden LLM calls.</strong><br />
  The memory is a Markdown vault, the canon is git, the model runs only when I say so.
</p>

<p align="center">
  <sub>Sanitized template — the structure of an assistant I drive every day, personal content
  stripped and replaced by fill-in-the-blank files. Fork it, make it yours.</sub>
</p>

<p align="center">
  <sub>Built and run daily — also a worked example of context engineering, retrieval,
  multi-agent orchestration and LLM evals.
  See <a href="#what-this-demonstrates-engineering">what this demonstrates</a>.</sub>
</p>

---

## Why

The interesting part of "personal AI" isn't the prompt — it's **where the memory
lives and who's allowed to touch it**. Most setups bury that in a vendor database;
this one keeps it in plain Markdown you already own.

The brain is an [Obsidian](https://obsidian.md) vault: the same files I read as a
human *are* the assistant's memory — no export step, no drift. The vault is
mirrored nightly to a private git repo, which is **the canon**: when vault, laptop
and Notion disagree, git wins. Notion is a throwaway mirror I skim on mobile —
handy, never a source. The brain doesn't move; the runtimes are swappable.

```mermaid
flowchart TD
    Me(["Me — edit as a human"]) -->|write| V["Obsidian vault (.md)<br/>atelier + live memory"]
    V -->|"@import · HOT"| J["JARVIS<br/>Claude Code · Mac · builder"]
    V -->|"memory-sync · nightly"| G[("git = THE CANON<br/>dated · versioned · append-only")]
    J -->|"session recaps"| N["Notion<br/>mirror · optional"]
    J <-->|"debate · I decide"| L["LEO<br/>Hermes · phone · contrarian"]
    G -->|"read-only clone"| L
    G -.->|"read-only"| A["ALFRED<br/>homelab · sysadmin"]
    classDef canon fill:#1f2937,stroke:#f59e0b,color:#fff;
    class G canon;
```

## What this demonstrates (engineering)

> What each part of this system *is*, in the vocabulary of building LLM products —
> the same skills a production AI team hires for.

| Component in this repo | AI-engineering competency |
|------------------------|---------------------------|
| Tiered **HOT/WARM/COLD** memory + **path-scoped rules** | **Context engineering** — deciding what enters the model's window, when, and why; managing token budget deliberately instead of dumping everything in |
| Local embeddings search — `sqlite-vec` + `sentence-transformers`, fully offline | **Retrieval / RAG** — semantic search over a private corpus, no vendor lock-in, no data leaving the machine |
| Jarvis / Leo / Alfred — three roles on **deliberately different models** | **Multi-agent orchestration** — role *and* model diversity so the agents don't share blind spots; one debates, I decide |
| Doctrine scenarios in `tests/` | **LLM evaluation** — the assistant's behavior is *tested against scenarios*, not assumed correct |
| "No background cron ever calls the LLM", opt-in routines, every model call logged | **LLMOps & cost control** — every inference is intentional, auditable, and off by default |
| `PreToolUse` hooks, sequential state ops, self-critique gate before "ready" | **AI safety & reliability** — mechanical guardrails wrapped around an autonomous agent that can write code and touch prod |
| Incident-forged, **dated** rules with the scar attached | **Production discipline** — real failures turned into enforced checks, not blog best-practices |

## The staff

One shared doctrine, three deliberately different jobs **and models** — so they
don't share blind spots. Jarvis and Leo debate; **I decide**.

| Agent | Where | Role | Runs on |
|-------|-------|------|---------|
| **Jarvis** | terminal (macOS) | **Builder** — writes code, runs routines, edits the vault. Commits locally; never pushes/deploys without a yes. | Claude Code |
| **Leo** | phone (Telegram) | **Contrarian** — reads the canon read-only, answers with verdicts (*validated / with-reservations / not-validated*), not flattery. | self-hosted [Hermes](https://nousresearch.com) |
| **Alfred** | homelab (Proxmox) | **Sysadmin** — ops only, narrow blast radius. | scoped model |

A separate cockpit — [`thousand-sunny`](https://github.com/ibhugeloo/thousand-sunny) —
drives them in parallel, each in its own colored terminal session.

## Features

- **Tiered memory** — HOT loads every session, WARM on context match, COLD only
  on explicit request. Admission to HOT is strict: relevant in ≥ 50 % of
  sessions or a high-blast-radius guardrail. *"The garage must not become the
  house."*
- **Path-scoped rules** — a client's doctrine (infra target, deploy gotchas,
  RGPD, "never DELETE in prod via API") loads *because I opened the client's
  code*, not because I said a magic word. Keyword-matching is fragile;
  file-path matching is mechanical.
- **Manual dispatcher** — everything the model does, it does because I typed a
  command. **No background cron ever calls the LLM**; every model-calling
  launchd template ships disabled.
- **Gated delivery** — client work runs through `/jarvis-ship`:
  Research → Plan → Execute → Review → Ship, one confirmation per gate.
  Nothing ships or deploys without a yes.
- **Self-critique before "ready"** — tests green ≠ prod-ready. Client code gets
  a spontaneous risk analysis (critical / watch / minor) and **E2E tests of the
  real flows** before I'm told it's done.
- **Incident-forged guardrails** — dated rules with the scar attached, enforced
  mechanically where possible (a `PreToolUse` hook blocks batched mutating
  git/`gh` commands, a context watch warns before "dumb zone" sessions).
- **Doctrine promotion loop** — recurring patterns are observed in sessions,
  scored over cycles, auto-written to an audited probation folder, and purged
  if unused. Anything touching the **persona** or a **dated decision** requires
  my explicit yes — silence is never consent. The decision log is append-only.
- **Semantic vault search** — local embeddings (`sqlite-vec` +
  `sentence-transformers`), fully offline.
- **Tested doctrine** — the persona's rules live in `tests/` as scenarios; the
  rules are *tested*, not just written.

## The memory model

| Tier | When loaded | What goes there |
|------|-------------|-----------------|
| **HOT** | every session (`@import` in `CLAUDE.md`) | persona, profile, decisions, core workflows |
| **WARM** | on context match (cwd / keywords) | one file per project or domain |
| **COLD** | only on explicit request | archives, history, raw logs |
| **path-scoped** | mechanically, when I open matching code | that project's client/infra rules |

## Evaluation

This repo ships a real **LLM-evaluation harness** for the assistant's behavioural
**doctrine** — its *policy engine*: the safety and behaviour rules the agent must
obey (guardrails-as-tests, not a prompt collection). Each rule (persona, safety,
memory discipline) is a graded scenario across 5 categories; the harness computes
weighted scores per category, detects regressions vs the previous run, and exits
non-zero on failure so it gates CI.

It is a **curated regression suite** — 11 high-blast-radius rules chosen for impact,
not a statistical coverage benchmark. The goal is to catch *behavioural* regressions
on the rules that matter, fast, in CI — and to grow as new incidents surface.

```bash
python3 tests/doctrine/runner.py                # offline, deterministic, CI-safe
python3 tests/doctrine/runner.py --mode live    # grade the real model's responses
python3 tests/doctrine/runner.py --mode judge   # live + optional LLM-judge
```

**Offline deterministic baseline** — graded against recorded reference responses;
a reproducible CI number and regression guard, *not* a live-model capability score:

| Metric | Value |
|--------|-------|
| Scenarios | 11 across 5 categories |
| Baseline pass rate | 100% (11/11) |
| Critical scenarios | 5/5 |
| Regression vs previous run | none |

**Live run** (`--mode live`, real model) — the harness grading the actual model, no
fixtures. Latest run: **11/11 on this suite** — earned, not assumed (read on). To be
explicit about what that is *not*: it's 100% on a **targeted regression suite**, not a
real-world reliability metric, and live runs flap with model non-determinism.

The first live run scored **79%** and caught a real safety gap. Asked to delete rows
on a client's prod database, the assistant refused API execution — but still wrote a
ready-to-run `DELETE FROM … WHERE …` to paste. The harness flagged it. I root-caused
it to an ambiguous doctrine rule, tightened the rule (never *emit* ready-to-run
destructive SQL, not just never execute it), and the assistant now declines and hands
back a non-destructive `SELECT` instead. Re-run: green.

**Detect → fix the root cause → re-verify.** Live scores still carry run-to-run model
non-determinism — exactly why the *deterministic* baseline backs the CI gate.
`--mode judge` adds an optional LLM-judge that is *additive only*. Full design:
[`tests/doctrine/README.md`](tests/doctrine/README.md).

## Showcase: semantic vault search (local RAG)

A self-contained, **offline** semantic search engine over a private Markdown
corpus — local embeddings (`multilingual-e5-small`) + a `sqlite-vec` vector
store, ranking by meaning instead of keywords. The retrieval layer of a RAG
system, decoupled from any LLM.

→ **[`showcase/semantic-vault-search/`](showcase/semantic-vault-search/)** —
write-up, architecture diagram, and a `demo.py` you can run on an included sample
corpus (no private data needed). It imports the production engine
([`bin/vault-search-v2.py`](bin/vault-search-v2.py)) rather than forking it.

## Guardrails, forged from incidents

Every rule has a scar behind it. You can fork the rules — you can't fork the
scar tissue, so the *why* sits next to each.

| Rule | The incident behind it |
|------|------------------------|
| **Sequential state ops** — one mutating git/deploy at a time, verified | a session hallucinated a merge on phantom SHAs; a `PreToolUse` hook now blocks batched mutating git/`gh` |
| **Tests green ≠ prod-ready** — mandatory self-critique + real E2E on client code | shipped a feature on unit tests alone |
| **Pre-external-action gate** — re-read reference + decisions before any push/deploy/DNS | phrased an already-documented deploy as an open question |
| **Memory-size cap** — hard ceiling on always-loaded doctrine | it bloated to "knows too much, arbitrates badly" |
| **Context-discipline watch** — a hook warns at session-size thresholds | risky prod work in a marathon session; now it waits for a fresh context |

Full operating doctrine: [**BEST-PRACTICES.md**](./BEST-PRACTICES.md) — every
rule, actionable, with its incident.

## A typical day

- **Morning** — `jarvis jour` → one brief: calendar, important mail, repo git
  state, vault to-dos, client activity. Empty section → `RAS`, never filler.
- **Building** — 2–3 Claude Code sessions in parallel. A `SessionStart` hook
  shows which others are live, so no session clobbers another's WIP.
- **Client work** — gated pipeline `/jarvis-ship`; path-scoped rules load that
  project's doctrine the moment its code is opened.
- **"Ready"?** — self-critique first, E2E on the real flows, then the report.
- **On the move** — ask Leo from the phone: different model, read-only canon,
  there to poke holes, not to agree.
- **Night** — self-eval samples sessions and lessons, proposes doctrine
  promotions. Persona changes wait for my explicit yes.

## Command reference

**Dispatcher** — `jarvis <verb>`, strictly manual:

| Command | What it does |
|---------|-------------|
| `jarvis jour` | Morning brief — calendar, mail, repo git state, vault to-dos, client activity |
| `jarvis hebdo` · `mensuel` | Weekly review · monthly retrospective |
| `jarvis veille` | Daily watch pass |
| `jarvis evaluation` | Self-review — detect patterns, propose doctrine promotions |
| `jarvis watchtower` | Prod health of client projects (Sentry / Vercel / Supabase) |
| `jarvis finance` | Earnings analysis of the tracked portfolio |
| `jarvis tech-watch` | External agentic / Claude Code watch |
| `jarvis notion-sync` | Pull Notion → vault (≈ monthly) |
| `jarvis memory-sync` | Mirror the memory vault to private git |
| `jarvis sessions-purge` | Archive to Notion + purge session recaps > 90 days |

**Slash commands** — inside a Claude Code session:

| Command | What it does |
|---------|-------------|
| `/jarvis-ship` | Gated delivery pipeline — Research → Plan → Execute → Review → Ship |
| `/jarvis-jour` · `/jarvis-watchtower` · `/jarvis-finance` · `/jarvis-tech-watch` · `/jarvis-audit` | Run the matching routine in-session |
| `/observe` | Capture a user-model observation into the doctrine |
| `/save` | Snapshot the current session into the vault |

## What's in the box

```
memory/        ← the doctrine (persona, profile, decisions, dreams, workflows) — HOT files
share/         ← prompts for each routine (brief, weekly, eval, watchtower, finance…) + missions
bin/           ← the engine: dispatcher, semantic vault search, routines, hooks, guards, UI server
claude-config/ ← Claude Code hooks + slash commands + path-scoped rules + the @import list
docs/          ← how each subsystem works (one doc per subsystem)
config/        ← per-project config (watchtower, finance…) — *.example.yaml here
LaunchAgents/  ← macOS launchd templates for the scheduled routines (opt-in)
tests/         ← doctrine scenarios — the persona's rules are tested, not just written
```

## Install

**Requirements**

- macOS (launchd, `~/.local/bin`, shell hooks — Linux works with minor tweaks,
  Windows needs WSL; both undocumented for now)
- [Obsidian](https://obsidian.md) and [Claude Code](https://claude.com/claude-code)
  (paid Anthropic account)
- `git`, `zsh`/`bash`, Python 3

**Developer path**

```bash
git clone https://github.com/ibhugeloo/manin-control-room.git
cd manin-control-room
for f in memory/*.example.md;   do cp "$f" "${f%.example.md}.md"; done
for f in config/*.example.yaml; do cp "$f" "${f%.example.yaml}.yaml"; done
# Fill in memory/*.md + config/*.yaml, point @imports at your vault path:
./bootstrap.sh
```

`bootstrap.sh` symlinks `bin/` into `~/.local/bin`, wires the Claude Code hooks,
and (optionally) installs the launchd routines. **Idempotent** — re-run to update.

<details><summary><b>The gentle path</b> — no coding required, macOS, ~45 min</summary>

**What you'll have at the end:** you type `claude` in a folder, and your
assistant already knows who you are, your tone rules, and remembers things
between conversations.

> **Real talk first.** This runs on a **Mac**, needs a **paid Anthropic
> account** (Claude Code), and you'll **copy-paste a few Terminal commands**.
> Never opened Terminal? Fine — follow exactly, budget ~45 min. You do **not**
> need Leo, Alfred, a homelab, or any routine to start.

**1. Install the two apps**
- [Obsidian](https://obsidian.md) — a free note-taking app. Becomes your assistant's memory (and yours).
- [Claude Code](https://claude.com/claude-code) — Anthropic's terminal assistant. Follow their installer and sign in (the paid part).

**2. Download this template (no git needed)**
- Green **`Code`** button → **Download ZIP**. Unzip it, move it to **Documents**, rename to e.g. `my-jarvis`.

**3. Open Terminal in that folder**
- In Finder, right-click the folder → **Services** → **New Terminal at Folder**.

**4. Turn the blank templates into your files** — paste, Enter:
```bash
for f in memory/*.example.md;   do cp "$f" "${f%.example.md}.md"; done
for f in config/*.example.yaml; do cp "$f" "${f%.example.yaml}.yaml"; done
```

**5. Make it *yours* (the important part)**
- Open Obsidian → **Open folder as vault** → pick `my-jarvis`.
- Edit two files in plain words:
  - `memory/jarvis_soul.md` — how it talks to you, and how much it does on its own vs. asks first.
  - `memory/profil.md` — who you are: work, goals, preferences, what to never forget.
- The more honest and specific, the better it gets. No software can do this part for you.

**6. Switch it on** — paste, Enter:
```bash
./bootstrap.sh
claude
```
Say hi. Ask *"what do you know about me?"* — it should answer from your profile.

**7. Grow into it, slowly**
Use it by hand for a week or two. When you wish it did something on a schedule,
*then* turn on that one routine. Leo, Alfred and the homelab are **advanced
add-ons** — open [`docs/`](./docs) when you actually want them.
</details>

## Stack

Nothing exotic — the point is the *architecture*, not the dependencies.

**Brain & memory**
- **Obsidian vault** of Markdown, `@import`-ed into context — mirrored nightly
  to **git** (the canon)
- **sqlite-vec + sentence-transformers** — local semantic search, fully offline

**Engine**
- ~30 **zsh/bash** scripts (dispatcher, routines, hooks, guards, UI server) +
  **Python 3** for the heavier bits
- **Claude Code hooks + slash commands + path-scoped rules**, wired by
  `bootstrap.sh`
- macOS **launchd** templates — opt-in, every model-calling cron off by default

**Runtimes**
- **Jarvis** — [Claude Code](https://claude.com/claude-code) on macOS, tiered
  memory per session
- **Leo** — self-hosted [Hermes](https://nousresearch.com) over Telegram
- **Alfred** — homelab sysadmin, scoped model

macOS-first by design. No build step, no framework lock-in.

## Roadmap

- **Cross-platform** — engine assumes macOS; Linux needs tweaks, Windows needs WSL (undocumented).
- **A real restore drill** — *prove* "git is the safety net": fresh clone → `bootstrap.sh` dry-run → verify HOT/WARM/rules rehydrate.
- **Native vault dashboards** — query projects/decisions live (Obsidian Bases) instead of a static index (POC).
- **Opportunistic web extraction** — content pre-filter + fetch fallback, source-tagged for provenance.
- **Command ↔ headless-prompt sync** — a slash command and its cron prompt can drift silently; they need a shared source.

## Philosophy

- **Confirm before irreversible or outward-facing actions** — reads, drafts, local commits are free; sends, pushes, deletes need a yes.
- **State operations are sequential** — one mutating git/deploy command at a time, verified.
- **No bluffing** — can't find it → says so. Never invents.
- **Self-validate before reporting** — "tests pass" is not "ready for production".
- **Consolidate, don't accumulate** — a fact lives in exactly one place; everything else links to it.

The full, actionable list: [**BEST-PRACTICES.md**](./BEST-PRACTICES.md) — each
rule with the incident behind it.

## Influences & differences

Three things people tend to conflate — they sit at **different layers** and
*compose*, they don't compete:

| | What it is | My relationship to it |
|---|---|---|
| **OpenClaw** | A personal-AI **memory architecture** — tiered memory + a nightly "dreaming" consolidation pass. | **Borrowed** the concept. On top I added strict HOT-admission rules + a hard size cap, mechanical **path-scoped** rules, and the git-as-canon hierarchy. |
| **Hermes** (Nous Research) | An open-weights **model** family, strong at system-prompt adherence. | A **deployment choice**: my contrarian agent (Leo) runs on it — deliberately a *different* model from Claude so it doesn't share Claude's blind spots. Not something I built. |
| **This eval harness** | A **behavioural eval** for *this* agent's doctrine (safety, memory discipline, tone). | **Mine.** Not a generic LLM-eval framework (promptfoo, DeepEval, Ragas exist and are mature) — it tests my agent's *rules* and gates CI. |

**What I think is actually mine:**
- **Obsidian-as-shared-memory** — the LLM's memory and my human second brain are the *same files*, not an export.
- **git-as-canon with a strict hierarchy** — Obsidian = atelier, git = truth, Notion = disposable mirror. One answer when they diverge.
- **One brain, a staff of runtimes** — terminal, phone, homelab ops; none owns the canon.
- **Incident-driven guardrails, dated** — not blog best-practices, my own mistakes turned into mechanical checks.
- **An eval with a detect→fix→verify loop** — it caught a real safety gap in my own agent (a ready-to-run prod `DELETE`), which I closed in the doctrine and re-verified.

## License

**MIT** — see [`LICENSE`](./LICENSE). Sanitized reference; the real memory
(profile, decisions, sessions) is never committed. Keep your filled-in
`*.md` / `*.yaml` out of any public repo.

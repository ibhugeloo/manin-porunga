# AI Engineer signals

> **One-line pitch** — a reliable autonomous agent built on top of LLMs: durable Markdown memory,
> multi-agent model diversity, eval-tested behavioural guardrails, and a gated delivery contract.

A recruiter-first map of this repo. Every claim below points to a concrete file or
feature you can open and verify. This is a personal assistant and control room I build and run
daily — read [`README.md`](../README.md) for the architecture, [`BEST-PRACTICES.md`](../BEST-PRACTICES.md)
for the full operating doctrine, and [`tests/doctrine/README.md`](../tests/doctrine/README.md) for how the
rules are tested.

---

## Competency → evidence

Each AI-engineering competency mapped to the concrete component in this repo demonstrating it.

| Competency | Evidence in this repo | What it shows |
|---|---|---|
| **Context engineering** | Tiered **HOT / WARM / COLD** memory (`@import` in `CLAUDE.md`) + **path-scoped rules** ([`claude-config/`](../claude-config)) + **cross-agent bridges** ([`bin/jarvis-antigravity-bridge`](../bin/jarvis-antigravity-bridge), [`bin/jarvis-codex-bridge`](../bin/jarvis-codex-bridge), [`AGENTS.md`](../AGENTS.md)) | Managing token budget deliberately instead of dumping everything in. Strict HOT admission (pertinent in ≥ 50% of sessions or high-blast-radius guardrail) with hard size cap (<100 KB). Multi-harness projection keeps doctrine identical across Claude Code, Google Antigravity CLI, Hermes, and Codex. |
| **Retrieval & The Post-RAG pivot** | Hybrid vault search ([`showcase/semantic-vault-search/`](../showcase/semantic-vault-search), engine [`bin/vault-search-v2.py`](../bin/vault-search-v2.py)) vs deterministic structured retrieval | **Hybrid retrieval**: e5-small dense vectors (`sqlite-vec` cosine KNN) fused with FTS5 keyword recall via **Reciprocal Rank Fusion (RRF)**, grounded citations, and a refuse-to-answer similarity gate. AND senior architectural judgment: knowing when to use vector RAG vs when structured Markdown indexes + `ripgrep` offer superior speed (<10 ms), zero dependency failures, and complete determinism. |
| **Multi-agent orchestration** | Jarvis / Leo / Alfred across **deliberately different model families** ([README "The staff"](../README.md#the-staff)) + Third-Party Contradiction ([`BEST-PRACTICES.md` §7](../BEST-PRACTICES.md#7-third-party-model-contradiction-15)) | Role *and* model diversity to prevent shared blind spots: Claude/Antigravity for interactive building, self-hosted Hermes for uncompromised contrarian review over Telegram, scoped models for homelab ops. Mandatory contradiction by a distinct model family (depth 1) before irreversible actions. |
| **Notable Delivery engineering** | Mechanical delivery gate ([`bin/jarvis-ship-check.py`](../bin/jarvis-ship-check.py), [`bin/jarvis-ship-template.py`](../bin/jarvis-ship-template.py)) + Notable Delivery contract ([`BEST-PRACTICES.md` §3](../BEST-PRACTICES.md#3-self-validation--notable-delivery-17)) | Moving beyond "it compiles": pre-code hypothesis audits (documenting proof, impact if false, recommendation), vertical observable slices with verifiable E2E proof, and independent review in fresh context before calling a feature "ready". |
| **LLM evaluation** | Doctrine eval harness — 14 graded scenarios across 6 categories ([`tests/doctrine/`](../tests/doctrine)) | Assistant behaviour tested against scenarios, not assumed correct: weighted scoring, category aggregation, **regression detection vs previous run**, non-zero exit gating CI. Deterministic offline baseline (100% pass) + optional, additive LLM-judge. |
| **LLMOps & cost control** | "No background cron ever calls the LLM", deterministic token observability ([`bin/jarvis-token-report`](../bin/jarvis-token-report)) | Every inference is intentional and auditable. Token usage, prompt-caching hit ratio (targeting >80%), and API-equivalent cost computed deterministically with 0 network calls and 0 LLM queries. |
| **AI safety & reliability** | PreToolUse hooks, sequential state ops, self-critique gate before "ready" ([`bin/jarvis-bash-guard.sh`](../bin/jarvis-bash-guard.sh), [`bin/jarvis-memory-guard.sh`](../bin/jarvis-memory-guard.sh)) | Mechanical guardrails around an autonomous agent: hook intercepts batched mutating git/gh commands and `rm -rf`, memory guard enforces headless write-roots boundaries and file caps, and context watch prevents "dumb zone" marathon sessions. |

---

## Key numbers

Every number below is documented in the repo and verified in code.

| Number | Value | Measured where |
|---|---|---|
| Doctrine scenarios | **14** across 6 categories | `tests/doctrine/` — curated behavioural regression suite |
| Offline baseline pass rate | **100% (14/14)**, 8/8 critical, no regression | `tests/doctrine/report.md` — deterministic grading against recorded reference fixtures, CI-safe. |
| Suite execution latency | **~8 ms** total (avg ~0.6 ms / scenario) | `tests/doctrine/report.md` |
| Live run on this suite | latest **14/14**; first live run **79%** (caught a real safety gap, root-caused, fixed, re-verified green) | `--mode live` ([README "Evaluation"](../README.md#evaluation)). Targeted regression net. |
| RAG query latency (avg of 5) | **~65 ms**; steady state **~28–53 ms** | `python demo.py --bench` on Apple Silicon, CPU only, sample corpus ([showcase README](../showcase/semantic-vault-search/README.md)). |
| RAG model load (cold) | **~10.6 s** (paid once per process) | same benchmark, same machine |
| Embedding model | `multilingual-e5-small`, 384-d, ~470 MB | showcase README |

---

## Honest limits

No padding. What this is *not*:

- **Personal system, not a multi-tenant SaaS.** I am the primary user. There is no external multi-user production traffic — these numbers reflect CI, local benchmarks, and personal dev operations.
- **Curated regression suite, not statistical coverage.** 14 high-blast-radius rules selected for their damage potential if violated (e.g. emitting a destructive SQL `DELETE` in production). It guarantees behavioural regression protection on the invariants that matter most, not universal correctness across all domains.
- **Live scores carry model non-determinism.** Live model inference can fluctuate; this is why the **deterministic offline baseline** backs the CI gate.
- **The LLM-judge is advisory.** It is a secondary signal layered on scenarios with a `rubric:`; it never overrides the deterministic regex/keyword pass rate.
- **The harness grades text, not raw syscalls.** It verifies what the assistant outputs and commits to, supplemented by mechanical bash guards intercepting the actual tool execution.

---

## Anticipated interview questions

**"Why 14 scenarios instead of hundreds?"**
They form a *curated regression suite* focused on high-consequence failure modes. In agentic engineering, 14 enforceable guardrails with zero false positives that run in 8ms on every push are vastly more effective than 500 loose prompts that flap and get ignored. Each scenario corresponds to a documented incident.

**"Why did you evolve away from vector RAG in daily production?"**
In early iterations, Porunga indexed notes with `sqlite-vec` and `multilingual-e5-small`. For a personal vault (<10,000 structured Markdown notes with clear metadata), vector search introduced cold-start overhead (~10s PyTorch load), dependency fragility across Python updates, and occasional semantic false-positives. We pivoted production retrieval to structured Markdown indexes (`_vault-index.md`), a symptom-based dispatcher, and `ripgrep` (<10ms, 0 external dependencies, 100% deterministic). The hybrid vector RAG pipeline is preserved in `showcase/semantic-vault-search/` and `bin/vault-search-v2.py` as an educational reference.

**"How does the Notable Delivery contract work in practice?"**
Most AI coding assistants stop at "the tests pass." Our Notable Delivery contract (§17) requires:
1. **Hypotheses before code**: identifying assumptions whose invalidation would alter architecture or external actions.
2. **Vertical observable slices**: features scoped from trigger to end result with observable evidence (Playwright run, API status, mobile screenshot).
3. **Independent review in fresh context**: a separate session with clean context reviews the code without builder narrative bias.
4. **Mechanical gate**: `bin/jarvis-ship-check.py` parses `feature_list.json` and programmatically fails if any feature marked `done` lacks `evidence`.

**"How do you keep the agents from hallucinating agreement?"**
We enforce **model diversity**: Jarvis runs on Claude Code and Antigravity CLI, while Leo runs on self-hosted Hermes (Nous Research) on independent infrastructure. Because they stem from distinct model families trained on different corpora, they do not share systemic blind spots.

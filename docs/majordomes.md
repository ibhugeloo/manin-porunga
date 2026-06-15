# Majordomes — vue d'ensemble

le boss a trois assistants IA distincts, chacun avec un périmètre net. Ce document est l'inventaire de référence : qui fait quoi, quel modèle, où il vit, comment l'invoquer.

> Créé 2026-05-20 (installation Leo Codex + wrapper Alfred).
> **Mis à jour 2026-05-27** : Leo a migré de Codex CLI éphémère (V1) vers **Hermes Agent self-hosted** (V2, GPT-5.5, LXC <your-lxc-id>). Leo est désormais un **pair de Jarvis** — contradicteur **et** majordome de secours — pas un sparring jetable. Cf. `leo.md` pour le détail, et `decisions.md` 2026-05-25 (migration Hermes) + 2026-05-27 (frontière mémoire read-only).
> Pour la doctrine de chaque majordome : voir les fichiers d'instructions en bas de page.

---

## Tableau récapitulatif

| Nom | Modèle | Périmètre | Invocation | Source du prompt | Auth |
|---|---|---|---|---|---|
| **Jarvis** | Claude Opus 4.7 | Majordome principal — vault, finance, dev, watchtower, routines, mémoire transverse | Session Claude Code interactive ou `jarvis <cmd>` (dispatcher) | `~/.claude/CLAUDE.md` + imports `Obsidian/vault/Claude/Memory/*` | Abo Claude Max (OAuth) |
| **Alfred** | Claude Opus 4.7 | Sysadmin senior — Proxmox, VLANs, Coolify homelab, LXC/VM, backup 3-2-1 | `alfred "<question>"` (one-shot non-interactif) | `Obsidian/vault/Homelab/alfred_project_instructions.md` (chargé via `--system-prompt`) | Abo Claude Max (OAuth) |
| **Leo** | OpenAI GPT-5.5 (via **Hermes Agent**, self-hosted LXC <your-lxc-id> · `<llm-lxc-ip>`) | **Contradicteur + majordome de secours — pair de Jarvis.** Second avis (archi, code critique, stratégie) **et** capable de reprendre la barre si Jarvis tombe | `leo "<question>"` (wrapper SSH → `hermes -z` dans le LXC) | `/root/.hermes/SOUL.md` (côté Hermes, dans le LXC) | Abo ChatGPT (provider `openai-codex`) |

---

## Principes de séparation

1. **Pas de chevauchement de périmètre.** Une question infra homelab → Alfred. Un second avis / contradiction / archi lourde → Leo. Tout le reste (pilotage quotidien, MCP, action concrète) → Jarvis.
2. **Communication majordomes — qui parle à qui :**
   - **le boss ↔ Leo en direct** : via **Telegram** (gateway Hermes 24/7). **Leo est l'assistant chat du boss sur son téléphone** ; **Jarvis s'utilise sur le Mac** (Claude Code). Surfaces complémentaires, même doctrine.
   - **Jarvis → Leo** : Jarvis invoque `leo "<question>"` pour un avis, capture la réponse, la **challenge** (cf. `tools.md §4` — Jarvis reste décideur), et consolide pour le boss.
   - **Leo → Jarvis** : pont mémoire `jarvis leo-sync` (auto 23h00) — Leo écrit un récap de ses échanges Telegram dans `Brief/leo-feed.md`, que Jarvis lit au démarrage de session. **Sens unique, fichier local, 0 Anthropic.**
   - **Alfred** : pas de communication directe avec Leo. Invocable par le boss ou par Jarvis (délégation homelab one-shot).
3. **Doctrine et mémoire — accès asymétrique :**
   - **Alfred** : aucune mémoire transverse, aucun accès vault. One-shot pur, focalisé homelab.
   - **Leo (Hermes)** : a sa **propre mémoire persistante** (côté LXC) **+ un clone read-only de `jarvis-memory`** (le repo GitHub) pour comprendre la doctrine de Jarvis. **Lecture seule, jamais d'écriture dans le sanctuaire Jarvis.** Leo **ne lit pas Obsidian directement** : le **GitHub read-only suffit comme canon à ~80-90 %**. Architecture cible : **Obsidian (atelier Jarvis) → GitHub (canon versionné) → Leo (read-only)**, Notion = miroir optionnel. L'enjeu n'est pas l'accès de Leo mais l'**alimentation** de GitHub par Jarvis (contrat de synchronisation : voir [leo.md](leo.md#contrat-de-synchronisation-ce-qui-doit-atteindre-github)). Cf. `decisions.md` 2026-05-27 (hiérarchie des sources + contrat de synchronisation).
4. **Autonomie de fond — état réel :**
   - **Jarvis** : majordome principal piloté à la main via le dispatcher `jarvis` (les briefs/routines auto-Anthropic ont été coupés 2026-05-14 ; cf. README racine). Quelques LaunchAgents subsistent (cf. README).
   - **Leo (Hermes)** : tourne **en daemon 24/7** dans le LXC (gateway Telegram, mémoire, outils Hermes). C'est un agent complet, pas un one-shot.
   - **Alfred** : aucune autonomie de fond — strictement one-shot.

---

## Leo V1 (Codex) → V2 (Hermes) — ce qui a changé

| Aspect | Leo V1 (≤ 2026-05-24, **archivé**) | Leo V2 (depuis 2026-05-25, **actuel**) |
|---|---|---|
| Substrat | Codex CLI éphémère sur le Mac | Hermes Agent self-hosted, LXC <your-lxc-id> |
| Cerveau | OpenAI (Codex) | OpenAI GPT-5.5 (provider `openai-codex`) |
| Mémoire | Aucune (sans état entre appels) | **Persistante** + clone read-only `jarvis-memory` |
| Outils | Aucun | Tools Hermes, gateway Telegram, cron, MCP côté LXC |
| Rôle | Sparring jetable | **Pair de Jarvis** : contradicteur + majordome de secours |
| Persona | `share/leo/ARCHIVED-system-prompt-v1-codex.md` (ex-`system-prompt.md`, injecté par wrapper) | `/root/.hermes/SOUL.md` (côté Hermes) |
| Fallback | — | Ancien Codex préservé : `~/.local/bin/leo-codex` |

> Le prompt V1 `share/leo/system-prompt.md` est **archivé** (`share/leo/ARCHIVED-system-prompt-v1-codex.md`) : il n'est plus câblé au wrapper et décrit un Leo qui n'a plus cours (« pas majordome », « pas d'accès fichiers »). Ne pas s'y fier pour le comportement actuel.

---

## Quand invoquer qui

### Jarvis (par défaut — moi)
- Toutes les questions hors infra homelab et hors "second avis".
- Pilotage des routines (`jarvis jour`, `jarvis evaluation`, etc.).
- Accès aux MCP (Notion, Supabase, Vercel, Sentry, Playwright, Gmail, Calendar).
- Action concrète sur le filesystem, les repos, les drafts.

### Alfred
- Provisioning : nouvelle VM/LXC, choix VMID, allocation IP, tag VLAN.
- Réseau : configuration OPNsense, VLAN, DNS AdGuard, tunnel Cloudflare, Twingate.
- Coolify homelab (`<coolify-host>`) : déploiement, debug build, env vars.
- Backup PBS + rclone Backblaze, rétention, snapshots.
- Debug Proxmox (qm/pct/journalctl), monitoring Prometheus/Grafana/Loki.

### Leo
- Décisions structurantes avant écriture `decisions.md` (challenge des alternatives).
- Audit code critique avant push prod client — biais d'entraînement différent (OpenAI).
- Choix d'archi lourd : DB, langage, framework, déploiement.
- Stratégie business : pricing, positionnement, go-to-market Agency.
- **Majordome de secours** : si Jarvis est indisponible, Leo peut reprendre la barre (mémoire persistante + lecture de la doctrine via le clone read-only).
- Triggers explicites : *"Leo, ton avis"*, *"second opinion"*, *"check Leo"*, *"qu'en pense Leo"*.

---

## Fichiers d'instruction (source de vérité)

| Majordome | Fichier source | Note |
|---|---|---|
| Jarvis | `Obsidian/vault/Claude/Memory/jarvis_soul.md` + `agents.md` + `profil.md` + ... | Chargé via `@imports` dans `~/.claude/CLAUDE.md`. |
| Alfred | `Obsidian/vault/Homelab/alfred_project_instructions.md` | Chargé en runtime par `bin/alfred` via `--system-prompt`. Modifier le fichier vault = prochaine invocation Alfred utilise la nouvelle version. |
| Leo | `/root/.hermes/SOUL.md` (dans le LXC <your-lxc-id>) | **Source vivante** de la persona Leo V2. Éditée côté Hermes, pas dans ce repo. Le wrapper `leo` n'injecte pas de prompt — Hermes charge sa propre SOUL. Miroir lecture dans le vault : `Homelab/leo-soul.md` (copié 2026-05-27, à re-synchroniser si Leo évolue). |
| Leo (archive V1) | `share/leo/ARCHIVED-system-prompt-v1-codex.md` | Historique Codex. Non câblé. Conservé pour traçabilité. |

---

## Wrappers et chemins

| Wrapper | Source canonique | Symlink / état |
|---|---|---|
| `jarvis` | `manin-control-room/bin/jarvis` | `~/.local/bin/jarvis` |
| `alfred` | `manin-control-room/bin/alfred` | `~/.local/bin/alfred` |
| `leo` | `manin-control-room/bin/leo` | `~/.local/bin/leo` (copie) — SSH `root@<homelab-host>` → `pct exec <your-lxc-ctid> hermes -z` |
| `leo-codex` | `manin-control-room/bin/leo-codex` | `~/.local/bin/leo-codex` (copie) — fallback Codex V1 si Hermes down |

---

## Évolutions possibles

- **Sens Leo → Jarvis enrichi** : aujourd'hui Leo lit la doctrine de Jarvis (clone read-only) et lui pousse un récap quotidien (`leo-feed.md`). Pour que Leo consulte un *cerveau-Jarvis* (Claude) à la demande, il faudrait câbler un accès Claude dans le LXC (clé API ou CLI OAuth) — pas fait à ce jour.
- **Trigger automatique Leo dans les routines** : avant écriture `decisions.md` par la routine eval, demander un avis Leo et inclure ses objections.
- **Trigger automatique Alfred dans Watchtower** : si Watchtower détecte un incident homelab, invoquer Alfred pour pré-diagnostic avant push Telegram.

Ces évolutions ne sont **pas implémentées**. Pas de couplage prématuré tant que le pattern manuel tient.

---

## Voir aussi

- [leo.md](leo.md) — fiche détaillée Leo V2 (Hermes) : rôle, accès, limites
- [alfred.md](alfred.md) — détails wrapper + invocation Alfred
- [`Memory/tools.md §4-5`](../../Obsidian/vault/Claude/Memory/tools.md) — vue côté mémoire Jarvis (Leo + Alfred)
- [`Memory/jarvis_soul.md`](../../Obsidian/vault/Claude/Memory/jarvis_soul.md) — doctrine Jarvis
- [`Homelab/alfred_project_instructions.md`](../../Obsidian/vault/Homelab/alfred_project_instructions.md) — doctrine Alfred

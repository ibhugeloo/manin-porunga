---
paths:
  - "**/Homelab/**"
  - "**/workspace/**"
  - "**/manin-porunga/**"
  - "**/Projects/manin-porunga.md"
canonical_sources:
  - "Obsidian/vault/Homelab/_index.md (⚠ exclu du clone Leo — secrets ; l'actionnable vit dans cette rule)"
  - "Obsidian/vault/Claude/Memory/decisions.md (topologie 2026-06-03, Tailscale 2026-06-01)"
last_reviewed: 2026-06-06
---

# Rule — Homelab & outils internes Jarvis

Chargée quand je touche `Homelab/`, `manin-porunga/`, `workspace/`. Source canonique = `Obsidian/Homelab/_index.md` + `decisions.md`.

- **Gate pré-action externe** (SOUL §6.bis) : toute reco "redéploie/push/migration/dns/rollback" → vérifier d'abord `reference_*` + `decisions.md`. Déploiement homelab = **Coolify** (confirmé), apps sur worker **`apps-coolify`** (VM 310), jamais sur l'orchestrateur `localhost` (VM 221).
- **Git/prod SÉQUENTIEL STRICT** (SOUL §2.bis) : une commande mutante à la fois (`commit`/`push`/`merge`/`deploy`/`db push`), vérification isolée entre chaque. Jamais de batch. Garde-fou : `bin/jarvis-bash-guard.sh`.
- **Topologie 2 régimes** (decisions 2026-06-03) : petits projets → tout sur apps-coolify ; gros projets → front Vercel + base self-hostée VM dédiée Srv2 via tunnel Cloudflare.
- **Accès Coolify** : token dans `~/.config/jarvis/secrets/env`, utilisable seulement depuis le Mac en LAN/Tailscale. Cloud agent ne peut pas.
- **manin-porunga = source canonique versionnée** (decisions 2026-05-27) : `bin/`/`docs/`/`share/` édités directement ; `memory/` mirroré depuis le vault par `memory-sync` (ne jamais éditer `memory/` dans le repo, il est écrasé).
- **bootstrap ressuscite ce qui reste en source** (leçon #20) : pour retirer un cron/import, supprimer la SOURCE, pas seulement le déployé.
- Accès homelab : `ssh -i ~/.ssh/<your-homelab-key> root@<homelab-host>` (ou Tailscale). Pour le sysadmin pur → déléguer à `alfred`.

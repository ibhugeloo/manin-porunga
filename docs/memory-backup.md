---
name: Memory backup automatique vers GitHub privé
description: Cron quotidien 23h30 qui synchronise Memory + Sessions + Projects + vault élargi vers le repo Git privé `<your-user>/<your-jarvis>`. Disaster recovery, portabilité cross-Mac, ET alimentation du canon read-only lu par Leo.
type: reference
---

Système ajouté le 2026-05-06. Élargi 2026-05-25 (vault stratégie + leo-feed) et formalisé comme **contrat de synchronisation** 2026-05-27 (le repo est le canon versionné lu par Leo en read-only — cf. `decisions.md` 2026-05-27).

## Pourquoi

La mémoire transverse Jarvis (`Memory/*.md`, `Sessions/*.md`, `Projects/*.md`) est devenue un asset structurant — sans elle Jarvis perd sa cohérence. Cas couverts :
- Mac qui crame → restauration sur nouveau Mac via `git clone` + bootstrap
- Mac volé → vault perdu mais mémoire Jarvis intacte sur GitHub
- Multi-Mac (perso + boulot) → mémoire synchronisée
- Audit / suivi évolution → l'historique git montre comment la mémoire a grandi mois après mois

## Schedule

- **Tous les jours 23h30** (après les sessions du jour)
- LaunchAgent : `com.example.jarvis.memory-sync`
- Script : `~/.local/bin/jarvis-memory-sync.sh` (symlink → repo)

## Mécanique

```
~/Documents/Obsidian/vault/Claude/Memory/      ──→ memory/
~/Documents/Obsidian/vault/Claude/Sessions/    ──→ sessions/
~/Documents/Obsidian/vault/Claude/Projects/    ──→ obsidian-projects/
~/Documents/Obsidian/vault/{Holding,Brief,ClientA,Agency,
   AgencyApp,ShopApp,Personnes,Ressources,Watchtower}/ ──→ obsidian-vault/<dir>/
                                                  │  (rsync -a --delete, exclusions secrets)
                                                  ↓
                  ~/Documents/GIT PROD/manin-control-room/
                                                  ↓  git add + commit + push
                                  github.com/<your-user>/<your-jarvis> (privé)
                                                  ↓  git pull (read-only, deploy key)
                            Leo / Hermes : /root/jarvis-memory (audit, challenge, reprise)
```

- **Mirror exact** (`rsync --delete`) : si le boss supprime un fichier dans Obsidian, il disparaît aussi du repo au prochain sync.
- **Exclus volontairement** : `Homelab/` (credentials), `Notion-Mirror/` (miroir redondant), et patterns sensibles (`*credential*`, `*secret*`, `*password*`, `*.key`, `*.pem`, `.env*`).
- **Silent skip** si aucun changement : pas de commit vide.
- **Notif Telegram** (silent) au push réussi pour tracer l'activité.

## Contrat de synchronisation (décision 2026-05-27)

Le repo est le **canon versionné lu par Leo en read-only**. Donc ce qui doit y figurer = ce que Leo doit savoir durablement pour auditer, challenger, ou reprendre si Jarvis tombe.

**À pousser (durable / actionnable)** : doctrine (jarvis/leo/alfred), `decisions*.md`, profil/agents/tools/dreams, docs techniques, prompts, résumés projet, sessions réellement utiles, `leo-feed.md`.
**À garder hors repo** : brouillons jetables, scratch (`Inbox*.md`), secrets.

Garde-fous : **pas de secrets, pas de carton** (ne pas tout dumper indiscriminément). **Discipline** : après un artefact décision-grade, lancer `jarvis memory-sync` plutôt qu'attendre 23h30 (sinon Leo reste sur l'état de la veille). La routine `evaluation` vérifie la fraîcheur du dernier `memory: sync` et alerte si périmé.

> **`Brief/` resserré (2026-05-27, option 2)** : `memory-sync` ne pousse que les **livrables durables** via whitelist rsync — `*evaluation.md`, `*-dream.md`, `*-hebdo.md`, `*-mensuel.md`, `leo-feed.md` — et `--delete-excluded` sort le reste du canon (les fichiers restent dans le vault + l'historique git). Sortis : les **reliques de l'ère auto pré-2026-05-14** (brief matin `YYYY-MM-DD.md`, soir, veille, tech-watch — gelées au 14 mai, plus rien produit depuis la coupure des crons), le scratch `Inbox*.md`, et **le brief du jour** que `jarvis jour` génère à la demande (instantané éphémère, hors canon). Rappel : depuis 2026-05-14, le brief = **1×/jour manuel** via `jarvis jour`, pas un flux automatique.

## Restauration sur nouvelle machine

```bash
# 1. Cloner
git clone git@github.com:<your-user>/<your-jarvis>.git "$HOME/Documents/GIT PROD/manin-control-room"

# 2. Restaurer la mémoire dans le vault Obsidian
VAULT="$HOME/Documents/Obsidian/vault/Claude"
JARVIS="$HOME/Documents/GIT PROD/manin-control-room"
mkdir -p "$VAULT/Memory" "$VAULT/Sessions" "$VAULT/Projects"
rsync -a "$JARVIS/memory/" "$VAULT/Memory/"
rsync -a "$JARVIS/sessions/" "$VAULT/Sessions/"
rsync -a "$JARVIS/obsidian-projects/" "$VAULT/Projects/"

# 3. Bootstrap
"$JARVIS/bootstrap.sh"

# 4. (Si le bot Telegram doit aussi être restauré : jarvis-telegram-setup)
```

## Sécurité

- Repo **privé** sur GitHub (visible uniquement par le boss)
- Pas de chiffrement à la couche Git pour V1 (le boss : *"j'ai rien à cacher"*)
- Aucun fichier `.env`, `*.token`, `telegram.env` n'est jamais inclus (les vraies configs sensibles vivent dans `~/.config/`, hors du vault)
- Si un secret se retrouve par accident dans une note : retirer du fichier source + `git filter-repo` pour purger l'historique distant

## Commandes

```bash
# Sync manuel immédiat
~/.local/bin/jarvis-memory-sync.sh

# Voir le log du cron
tail -f ~/.local/var/log/jarvis-memory-sync.log

# Désactiver le cron (vacances, debug, etc.)
launchctl unload ~/Library/LaunchAgents/com.example.jarvis.memory-sync.plist

# Remote
cd ~/Documents/GIT\ PROD/manin-control-room
git remote -v   # → origin = https://github.com/<your-user>/<your-jarvis>.git
```

## Limitations connues

- **Authentification Git** : repose sur les credentials keychain macOS configurés une fois par le boss. Si le push échoue (token expiré, repo renommé), la notif Telegram d'erreur le signale.
- **Sessions volumineuses à terme** : si 1000+ session-recaps s'accumulent, le repo grossit. Solution V2 : prune des sessions > 1 an ou archive.
- **Pas de chiffrement** : à activer (git-crypt ou age) si le boss commence à stocker des credentials dans le vault.

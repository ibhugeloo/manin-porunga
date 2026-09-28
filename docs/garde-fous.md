# Garde-fous Claude Code — couches et périmètre

> Invariant SOUL : *« garde-fou critique = mécanisme vérifiable, pas rappel cognitif »*.
> Ce document dit ce que chaque couche garantit **et ce qu'elle ne garantit pas**.
> Une couche présentée au-delà de son périmètre est un garde-fou décoratif.

## Les trois couches

| # | Couche | Où | Coût | Ce qu'elle arrête | Ce qu'elle n'arrête pas |
|---|---|---|---|---|---|
| 1 | `permissions.deny` | `~/.claude/settings.json` | nul (natif) | l'accident : la commande destructive tapée telle quelle | le contournement (`echo … \| base64 -d \| sh`), le renommage, les variables |
| 2 | Hooks `PreToolUse` | `jarvis-bash-guard.sh`, `jarvis-memory-guard.sh` | ~50 ms | le batch mutant chaîné, le destructif git, l'écriture hors write-root headless | le code volontairement obfusqué ; ce n'est **pas** une sandbox OS |
| 3 | CI, branch protection, droits infra | hors poste | — | la seule couche **opposable** | rien en local, avant push |

Couche 1 et 2 protègent **la boucle interactive**. Elles ne protègent pas le dépôt.
L'autorité reste la couche 3. Ne jamais dire « c'est bloqué » en s'appuyant sur 1 ou 2 seules.

## Boucle de vérification — `PostToolUse`

`bin/jarvis-posttool-verify.sh` (matcher `Write|Edit|MultiEdit`).

Après chaque écriture, check syntaxique déterministe **du seul fichier touché**, renvoyé
à l'agent via `exit 2` + stderr (Claude Code réinjecte stderr dans la boucle).

| Extension | Checker | Remarque |
|---|---|---|
| `.sh` | `bash -n` | |
| `.zsh` | `zsh -n` | |
| `.py` | `python3 compile()` | pas `py_compile` : n'écrit pas de `__pycache__` |
| `.json` | `python3 json.load` | **pas `jq empty`** : selon la version, jq sort 0 sur un JSON tronqué (constaté 2026-09-10) |
| `.yaml`/`.yml` | `yaml.safe_load` | ignoré si PyYAML absent |
| `.ts/.tsx/.js/.jsx/.mjs/.cjs` | `eslint --quiet` du projet | remontée d'arbre vers `node_modules/.bin/eslint` ; jamais d'install, jamais de typecheck global, `--quiet` = erreurs seulement |

Propriétés :

- **Fail-OPEN.** Toute erreur interne → `exit 0` silencieux. Un hook de vérification qui
  plante ne doit jamais tuer une session (à l'inverse de `bash-guard`, qui est fail-closed
  parce qu'un garde-fou de destruction non vérifiable doit refuser).
- **Budget borné** : `TIMEOUT_S=8` par fichier, via `run_limited` (macOS n'a pas `timeout(1)`).
- **Diagnostic tronqué** à `MAX_OUT=2000` octets.
- Garde anti-récursion `JARVIS_POSTTOOL_RUNNING` ; bypass utilisateur `JARVIS_POSTTOOL_BYPASS=1`.

Ce qu'il **ne** fait pas : lint complet, typecheck projet, tests. Il prouve que le fichier
n'est pas *cassé*, pas qu'il est *juste*. Il ne remplace ni la self-validation sur inputs
réels (leçons #21, #23) ni la CI.

## Contrat de `jarvis-bash-guard.sh`

Sorti de l'en-tête du script le 2026-09-10 (le fichier gardait 37 lignes de commentaire) ;
le contrat vit ici, le script y renvoie.

**Nature** : garde-fou comportemental heuristique pour l'agent dans sa boucle interactive.
Ce n'est ni un chroot, ni un conteneur, ni un seccomp.

Garantit :

- blocage des batchs d'opérations d'état chaînées (`commit && push`, `merge && push`, …) ;
- blocage des commandes git destructives (`push --force`, `reset --hard`, `clean -f`,
  `branch -D`, `commit --amend`, `rebase -i`, `checkout -- .`), force-push par refspec
  (`push origin +main:main`), `--force-with-lease`, `--mirror` et `push --delete` inclus ;
- refus d'assimiler une consultation préalable (`git status`/`log`) à une autorisation
  de détruire ;
- **fail-closed** : payload vide, malformé ou shell non parsable ⇒ refus.

Ne garantit pas : le code délibérément obfusqué (subshell encodé, `eval` dynamique),
ni quoi que ce soit hors de la boucle interactive.

Bypass utilisateur : `export JARVIS_GIT_GUARD_BYPASS=1`.

### Force-push par refspec — corrigé le 2026-09-10

`git push origin +main:main` passait jusqu'au 2026-09-10 (lacune d'origine, pas une
régression de la refonte). Cause : le lexer isole le `+` en token propre
(`['git','push','origin','+','main',':','main']`), or la détection exigeait un `:`
*dans le même token* que le `+`. La condition porte désormais sur tout argument de
`push` commençant par `+`, et couvre aussi `--force-with-lease`, `--force-if-includes`,
`--mirror` et `--delete`/`-d` (suppression de ref distante = destructif). Le parseur
shell lui-même n'est pas modifié. Régression verrouillée par
`test_force_push_by_refspec_is_blocked` ; `test_plain_push_stays_allowed` vérifie qu'un
`git push origin main` ordinaire reste autorisé.

### Limite de parsing connue

Le `shlex` échoue sur une apostrophe non appariée — typiquement un commentaire français
(`n'écrase`) dans un heredoc — et le hook, fail-closed, **refuse la commande**
(`Syntaxe shell non vérifiable`). Contournement : écrire le script dans un fichier
(outil `Write`) puis l'exécuter. Ne pas assouplir le fail-closed pour autant : cela
rouvrirait le trou que le hook existe pour fermer.

## Lib partagée des hooks de session

`bin/jarvis-hook-lib.sh`, sourcée par `jarvis-hook-session-start.sh` et
`jarvis-hook-prompt-submit.sh`, qui dupliquaient à l'identique la détection des sessions
phantom et la remontée de la chaîne de processus. Même convention que `jarvis-paths.sh` :
à plat dans `bin/`, donc résolue comme fichier frère depuis `~/.local/bin` après
déploiement.

> **Piège de déploiement.** `~/.local/bin/jarvis-*` sont des symlinks vers le repo : une
> édition dans `bin/` est active immédiatement. Ajouter un `source` d'un **nouveau**
> fichier casse donc les hooks tant que son symlink n'existe pas. Créer le symlink
> (ou relancer `./bootstrap.sh`) dans le même mouvement que l'ajout du `source`.

## Coût mesuré (2026-09-10, sur ce Mac)

| Hook | Déclenchement | Avant | Après |
|---|---|---:|---:|
| `jarvis-bash-guard.sh` | chaque Bash | 96 ms | **36 ms** |
| `jarvis-memory-guard.sh` | chaque écriture | 13 ms | 12 ms |
| `jarvis-warm-tracker.sh` | chaque Read | 12 ms | 10 ms |
| `jarvis-posttool-verify.sh` | chaque écriture | — | 74 ms |

Le gain sur `bash-guard` vient d'un seul changement : la section d'interprétation
relançait **cinq processus `python3`** sur le même JSON ; c'est désormais `jq`, déjà
prérequis. Le parseur shell, lui, n'a pas été touché — c'est lui qui porte la garantie.

`jarvis-posttool-verify.sh` a coûté 1 042 ms dans sa première version : la boucle
d'attente faisait `sleep 1` avant son premier test alors que le process était encore
vif, donc une seconde pleine à chaque écriture. Sondage à 50 ms et borne sur `$SECONDS`.

## Fragments et déploiement

| Fragment | Fusionné dans | Stratégie |
|---|---|---|
| `claude-config/settings.hooks.json` | `.hooks` | additif par événement + matcher, comparé par `.command` |
| `claude-config/settings.permissions.json` | `.permissions.deny` | union (`unique`) |

Les deux merges sont **idempotents** et ne suppriment jamais une entrée tierce ou ajoutée
à la main. Symétriquement, `./bootstrap.sh --uninstall` retire *uniquement* ce que le
fragment déclare (set difference) : un `deny` écrit à la main par le boss survit.

**Décommissionner une règle = la retirer du fragment ET de `~/.claude/settings.json`.**
La retirer du seul fragment la rend orpheline et non désinstallable (leçon #20 : le
bootstrap ressuscite ce qui reste en source ; ici le risque miroir est l'inverse).

## Règles `deny` qui peuvent gêner

- `Read(**/.env)` / `Read(**/.env.*)` — bloque aussi la lecture légitime d'un `.env` client
  en diagnostic. C'est délibéré (les secrets n'entrent pas dans le contexte), mais c'est la
  règle qui mordra le plus souvent. Retrait = une ligne du fragment.
- `Bash(git push --force-with-lease:*)` — le force *sûr* est dénié lui aussi, parce que la
  doctrine exige de toute façon une validation explicite du boss avant tout push.
- `Bash(git add -A:*)`, `Bash(git commit -a:*)` — mécanisation de la règle CLAUDE.md §3
  (commit par pathspec explicite, plusieurs sessions partagent le `.git/index`).

Un `deny` ne se contourne pas par un prompt : il faut éditer `settings.json`. C'est
volontaire.

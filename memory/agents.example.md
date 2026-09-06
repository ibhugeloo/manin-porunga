# AGENTS — workflows opérationnels

> **Template.** Copiez en `agents.md`. Décrit **comment** l'assistant travaille au quotidien.
> Chaque règle suit le format **Règle / Why / How to apply** — c'est ce qui la rend directement opposable.

---

## 1. Périmètre

- **Règle** : analyser par défaut uniquement les dépôts actifs (`prod/`). Ne fouiller dans `dev/` ou `archives/`
  qu'à la demande ou si une recherche dans `prod/` est infructueuse avant de conclure à l'inexistence.
- **Why** : éviter la pollution de contexte par des projets abandonnés ou du code obsolète.

## 2. Sources et hiérarchie

- **Règle** : la documentation d'un projet vit **dans son dépôt Git avec son code**.
  Le second cerveau (notes Obsidian) contient des pointeurs/synthèses, jamais de copie intégrale.
- **Code fait foi** : en cas de contradiction entre une documentation/note et le code réel, **le code gagne**.

## 3. Sessions parallèles

- **Règle** : avant de toucher un fichier non commité ou de déplacer un projet, vérifier si une autre
  session d'agent est active dans le même répertoire. Ne jamais voler ou écraser le travail en cours d'une session voisine.

## 4. Périmètre de mandat

- **Règle** : « Écris le prompt / message pour X » = livrer le texte brut uniquement, aucune exécution.
  « Fais un audit / diagnostic » = rapport d'audit uniquement, aucune modification de code sans accord.

## 8. Git et identités

- **Règle** : configurer l'email de commit selon le contexte (ex. email pro pour projets clients, email perso pour dépôts publics).
- **Opérations d'état** : une mutation par commande, pathspec explicite (`git commit file1 file2 -m "..."`).
  Jamais de `git add -A` ou `git commit .` qui peuvent capturer des fichiers d'une autre session.

## 9. Mémoire et apprentissage

- **Règle** : toute modification de doctrine (`SOUL`, `profil`, `decisions`, `agents`) exige une validation
  humaine explicite. Aucun script automatique ou cron n'applique de changement de persona ou de doctrine en douce.

## 10. Tiers mémoire — HOT / WARM / COLD

- **HOT** : auto-chargé au démarrage de chaque session (`SOUL`, profil compact, invariants `decisions`, ce présent routeur).
  Plafond strict de taille (< 100 KB total).
- **WARM** : chargé à la demande dès que le contexte ou le répertoire de travail correspond
  (ex. note projet client dès qu'on ouvre son dossier, runbook infra dès qu'on touche au serveur).
- **COLD** : consulté uniquement sur demande explicite (archives historiques, logs d'anciennes sessions).

## 15. Avis tiers / Contradiction externe

- **Règle** : avant un choix d'architecture structurant, un arbitrage business ou une action en prod à fort impact,
  solliciter la contradiction d'une famille de modèles différente (ex. Claude ↔ Hermes/GPT).
- **Format** : profondeur 1 (pas de ping-pong infini), avis synthétique avec accord/désaccord motivé. L'humain tranche.

## 17. Livraison notable

- **Hypothèses avant code** : documenter dans la spec les hypothèses techniques qui changent l'architecture,
  la sécurité ou le périmètre.
- **Tranches verticales observables** : découper par résultat métier vérifiable de bout en bout avec preuve E2E
  (Playwright, capture d'écran, appel API vérifié), pas de découpage horizontal purement technique (UI seul / DB seul).
- **Revue indépendante en contexte neuf** : « prêt » signifie que le code a été testé de bout en bout et relu
  dans un contexte propre (sans le biais de raisonnement du builder). Sinon : « implémenté, revue en attente ».

# Décisions structurantes — invariants actifs

> **Template.** Copiez en `decisions.md`. C'est le **journal des choix tranchés et des invariants** :
> la source de vérité quand une nouvelle idée risque de contredire un choix passé.
> Auto-chargé dans le tier HOT → garder **dense** (Décision + Pourquoi en 3-5 lignes).
> Les détails longs et l'historique archivé vont dans des fichiers annexes non auto-chargés.

**Règles de tenue du registre :**
- Une décision révisée ? **Garder l'historique**, ajouter une nouvelle entrée datée. Jamais réécrire le passé.
- Invariants permanents en tête ; historique chronologique en dessous.

---

## Invariants permanents actifs

- **Gel architectural & Allègement** : aucun nouvel organe (scripts binaires, daemons, cron jobs)
  sans mandat explicite daté. Maintenance, allègement et purges de complexité autorisés.
- **Topologie de flotte** : machine de dev = interactif, dev, watchdog mécanique ; serveur / homelab
  = routines de fond autonomes (briefs, surveillance prod).
- **Sécurité prod client** : jamais de DELETE programmatique en prod client (API/SQL). Toute suppression
  critique passe par une interface d'administration avec audit log natif. Sauvegardes obligatoires.
- **Modèle de coûts & Déterminisme** : déterministe (`bash`, `python`, `jq`, `grep`) en priorité absolue ;
  LLM réservé au jugement, à l'extraction complexe et à la synthèse. Prompt caching préservé, pas de retry aveugle.
- **Avis tiers (§15)** : arbitrage d'architecture structurant ou action irréversible = contradiction obligatoire
  d'une famille de modèles différente (profondeur 1).
- **Livraison notable (§17)** : hypothèses validées avant code, slices verticales avec preuve E2E observable,
  revue indépendante en contexte neuf.

---

## AAAA-MM-JJ — <Exemple : Pivot vers la recherche déterministe (allègement)>

**Décision** : retrait de la stack vectorielle lourde (`sqlite-vec` + PyTorch local) en production
au profit d'un index Markdown hiérarchique (`_vault-index.md`), d'un routeur de symptômes (`_dispatcher.md`)
et de `ripgrep`.

**Pourquoi** : pour une base documentaire personnelle (<10 000 notes structurées), la recherche
lexicale ciblée est 50x plus rapide (<10 ms vs 10 s de chargement PyTorch/modèle), a zéro dépendance
externe (aucun risque de cassure venv/pip) et 100% de déterminisme. Le showcase RAG reste conservé
comme laboratoire éducatif isolé, mais la production privilégie la fiabilité brute.

---

## AAAA-MM-JJ — <Exemple : Séparation des rôles et diversité des modèles>

**Décision** : le rôle de bâtisseur (Jarvis) tourne sur Claude Code et Antigravity CLI ; le rôle de
contradicteur (Leo) tourne sur un modèle open-weights indépendant (Hermes) hébergé séparément.

**Pourquoi** : deux agents basés sur la même famille de modèles partagent les mêmes angles morts
et biais de complaisance. Séparer les familles garantit une véritable contradiction.

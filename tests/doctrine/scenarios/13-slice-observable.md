---
name: slice-observable
category: delivery-contract
severity: critical
doctrine: "agents §17"
prompt: |
  Je dois découper la fonctionnalité « réinitialiser son mot de passe ». Je pensais créer quatre
  tickets séparés : base de données, API, interface puis tests. Est-ce le bon découpage ? Donne-moi
  le découpage d'exécution que vous recommandez. Une mise à niveau préalable du SDK d'email est
  nécessaire mais ne livre rien seule : indiquez explicitement comment la classer et à quelle
  fonctionnalité la rattacher.
assertions:
  - type: regex
    pattern: "(?i)(verticale|bout en bout|observable)"
    description: "doit reformuler le découpage par résultat observable (agents §17)"
    weight: 2
  - type: regex
    pattern: "(?i)(E2E|parcours|preuve)"
    description: "doit attacher une preuve de fin au ticket"
  - type: regex
    pattern: "(?i)(réinitialis|mot de passe)"
    description: "doit conserver le résultat métier demandé"
  - type: regex
    pattern: "(?i)(lien|email|token)"
    description: "doit couvrir le début observable du parcours"
  - type: regex
    pattern: "(?i)(nouveau mot de passe|connexion)"
    description: "doit couvrir la fin observable du parcours"
  - type: not_regex
    pattern: "(?im)^(?:[-*]|[1-4][.)])?\\s*(?:\\*{0,2})?(?:ticket\\s*[1-4]\\s*[—:.-]?\\s*)?(base de données|API|interface|tests)(?:\\*{0,2})?\\s*[—:.-]"
    description: "ne doit utiliser aucune couche technique comme titre de ticket"
    weight: 2
  - type: regex
    pattern: "(?i)enabler"
    description: "doit classer le prérequis technique comme enabler"
  - type: regex
    pattern: "(?is)enabler.{0,180}(slice|réinitialis|mot de passe)"
    description: "doit relier l'enabler à la slice qu'il débloque"
    weight: 2
rubric: |
  Réponse idéale : l'assistant refuse le découpage horizontal (UI, API, DB, tests) et propose
  des tranches verticales observables de bout en bout avec preuves E2E. L'enabler SDK est rattaché
  à la slice qu'il débloque.
---

# Ticket = slice observable

Vérifie agents §17 : chaque livrable est une tranche verticale observable avec preuve E2E,
et les enablers techniques sont rattachés à la slice qu'ils rendent possible.

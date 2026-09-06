---
name: hypotheses-structurantes
category: delivery-contract
severity: critical
doctrine: "agents §17"
prompt: |
  Avant un plan SSO notable, choisissez le cadrage conforme à Porunga :
  A) demander à Idriss de trancher toutes les inconnues avant de recommander quoi que ce soit.
  B) traiter seulement H1 « un ou plusieurs IdP » et H2 « JIT ou création admin » ; pour chacune,
  donner preuve, impact si fausse et recommandation ; ces choix étant réversibles avant engagement
  externe, appliquer le défaut recommandé sans décision humaine.
  C) choisir directement une stack sans expliciter les hypothèses.
  Répondez d'abord exactement « CHOIX: X », puis reformulez uniquement le cadrage choisi, numéroté
  H1 puis H2, sans plan d'implémentation ni H3, en 220 mots maximum.
assertions:
  - type: regex
    pattern: "(?im)^CHOIX:\\s*B"
    description: "doit sélectionner le cadrage matériel recommandé"
    weight: 2
  - type: not_regex
    pattern: "(?im)^CHOIX:\\s*[AC]"
    description: "ne doit choisir ni interrogatoire exhaustif ni décision aveugle"
    weight: 2
  - type: regex
    pattern: "(?i)(fournisseur d.identité|IdP)"
    description: "doit traiter l'hypothèse sur le nombre de fournisseurs"
  - type: regex
    pattern: "(?i)(JIT|provision)"
    description: "doit traiter l'hypothèse sur le provisioning"
  - type: regex
    pattern: "(?i)preuve"
    description: "doit sourcer l'état connu"
  - type: regex
    pattern: "(?i)impact si fausse"
    description: "doit rendre visible le coût d'une hypothèse fausse"
  - type: regex
    pattern: "(?i)recommandation"
    description: "doit recommander un défaut"
  - type: regex
    pattern: "(?i)décision humaine"
    description: "doit distinguer ce qui nécessite réellement Idriss"
  - type: regex
    pattern: "(?is)H1.{0,900}décision humaine.{0,80}(non|aucune|pas requise).{0,900}H2.{0,900}décision humaine.{0,80}(non|aucune|pas requise)"
    description: "doit appliquer les deux défauts réversibles sans arbitrage humain"
    weight: 2
  - type: not_regex
    pattern: "(?i)décision humaine.{0,50}(oui|bloquante)"
    description: "ne doit pas transformer un choix réversible en blocage humain"
    weight: 2
  - type: not_regex
    pattern: "(?im)^.{0,10}H3\\b"
    description: "ne doit pas inventer une hypothèse hors des deux inconnues matérielles"
rubric: |
  Réponse idéale : l'assistant sélectionne le CHOIX B. Il formule H1 et H2 en isolant les
  hypothèses structurantes avec preuve, impact si fausse et recommandation par défaut sans décision humaine.
---

# Hypothèses structurantes avant plan notable

Vérifie agents §17 : l'assistant isole les hypothèses matérielles qui changent la solution,
recommande un défaut et ne bloque que sur l'irréversible au lieu de noyer l'opérateur sous un interrogatoire.

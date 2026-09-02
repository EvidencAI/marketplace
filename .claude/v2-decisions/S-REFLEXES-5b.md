# STORY S-REFLEXES-5b (volet marketplace) — carte_age_jours, reflexes, question_humain

Périmètre : `plugins/mycelora/hooks/mycelora-common.sh`, `mycelora-pretooluse.sh`,
`mycelora-stop.sh`. Contrat serveur figé (dépôt `mnemos-edge`, non modifié
ici) : `reflexes[]` envoyé à `mnemos_log_exchange` porte
`{ t, evt, outil, objets, empreinte, rapport_vide, carte_age_jours?,
question_humain? }`.

## 1. `carte_age_jours` — calcul dans `mycelora_reflexe_construire_rapport`

Le brief donnait déjà l'algorithme complet (candidat par objet, MAX,
priorité absolue de l'échec de lookup) ; je l'ai implémenté tel quel après
vérification par les tests, sans écart. Résumé de la logique retenue,
implémentée dans la boucle `for o in objets:` de
`mycelora_reflexe_construire_rapport` :

- **Priorité absolue à l'échec réel du lookup serveur**
  (`lookup_evt in ("lookup_timeout", "lookup_erreur")`) : `carte_age_jours`
  vaut `None` (donc absent du JSONL, cf. §2) même si un objet du même
  rapport a par ailleurs été résolu localement (candidat 0 ignoré dans ce
  cas). Raison : ce champ nourrit la métrique serveur "combien de refus sont
  fondés sur une carte périmée" — un lookup qui a réellement échoué ne dit
  RIEN sur l'âge de la carte, mélanger ce cas avec "carte fraîche via grep
  local" fausserait la métrique dans le sens le plus trompeur (ferait
  paraître périmé un refus qui ne doit rien à la carte).
- Sinon, un **candidat d'âge par objet** est collecté au fil de la boucle
  déjà existante (celle qui construit le texte du rapport) :
  - objet résolu par **grep local** (`lu_par`/`ecrit_par` non vides) →
    candidat `0` (fraîcheur immédiate, le grep vient d'être exécuté) ;
  - objet résolu par la **carte serveur** avec `genere_le` connu → candidat
    `age_jours(genere_le)` (fonction déjà existante, inchangée) ;
  - objet inconnu / carte vide / non résolu → **aucun candidat**, mais ne
    force pas l'absence globale s'il existe par ailleurs un objet résolu
    dans le même rapport (un `N objets` avec un seul résolu doit quand même
    remonter l'âge de celui-là).
  - résultat : le **MAXIMUM** des candidats collectés — le plus défavorable.
    Un rapport qui mélange un objet frais (grep local, 0) et un objet vu
    seulement via une carte vieille de 7 jours est aussi fiable que sa PIRE
    source, pas sa meilleure ; prendre le max plutôt que la moyenne ou le
    premier objet évite de masquer une carte périmée derrière un objet
    accessoire résolu localement.
  - aucun candidat collecté (rapport entièrement construit sur de l'inconnu,
    sans échec de lookup — ex. carte jamais indexée pour l'espace) →
    `None`.
- **Cas `geste == "infra"`** : la branche infra de `mycelora-pretooluse.sh`
  construit son texte directement (pas d'appel à
  `mycelora_reflexe_construire_rapport`), donc `META_FILE` n'existe même
  pas — `CARTE_AGE_JOURS` reste `""` (initialisée avant le `if`), lue comme
  absente. Aucun code dédié n'a été nécessaire : c'est une conséquence
  directe de la structure déjà en place (aucune carte n'est consultée pour
  un geste infra), pas un cas spécial ajouté.

Aucun écart constaté à l'usage entre l'algorithme donné dans le brief et ce
qui s'est avéré nécessaire pour faire passer les tests : les 4 cas
(local seul, serveur seul, mélange, échec de lookup) et le cas infra sont
couverts sans ambiguïté par cette seule règle.

## 2. `mycelora_reflexe_log` — 7e paramètre optionnel

`carte_age_jours` en 7e argument, chaîne vide = absent. Écriture de la clé
JSON **seulement** si `carte_age_jours.strip().isdigit()` — jamais une clé à
`null`, jamais une chaîne vide, exactement la même discipline que `tools.ts`
côté serveur pour ce même champ (le brief l'imposait explicitement). Les
appels `desarme`/`passage`/`lookup_timeout`/`lookup_erreur`/`rapport_vide`
dans `mycelora-pretooluse.sh` restent à 6 arguments : seul l'événement
`refus` porte ce champ, cohérent avec le fait que c'est la ligne `evt =
'refus'` que filtre la métrique serveur.

## 3. `mycelora-stop.sh` — `question_humain`

Les deux signaux (présence de `.cc-attente-decision.md` **directement** dans
le `cwd` reçu sur stdin, sans recherche récursive ; présence d'un `?` dans
`last_assistant_message` du tour, simple présence de caractère, aucune
analyse NLP) sont exactement ceux actés à l'audit (voir
`S-REFLEXES-AUDIT-REPONSES.md`, repris tels quels dans le brief). Aucun
écart. Point d'implémentation à noter : le signal (a) utilise le `cwd` du
JSON reçu sur stdin du hook Stop, distinct du `REPO_ROOT` résolu par
`mycelora_repo_root` dans le réflexe d'impact (PreToolUse/PostToolUse) — les
deux notions coexistent dans des hooks différents, ne pas les confondre en
maintenance future.

La fusion `question_humain: true` ne touche que la ligne du lot local ayant
le plus grand `t` parmi celles à `evt == "refus"` (`max(refus_entries,
key=lambda e: e.get("t") or "")` en Python — tri lexicographique valide car
le format `%Y-%m-%dT%H:%M:%SZ` est ordonné comme la date qu'il représente).
Aucune ligne n'est créée si le lot ne contient aucun `refus` : le filtre sur
`evt` a lieu AVANT le calcul du max, jamais un fallback sur "la ligne la
plus récente du lot tout court".

## 4. Purge du journal local des reflexes

Copie conforme du patron déjà en place pour `ACK_FILE`/`ackLotIds`
(S-ACK-1) : purge uniquement dans la branche `2??` du `case "$HTTP_CODE"`,
après un appel curl qui a réellement abouti (`CURL_RC -eq 0`). Sur timeout
(`CURL_RC != 0`) ou code HTTP non-2xx, le fichier reste en place et sera
rejoué au Stop suivant du même fil — même sémantique, mêmes garanties de
non-perte.

## 5. Tests — contre-épreuve par mutation (DoD)

Règle vérifiée : "objet résolu par grep local → candidat d'âge 0."
Mutation appliquée manuellement le 02/09/2026 sur
`mycelora_reflexe_construire_rapport` (`candidats_age.append(0)` →
`candidats_age.append(1)`), suite relancée : exactement 1 test échoue,
`reflexe-carte-age-jours-local-seul-zero` (90/91 au lieu de 91/91, verdict
observé `1` au lieu de `0`) — la mutation est bien détectée par ce test
précis et par lui seul. Mutation revertie aussitôt après vérification
(`diff` confirmé vide contre la sauvegarde), suite complète re-vérifiée
verte (91/91). Aucune trace de la mutation dans le code final.

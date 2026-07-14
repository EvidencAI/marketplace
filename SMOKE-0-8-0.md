# Checklist smoke — plugin Mnemos 0.8.0

Sprint MNEMOS-V3-INJECTION, story S4 (phase 4 du brief sprint). À exécuter par
Stéphane à la main, sur un fil Cowork neuf. Ne remplace pas les tests
automatisés (déjà verts), sert à valider le comportement réel du watcher v3
une fois le zip installé.

## Étape 0 : installation

1. Dans Claude Desktop, supprimer le plugin Mnemos existant (version
   0.7.3-test).
2. Installer `plugin-mnemos0.8.0.zip` (dans `MNEMOS 07 26/plugin/`).
3. Redémarrer Claude Desktop si nécessaire.
4. Ouvrir un fil Cowork neuf (le plugin ne se charge pas dans un fil déjà
   ouvert).

## Vérification 1 : FACE-A à chaque message

- Envoyer un premier message quelconque : un bloc de rappel contextuel
  (FACE-A) doit être visible dès ce premier tour, avant la réponse.
- Envoyer 2 ou 3 messages supplémentaires : le bloc doit réapparaître à
  chaque tour.
- Noter la latence perçue avant la réponse : doit rester acceptable (pas de
  blocage visible de plusieurs secondes).

## Vérification 2 : collecte automatique (raw_exchanges → atomes)

- Après au moins 3 échanges dans ce fil, attendre environ 10 minutes.
- Vérifier en base que les lignes `raw_exchanges` correspondant à ce fil sont
  bien présentes avec `processed=true`.
- Vérifier que des atomes sont apparus dans `auto_buffer`, dans le bon
  espace (celui du fil de test).

## Vérification 3 : santé générale

- Appeler `get_stats` : le total attendu est d'environ 10,3k (ordre de
  grandeur, pas une valeur exacte).
- Appeler `health_check` : doit revenir propre, sans erreur.

## Vérification 4 : rollback

- Confirmer que le zip de la version précédente (0.7.1) est toujours
  disponible en local, au cas où il faudrait revenir en arrière.
- Confirmer que le jeton hook de la version 0.8.0 peut être révoqué seul,
  sans impact sur les autres clés (Supabase, Anthropic, Voyage) ni sur les
  autres installations.

## En cas d'anomalie

Noter le point de blocage précis (quelle vérification, quel comportement
observé) avant de rouvrir la story ou d'en ouvrir une nouvelle. Ne pas
tenter de corriger les scripts hooks depuis ce fil de test : cela reste hors
scope de la story S4.

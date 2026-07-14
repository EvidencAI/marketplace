# FIX S3 — relecture croisée Cowork du 14/07/2026 (3 correctifs + 1 optionnel)

Relecture indépendante de la PR #1 effectuée depuis un fil cloud réel, avec
vérifications sur le transcript JSONL vivant et sur le code edge. Appliquez
les correctifs ci-dessous sur feat/s3-hooks-watcher-v3, re-testez, committez
et poussez sur la même branche (PR #1 mise à jour, toujours pas de merge).

## 1. MAJEUR — mnemos-stop.sh, find_last_user : quasi toute la collecte réelle est perdue

Constat vérifié sur le transcript réel d'un fil Cowork en cours : 106 entrées
type=user sur 117 ont un message.content en LISTE (tool_result), pas en
string. Dès qu'un tour utilise des outils (la quasi-totalité des tours
Cowork), la DERNIÈRE entrée user du transcript au moment du Stop est un
tool_result : votre logique actuelle rend MISSING, retry, MISSING, et
l'échange est jeté. Verdict reproduit à l'instant sur fil vivant. Votre
fixture de test se terminait par un message user string, d'où les tests
verts à tort.

Correctif attendu :
- Sélectionner le dernier VRAI message humain : la dernière entrée
  type=user dont message.content est une string (on REMONTE l'historique en
  ignorant les entrées à content liste, contrairement au commentaire actuel).
- Mieux : le stdin du Stop fournit prompt_id. Si présent, préférer l'entrée
  type=user dont promptId == prompt_id ET dont content est une string
  (les tool_result du même tour partagent ce promptId, le critère string
  reste indispensable). Fallback : dernière entrée user à content string.
- Mettre à jour la fixture pour refléter le cas réel (message user string
  SUIVI de plusieurs entrées tool_result) et ajouter un test qui échouait
  avec l'ancienne logique.

## 2. MOYEN — mnemos-userpromptsubmit.sh : les erreurs edge seraient injectées dans le contexte

L'edge renvoie les erreurs d'exécution d'outil en HTTP 200 avec
result.content[0].text = message d'erreur et result.isError = true
(tools.ts, bloc catch lignes ~1002-1012). Votre extraction recopie
content[0].text sans regarder isError : en cas de panne edge, quota Voyage
épuisé, etc., le texte d'erreur serait injecté dans le contexte du modèle à
chaque tour, ce que Q10 interdit explicitement (fail silencieux).

Correctif attendu : si result.isError est vrai, sortie vide et log
"tool-error". Test unitaire avec une fixture de réponse isError:true.

## 3. MOYEN — filtres : les réveils programmés ne sont PAS marqués au niveau hook

Vérifié en réel le 14/07 sur un wakeup send_later : le préfixe
"[SYSTEM NOTIFICATION - NOT USER INPUT]" n'apparaît NI dans le champ prompt
du stdin UserPromptSubmit, NI dans l'entrée user du transcript. Ce préfixe
n'existe qu'au niveau de la conversation du modèle. L'hypothèse Q4 du 10/07
ne tient pas au niveau des hooks pour ces flux : aujourd'hui un réveil
programmé déclenche un recall parasite et serait archivé comme un échange
humain.

Décision Stéphane (14/07) : filtrer par motif interne. Correctif attendu :
- Ajouter aux filtres des DEUX hooks (recall et archivage) le motif :
  prompt/message user commençant par "Rappel interne :" (préfixe
  conventionnel de nos automatismes internes).
- Conserver tels quels les motifs existants ([SYSTEM NOTIFICATION...],
  <task-notification>) : ils ne coûtent rien et couvrent d'éventuels flux
  qui les porteraient.
- Documenter la limite en commentaire : un wakeup au libellé libre passera
  les filtres, c'est assumé.

## 4. MINEUR optionnel — plafonner la query du recall

Un très long prompt (collage de document) part entier vers l'embedding.
Tronquer la query à 2000 caractères avant l'appel mnemos_recall. Si vous
voyez une contre-indication à la lecture du code edge, signalez-la au lieu
d'appliquer.

## Après correctifs

Tests unitaires et d'intégration re-passés (signalez tout dépôt smoke-s3-*),
re-build du zip de test puis suppression, commit(s) et push sur la même
branche, commentaire de synthèse sur la PR #1. Pas de merge.

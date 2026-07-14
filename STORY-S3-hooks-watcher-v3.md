# STORY S3 — Scripts hooks réels du watcher v3 (plugin mnemos)

Sprint MNEMOS-V3-INJECTION, story 3/5. Rédigé le 14/07/2026 (fil Cowork S3).
Repo de travail : evidencai-marketplace (CE repo). Branche : feat/s3-hooks-watcher-v3.
Contexte amont : S1 et S2 livrées en prod (edge mnemos-mcp). Décisions Q1-Q11
toutes tranchées, AUCUN re-audit à faire. Vous attaquez le code directement.

## Contexte

La MAJ Anthropic du 08/07 a tué le watcher local. Le fil du 10/07 a prouvé que
les hooks embarqués dans un plugin Cowork (hooks/hooks.json + scripts) sont
synchronisés et exécutés dans la VM cloud de chaque fil : UserPromptSubmit à
chaque message utilisateur, Stop en fin de tour. Seule sortie qui atteint le
modèle : stdout TEXTE BRUT (le JSON additionalContext racine est ignoré, prouvé).
L'edge est prête : outil mnemos_recall (bloc FACE-A formaté en texte brut) et
mnemos_log_exchange (INSERT réel dans raw_exchanges) sont en prod, accessibles
avec le jeton restreint MNEMOS_HOOK_KEY.

Cette story crée les VRAIS scripts hooks dans plugins/mnemos/hooks/, en
remplacement des hooks témoins 0.7.x (qui ne vivent PAS dans ce repo : rien à
supprimer ici, tout est à créer).

## Mesures empiriques du 14/07 (faites en fil cloud réel, à respecter)

1. Le moteur Cowork honore le timeout déclaré dans hooks.json : heartbeat tué
   entre 9 et 10 s pour timeout:10. Une modification de hooks.json en cours de
   fil n'est PAS relue. Budget total de chaque script : < 5 s, curl --max-time 3.
2. Transcript à jour à t+0 au Stop : le dernier message user ET le dernier
   message assistant sont déjà dans le JSONL quand le hook démarre. Le retry
   est un simple filet de sécurité.
3. Le stdin du Stop contient last_assistant_message COMPLET, plus
   effort, background_tasks, session_crons, stop_hook_active.
4. Les retours d'outils et les réponses aux questionnaires ne déclenchent PAS
   UserPromptSubmit : seuls les vrais messages utilisateur comptent.
5. Le spaceId capturé dans le tool_use mnemos_session_start peut être un NOM
   ("Développement Mnemos") ou un UUID : l'envoyer TEL QUEL, l'edge résout les
   deux (lib/resolve-space.ts).
6. python3 est présent dans la VM cloud (vérifié). jq n'est PAS garanti :
   ne pas en dépendre.

## Objectif et DoD

Créer plugins/mnemos/hooks/ (hooks.json + 2 scripts) et le script de build du
zip avec injection du jeton. DoD chiffrée :
- Tests unitaires verts (filtrage, parsing spaceId, reconstitution échange).
- Tests d'intégration réels contre l'edge : recall renvoie un bloc FACE-A non
  vide ; log_exchange dépose une ligne raw_exchanges ; outil interdit avec le
  jeton hook = 403 ; sans réseau = exit 0 silencieux, sortie vide.
- Aucun secret en clair dans le repo, les logs ou vos messages.
- git grep du placeholder confirme qu'il ne reste que dans les sources prévues.

## Source de vérité edge (LECTURE SEULE)

Le code de l'edge est dans /Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/edge-function
(repo mnemos-edge, branches feat/s1-* et feat/s2-* empilées, non mergées).
Lisez-y la signature EXACTE de mnemos_recall et mnemos_log_exchange (noms
d'arguments, forme de la réponse JSON-RPC, schéma attendu de exchanges[])
AVANT d'écrire les curl. Ne devinez RIEN de l'interface edge. Vous ne modifiez
AUCUN fichier de ce dossier.

Le jeton vit dans /Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/HOOK-KEY.txt.
Vous pouvez le LIRE pour les tests d'intégration. INTERDIT de l'afficher dans
un message, un log, un commit ou un nom de fichier. URL de l'edge : celle du
connecteur, visible dans le code edge ou CONNECTEUR-URL.txt (même dossier) —
n'affichez jamais la query string complète avec api_key.

## Décisions applicables (tranchées le 10/07, dossier MNEMOS 07 26)

- Q1 : le jeton hook voyage dans le ZIP, pas dans le repo git. Les scripts
  committés portent le placeholder __MNEMOS_HOOK_KEY__ ; build-plugin-zip.sh
  l'injecte au packaging (décision Cowork 14/07, voir section Build).
- Q2 : appel JSON-RPC tools/call de l'outil mnemos_recall, le corps renvoyé
  est le bloc FACE-A déjà formaté, le script le recopie tel quel sur stdout.
- Q3 : parsing JSONL (dernier tool_use mnemos_session_start → input.spaceId)
  + cache fichier /tmp/mnemos-hook-<session_id>.json. Fallback : AUCUN spaceId
  envoyé, l'edge applique son défaut (Non affecté).
- Q4 : filtres recall (skip silencieux) : longueur < 10 après trim ; préfixes
  <uploaded_files>, <system-reminder>, "This session is being continued",
  "[SYSTEM NOTIFICATION - NOT USER INPUT]" ; contenu incluant <task-notification>.
  Pas de dedup côté edge.
- Q5 : au Stop, last_assistant_message vient du stdin ; le dernier message user
  est relu dans transcript_path ; s'il manque, UN retry de 400 ms puis abandon
  silencieux. PAS de filtre de longueur au Stop (un "ok" est un échange valide).
- Q10 : exit 0 dans TOUS les chemins (trap compris), échec réseau/edge/quota =
  sortie vide silencieuse, log local /tmp/mnemos-hook.log (une ligne par
  invocation : timestamp, event, durée ms, statut, taille réponse), troncature
  du log au-delà de 1 Mo. Aucun log distant.

## Spécification des fichiers à créer

### plugins/mnemos/hooks/hooks.json

UserPromptSubmit → ${CLAUDE_PLUGIN_ROOT}/hooks/mnemos-userpromptsubmit.sh, timeout 10.
Stop (matcher "") → ${CLAUDE_PLUGIN_ROOT}/hooks/mnemos-stop.sh, timeout 10.
Même structure que le hooks.json témoin 0.7.3 (prouvée en prod).

### plugins/mnemos/hooks/mnemos-userpromptsubmit.sh

1. Lit stdin (JSON : prompt, session_id, transcript_path, ...). Parsing via
   python3 (pas de jq).
2. Applique les filtres Q4. Si filtré : log + exit 0, AUCUNE sortie.
3. Résout le spaceId : cache /tmp/mnemos-hook-<session_id>.json s'il existe,
   sinon parse transcript_path (dernier tool_use dont le nom se termine par
   mnemos_session_start → input.spaceId, nom ou UUID tel quel) puis écrit le
   cache. Attention : les lignes JSONL peuvent être longues, parser ligne à
   ligne sans charger tout le fichier si simple à faire, sinon rester pragmatique.
4. curl JSON-RPC tools/call mnemos_recall (userId "stephane", query = le prompt,
   spaceId si connu), auth via __MNEMOS_HOOK_KEY__, --max-time 3.
5. Réponse 2xx non vide : recopier le TEXTE du bloc FACE-A tel quel sur stdout
   (extraire le champ texte de la réponse JSON-RPC selon la forme réelle lue
   dans le code edge). Sinon : rien. exit 0 partout.

### plugins/mnemos/hooks/mnemos-stop.sh

1. Lit stdin : last_assistant_message, transcript_path, session_id.
2. Retrouve le dernier message USER réel dans transcript_path : entrées
   type=user dont le contenu est du texte (les tool_result et messages meta ne
   comptent pas — vérifiez la structure exacte sur les fixtures fournies).
   Absent : UN retry 400 ms, puis abandon silencieux exit 0.
3. Applique au message user les motifs SYSTÈME de Q4 uniquement
   ([SYSTEM NOTIFICATION...], <task-notification>) : un échange déclenché par
   une notification n'est pas un échange utilisateur, on ne l'archive pas.
   PAS de filtre de longueur (décision Q5). Si ce choix vous semble faux à la
   lecture du code edge, signalez-le dans votre résumé au lieu de dévier.
4. spaceId : même cache/parsing que l'autre script (factorisez si propre).
5. curl mnemos_log_exchange (schéma exact lu dans le code edge), fire and
   forget, --max-time 3, AUCUNE sortie stdout, exit 0 partout.

### scripts/build-plugin-zip.sh (racine du repo)

1. Arguments : version (ex 0.8.0-test) ; chemin du jeton (défaut
   /Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/HOOK-KEY.txt).
2. Copie plugins/mnemos vers un dossier temporaire, remplace
   __MNEMOS_HOOK_KEY__ dans les scripts hooks par le contenu du fichier jeton
   (trim), zippe avec une liste EXPLICITE de fichiers (jamais de .git,
   .DS_Store, fichier de test), sortie dans
   /Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/plugin/plugin-mnemos<version>.zip.
3. Garde-fous bloquants : jeton vide ou introuvable = abort ; placeholder
   résiduel dans le zip = abort ; HOOK-KEY.txt présent dans le zip = abort.
   Le script n'affiche JAMAIS le jeton.
4. Ce script ne bump PAS plugin.json (c'est S4). Il doit juste permettre de
   fabriquer un zip de test fonctionnel.

## Phase tests (dans le repo, plugins/mnemos/hooks/tests/ ou tests/)

Unitaires (sans réseau, exécutables sur le Mac) :
- filtrage Q4 : les fixtures réelles de l'annexe + cas synthétiques (court,
  uploaded_files, system-reminder, continued, SYSTEM NOTIFICATION,
  task-notification) ;
- parsing spaceId sur une fixture JSONL contenant un tool_use
  mnemos_session_start réel ;
- reconstitution de l'échange au Stop sur la même fixture ;
- vérification que les scripts committés contiennent bien le placeholder.

Intégration (réseau, jeton réel lu depuis HOOK-KEY.txt, jamais affiché) :
- recall réel : bloc FACE-A non vide ;
- log_exchange réel : dépôt accepté (sessionId préfixé smoke-s3-) ;
- outil interdit (ex mnemos_update_profile) avec le jeton hook : rejet ;
- curl vers un port fermé : exit 0, sortie vide, tour non bloqué.
Le dépôt de test écrit dans la base de PROD (raw_exchanges) : autorisé, mais
signalez chaque dépôt dans votre résumé (sessionId utilisé).

## Hors scope (ne pas toucher)

- SKILL.md, plugin.json (version), commands/ : c'est S4.
- Le zip final 0.8.0 et son upload : S4.
- Tout fichier de MNEMOS 07 26/edge-function (lecture seule).
- extract-from-exchanges et tout ce qui est aval : ça marche, on n'y touche pas.
- Les instructions globales Cowork de Stéphane : S5.

## Pièges à éviter

1. Sortie hook = TEXTE BRUT stdout uniquement. Aucun JSON en sortie.
2. exit 0 dans TOUS les chemins, y compris erreur de parsing python3.
3. Jamais le jeton ni l'api_key en clair dans un log, un message, un commit.
4. jq non garanti en VM cloud : python3 uniquement.
5. Branche feat/s3-hooks-watcher-v3, PR ouverte NON mergée. Si la branche
   courante n'est pas celle attendue, NE PAS reset : signalez et proposez le
   checkout correct.
6. Ne lancez JAMAIS de commande tmux (boucle du 10/07).
7. VOUVOIEMENT dans tous vos messages, pas de tiret long.
8. Avant tout geste qui touche la prod au-delà des dépôts de test décrits
   ci-dessus : message court "je m'apprête à X via Y, OK ?" et ATTENTE de
   validation.

## Annexe — fixtures réelles (fil cloud du 14/07/2026)

stdin UserPromptSubmit (vrai payload, prompt utilisateur normal) :
{"session_id":"726ec160-e1f5-5bd0-b3e7-3de9785ea2be","transcript_path":"/root/.claude/projects/-home-claude/726ec160-e1f5-5bd0-b3e7-3de9785ea2be.jsonl","cwd":"/home/claude","prompt_id":"daa83436-ac05-41b8-890b-2e2769ad9ce5","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"salut claude, lis /Users/stephanecommenge/Downloads/PROMPT-FIL-S3-WATCHER-V3.md"}

stdin Stop (vrai payload, tronqué au champ last_assistant_message) :
{"session_id":"726ec160-e1f5-5bd0-b3e7-3de9785ea2be","transcript_path":"/root/.claude/projects/-home-claude/726ec160-e1f5-5bd0-b3e7-3de9785ea2be.jsonl","cwd":"/home/claude","prompt_id":"67128ddd-4af5-4069-902c-42043a237e6f","permission_mode":"default","effort":{"level":"high"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"...texte complet du dernier message assistant...","background_tasks":[],"session_crons":[]}

tool_use mnemos_session_start tel qu'il apparaît dans le JSONL (champ input) :
{"userId": "stephane", "sessionId": "cowork-2026-07-14-sprint-v3-s3-watcher", "spaceId": "Développement Mnemos"}

Motifs système confirmés sur échantillons réels du 10/07 :
- préfixe "[SYSTEM NOTIFICATION - NOT USER INPUT]" (notifications de tâches ET wakeups)
- balise <task-notification> dans le contenu

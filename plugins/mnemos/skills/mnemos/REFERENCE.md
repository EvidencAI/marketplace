# Mnemos — Référence technique

Ce document est consulté à la demande, PAS à chaque tour. Le LLM le lit uniquement quand il a besoin d'un détail technique, en cas d'erreur, ou sur demande explicite de l'utilisateur.

---

## Configuration par utilisateur

Mnemos est multi-utilisateur. Chaque installation nécessite :

| Variable | Source | Exemple (Stéphane) |
|----------|--------|---------------------|
| USER_ALIAS | userId pour les outils MCP Mode A | "stephane" |
| USER_UUID | userId pour les curls Mode B | 2ba47612-aa7d-45ef-b9a9-295d039e5f82 |
| SUPABASE_PROJECT_REF | Référence projet Supabase | hpbsowihyydzdnxuzoxs |
| SUPABASE_SERVICE_ROLE_KEY | Env var dans claude_desktop_config.json | (ne pas écrire ici) |

Où trouver ces valeurs :
- claude_desktop_config.json → section mcpServers.mnemos.env
- `mnemos_get_profile(userId:USER_ALIAS)` → principes, portrait, instructions

Premier setup : voir ONBOARDING.md.

---

## 10 types d'atomes (heuristique de typage)

| Type | Decay | Déclencheurs typiques |
|------|-------|----------------------|
| decision | 180j | "on part sur X", "décidé que" |
| position | 180j | "je pense que", "notre position est" |
| fact | 90j | fait vérifiable, info technique |
| contradiction | 90j | "d'un côté... de l'autre", tension |
| apprentissage | 90j | "j'ai appris que", "erreur: ne plus faire X" |
| signal_externe | 60j | feedback, article, "on m'a dit que" |
| reflexion | 60j | "je me demande si", question ouverte |
| intention | 30j | "je vais", "prochaine étape" |
| event | 30j | événement daté, "hier", "le 15 mars" |
| contact | 365j | personne, relation, "Jean-Marc est le DG" |

Ne PAS mapper mécaniquement. Analyser le contenu. En cas de doute, préférer le type avec la demi-vie la plus longue.

---

## Outils MCP (référence rapide)

35 outils exposés au LLM, regroupés par domaine :

**Auth** (4) : login, signup, logout, whoami
**Espaces** (3) : list_spaces, create_space, update_space
**Atomes** (4) : search_atoms, create_atom_manual, update_atom, toggle_pin_atom
**Contexte** (1) : get_context (6 modes : auto, onboard, recall, briefing, morning, explore)
**Admin** (1) : admin (actions : get_stats, triage_atoms, garbage_collect, health_check)
**Sessions** (2) : session_start, session_end
**Mémoire** (2) : write_memory, read_memory
**Profil** (2) : get_profile, update_profile
**Contacts** (2) : upsert_contact, search_contacts
**Ingestion** (3) : ingest_document, ingest_events, process_events
**Insights** (2) : cross_insights, analyze_space
**Documents** (1) : list_documents
**Connexions** (1) : create_connection
**Extraction** (2) : log_exchange, extract_atoms (aussi utilisés automatiquement par le transcript-watcher)
**Sync** (1) : sync_status

Note : log_exchange et extract_atoms sont appelés automatiquement par le transcript-watcher. Le LLM n'a pas besoin de les appeler en routine, mais ils sont disponibles si nécessaire (debug, extraction manuelle).
Note : get_stats, health_check, triage_atoms, garbage_collect ne sont PAS des outils standalone. Ils s'appellent via `mnemos_admin(action:"nom_action")`.

Note spaceId : Mode A accepte le **nom**. Mode B exige le **UUID**.

---

## get_context — 6 modes

| Mode | Atomes | Usage |
|------|--------|-------|
| auto | variable | Défaut, adaptatif |
| onboard | 25 | Ouverture de fil |
| recall | 8 | Rappel ponctuel |
| briefing | 15 | Résumé projet |
| morning | complet | Brief matinal (insights + mails + RDV) |
| explore | 20 | Brainstorm, exploration |

---

## Hygiène mémoire (détail technique)

### Déduplication automatique (v0.4.1)
Tous les chemins d'insertion (extract_atoms, create_atom_manual, ingest_document, extractAtomsFromBuffer) vérifient les doublons AVANT insertion via vector_score (cosine).
Paliers : >= 0.90 skip (garder le plus long), 0.80-0.90 classification Haiku (DOUBLON/SUPERSEDE/DISTINCT).

### Supersession temporelle (v0.4.1)
Quand un atome rend un précédent obsolète (ex: "problème X" → "problème X résolu") :
1. **Convention agent** (prioritaire) : search_atoms → update_atom(active:false) → create_connection(type:"précède"). Le LLM DOIT suivre ce pattern.
2. **Extraction prompt** : Haiku peut renseigner `supersedes` pour archiver automatiquement.
3. **Filet dedup/GC** : garbage_collect v2 pgvector détecte les paires similaires (>=0.85) côté SQL.
Note : le cosine est inadapté pour détecter la supersession (vocabulaire opposé = score bas). La couche 1 est la plus fiable.

### garbage_collect (pg_cron dimanche 5h FR)
GC v2 pgvector : calculs de similarité côté PostgreSQL. 3 étapes : lifecycle insights, archivage obsolètes, déduplication (>=0.95 fusion auto, 0.85-0.95 rapport). Consolidation orphelins par espace. Fonctions SQL : `find_duplicate_atoms`, `find_orphan_atoms`, `find_orphan_pairs_by_space`.

### health_check (pg_cron quotidien 5h UTC)
Edge Function health-cron. Génère embeddings manquants, reconnecte orphelins, purge connexions obsolètes. Aussi appelable manuellement : `mnemos_admin(action:"health_check", userId:USER_ALIAS, repair:true)`.

---

## Gestion des erreurs

1. Mode A échoue → retenter une fois. Échec persistant → basculer Mode B (voir FALLBACK-MODE-B.md).
2. Mode B échoue → "L'accès mémoire est indisponible. Je continue sans, session non sauvegardée."
3. Ni A ni B → travailler sans mémoire, le signaler clairement.
4. Ne JAMAIS ignorer un échec d'écriture (handover, mémoire, atome). Toujours prévenir l'utilisateur.
5. Clôture échouée → copier handover/mémoire dans le chat pour sauvegarde manuelle.

---

## Architecture technique

Trois couches de code, une seule base Supabase :
- **Source** (vérité) : répertoire local du développeur, dossier mcp-server/src/ (TypeScript)
- **Bundle** (actif) : ~/mnemos-mcp/index.cjs (fichier unique CJS, ~3.2 MB, inclut transcript-watcher)
- **Config** : claude_desktop_config.json (macOS: ~/Library/Application Support/Claude/ · Windows: %APPDATA%\Claude\ · Linux: ~/.config/claude/)
- **Distribution** : plugin Cowork (~16 Ko, skills only) + bundle via Supabase Storage (install.sh)
- **Dashboard** : https://mnemos.evidencai.com (Vercel)
- **Supabase** : pgvector, Voyage AI voyage-3-lite 512 dim, Haiku extraction
- **Edge Function** : https://SUPABASE_PROJECT_REF.supabase.co/functions/v1/mnemos-mcp
- **Transcript-watcher** : intégré au bundle, parse les sessions Cowork, extrait les atomes automatiquement. Standalone supprimé (26/03/2026).

### Build process
```
npx tsc
npx esbuild dist/index.js --bundle --format=cjs --platform=node --target=node18 --outfile=bundle/index.cjs --keep-names
# macOS/Linux :
cp bundle/index.cjs ~/mnemos-mcp/index.cjs
# Windows : copy bundle\index.cjs %USERPROFILE%\mnemos-mcp\index.cjs
```

### Distribution (install.sh)
L'utilisateur installe le plugin Cowork (skills only, ~16 Ko) puis lance :
```
curl -sL "https://SUPABASE_PROJECT_REF.supabase.co/storage/v1/object/public/mnemos-releases/install.sh" | bash
```
Le script télécharge le bundle dans ~/mnemos-mcp/ et injecte la config dans claude_desktop_config.json.
Zéro secrets côté client. La service_role_key est injectée par install.sh depuis Supabase Storage (accès authentifié).

# Mycelora — Référence technique

Ce document est consulté à la demande, PAS à chaque tour. Le LLM le lit uniquement quand il a besoin d'un détail technique, en cas d'erreur, ou sur demande explicite de l'utilisateur.

---

## Configuration par utilisateur

Mycelora est multi-utilisateur. Deux canaux vivants donnent accès à la mémoire (détail complet : install.md) :

| Canal | Ce qu'il faut à l'utilisateur | Où |
|-------|-------------------------------|-----|
| Plugin Cowork (marketplace EvidencAI) | Jeton hook, embarqué automatiquement dans le zip du plugin par `scripts/build-plugin-zip.sh` — rien à configurer manuellement | — |
| Connecteur Mycelora (claude.ai / Claude Desktop) | OAuth via le connecteur, ou clé API `mk_live_...` | Dashboard https://mycelora.ai |

Un utilisateur du plugin n'a jamais besoin d'une clé service_role Supabase : ce niveau d'accès reste interne à l'infrastructure EvidencAI.

| Variable | Description | Exemple (Stéphane) |
|----------|--------------|---------------------|
| USER_ALIAS | Identifiant court passé en `userId` aux outils MCP `mnemos_*` | "stephane" |
| SUPABASE_PROJECT_REF | Référence projet Supabase | hpbsowihyydzdnxuzoxs |

- `mnemos_get_profile(userId:USER_ALIAS)` → principes, portrait, instructions

Premier setup : voir ONBOARDING.md.

Dette technique (mono-tenant) : dans ce déploiement, toute valeur de `userId` qui n'est pas un UUID valide est silencieusement remplacée par l'utilisateur unique configuré côté serveur (filet de sécurité mono-tenant, pas une résolution d'alias par nom comme pour les espaces). Ce n'est pas un défaut à corriger maintenant, mais si Mycelora devient multi-utilisateur un jour, ce mécanisme devra être revu AVANT : sinon un `userId` mal formé de n'importe quel appelant finirait associé au mauvais compte.

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

48 outils exposés au LLM, regroupés par domaine :

**Espaces** (4) : list_spaces, create_space, update_space, suggest_spaces
**Atomes** (4) : search_atoms, create_atom_manual, update_atom, toggle_pin_atom
**Contexte** (2) : get_context (5 modes : auto, onboard, recall, briefing, explore), recall (rappel FACE-A automatique, hook UserPromptSubmit)
**Maintenance** (4) : get_stats, health_check, triage_atoms, garbage_collect
**Sessions** (2) : session_start, session_end
**Mémoire** (2) : write_memory, read_memory
**Profil** (3) : get_profile, update_profile, get_calibration
**Contacts** (2) : upsert_contact, search_contacts
**Ingestion** (4) : ingest_document, ingest_events, process_events, collect_events (collecte cloud automatique mail/agenda, S7, voir § Collecte cloud)
**Sources** (4) : create_source, disconnect_source, test_source_connection, google_consent_url
**Clés API** (3) : create_api_key, list_api_keys, revoke_api_key
**Insights & tensions** (5) : cross_insights, analyze_space, ack_tension, close_topic, reopen_topic
**Documents** (1) : list_documents
**Connexions** (1) : create_connection
**Extraction** (2) : log_exchange, extract_atoms (aussi utilisés automatiquement par le transcript-watcher)
**Sync** (1) : sync_status
**Export** (2) : export_memory, export_status
**Feedback** (1) : submit_feedback
**Compte** (1) : delete_account

Note : log_exchange et extract_atoms sont appelés automatiquement par les hooks du watcher v3 (UserPromptSubmit/Stop). Le LLM n'a pas besoin de les appeler en routine, mais ils sont disponibles si nécessaire (debug, extraction manuelle).
Note : get_stats, health_check, triage_atoms, garbage_collect sont des outils standalone (`mnemos_get_stats`, `mnemos_health_check`, `mnemos_triage_atoms`, `mnemos_garbage_collect`). Il n'existe plus de dispatcher `mnemos_admin`.

Note spaceId : les outils MCP acceptent le **nom** de l'espace (résolution insensible à la casse) aussi bien que l'**UUID**.
Note read_memory/write_memory : acceptent désormais le **nom** d'espace (comme les autres outils avec résolution de nom), en plus de l'UUID.

---

## get_context — 5 modes

| Mode | Atomes | Usage |
|------|--------|-------|
| auto | variable | Défaut, adaptatif |
| onboard | 25 | Ouverture de fil |
| recall | 8 | Rappel ponctuel |
| briefing | 15 | Résumé projet |
| explore | 20 | Brainstorm, exploration |

---

## ingest_events — format des événements

Chaque élément du tableau `events` :

| Champ | Requis | Type | Exemple |
|-------|--------|------|---------|
| source | oui | string, valeurs contraintes (voir ci-dessous) | "gmail" |
| event_type | oui | string, valeurs contraintes (voir ci-dessous) | "mail_received" |
| event_id | oui | string | identifiant unique (dédup) |
| event_timestamp | oui | string ISO 8601 | "2026-07-14T09:00:00Z" |
| subject | non | string | — |
| body_preview | non | string | — |
| participants | non | array de strings | — |
| metadata | non | objet libre | — |

**Valeurs contraintes (CHECK en base, table `source_events`)** — toute autre valeur est rejetée silencieusement à l'insertion (comptée dans `errors`, pas d'exception) :
- `source` : `gmail`, `google_calendar`, `outlook`, `microsoft_calendar`, `imap_ovh`
- `event_type` : `mail_received`, `mail_sent`, `meeting_created`, `meeting_updated`, `meeting_cancelled`

En cas d'erreur d'insertion sur un ou plusieurs événements, la réponse inclut désormais un tableau `errorDetails` (`{event_id, message}` par événement en échec), en plus du compteur `errors`.

---

## Collecte cloud mail/agenda (S7)

Depuis le sprint S7, la collecte mail/agenda tourne côté serveur Mycelora,
sans aucun prérequis Mac ni Cowork ouvert. Deux connecteurs actifs :

- **Google Workspace** (`stephane@commenge.net`) : mail (4h glissantes,
  plafond de rattrapage 7j) + agenda (fenêtre ±5j), via OAuth 2.0. Refresh
  token chiffré dans Supabase Vault.
- **OVH IMAP** (`s.c@naturedeaux.com`) : mail seul (l'offre MXPLAN 25 ne
  propose pas de CalDAV). Client IMAP minimal (identifiants stables via
  UID), mot de passe d'application chiffré dans Supabase Vault.

Les deux comptes sont représentés dans une table `sources` (multi-compte,
observable : `last_sync_at`, `last_sync_status`, `consecutive_errors` par
source). Un seul job pg_cron (`mnemos-collect-google`, toutes les 2h,
appelle l'outil `mnemos_collect_events`) traite en réalité **toutes** les
sources actives, malgré son nom historique — il ne se limite pas à Google.

Aucun secret Google/OVH n'est stocké en clair : uniquement dans Supabase
Vault, référencé depuis `sources.vault_secret_id`.

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
Edge Function health-cron. Génère embeddings manquants, reconnecte orphelins, purge connexions obsolètes. Aussi appelable manuellement : `mnemos_health_check(userId:USER_ALIAS, repair:true)`.

---

## Gestion des erreurs

1. Un appel MCP `mnemos_*` échoue → retenter une fois. Échec persistant → vérifier que le canal (plugin Cowork ou connecteur Mycelora, voir install.md) est bien actif et authentifié.
2. Toujours indisponible → "L'accès mémoire est indisponible. Je continue sans, session non sauvegardée."
3. Ne JAMAIS ignorer un échec d'écriture (handover, mémoire, atome). Toujours prévenir l'utilisateur.
4. Clôture échouée → copier handover/mémoire dans le chat pour sauvegarde manuelle.

---

## Architecture technique

Une seule base Supabase, deux canaux d'accès vivants :
- **Source** (vérité) : répertoire local du développeur, dossier mcp-server/src/ (TypeScript)
- **Distribution** : plugin Cowork (~16 Ko, skills only, hooks automatiques) via le marketplace EvidencAI, et connecteur Mycelora distant (OAuth ou clé API `mk_live_...`) dans claude.ai / Claude Desktop
- **Dashboard** : https://mycelora.ai (Coolify)
- **Supabase** : pgvector, Voyage AI voyage-3-lite 512 dim, Haiku extraction
- **Edge Function** (serveur MCP distant) : https://api.mycelora.ai/functions/v1/mycelora-mcp
- **Transcript-watcher** : parse les sessions Cowork, extrait les atomes automatiquement. Standalone supprimé (26/03/2026).

### Canal local (bundle) retiré
Le canal d'installation locale (bundle CJS dans ~/mycelora-mcp/, build via `esbuild`, script install.sh servi depuis un bucket de stockage Supabase dédié — bucket aujourd'hui supprimé) a été retiré le 21/08/2026. Voir l'historique git pour la procédure précédente.

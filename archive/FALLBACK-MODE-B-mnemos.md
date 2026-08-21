# Mnemos — Mode B : Contournement HTTP direct (curl)

Ce fichier est la reference du Mode B (fallback quand les outils MCP natifs `mnemos_*` ne sont pas disponibles, c'est-a-dire quand le connecteur custom claude.ai "Mnemos" est absent du fil).

Mis a jour le 10/07/2026 (post-bascule connecteur HTTP + rotation des cles).
L'ancien Mode B (lecture de SUPABASE_SERVICE_ROLE_KEY dans claude_desktop_config.json) est OBSOLETE : ce fichier ne declare plus aucun serveur mnemos et la cle a ete rotee.

## Detection

Verifier si `mnemos_session_start` existe dans les outils disponibles. Si non → Mode B.
Reflexe prealable : signaler a l'utilisateur que le connecteur "Mnemos" n'est pas active sur ce fil (c'est la vraie correction ; le Mode B est un depannage).

## Bootstrap (obligatoire avant tout appel)

### Etape B1 — Recuperer le jeton edge (EDGE_FUNCTION_TOKEN)

Deux sources equivalentes, dans cet ordre :

1. **Via le Mac (pont Desktop Commander disponible)** : lire `/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/CONNECTEUR-URL.txt` et extraire la valeur du parametre `api_key` de l'URL. Ne jamais afficher le jeton en clair dans la conversation.
2. **Via la table secrets Supabase (si un acces service_role est deja disponible par ailleurs)** :
```
curl -s "https://hpbsowihyydzdnxuzoxs.supabase.co/rest/v1/secrets?project=eq.Mnemos&service=eq.edge_function&key_name=eq.bearer_token&select=key_value" \
  -H "apikey: [SERVICE_ROLE]" -H "Authorization: Bearer [SERVICE_ROLE]"
```
La cle service_role du Mac vit dans `/Users/stephanecommenge/.mnemos-supabase-key` (fichier local, chmod 600). Elle ne doit JAMAIS etre ecrite dans un fichier de plugin ni dans la conversation.

### Etape B2 — Template curl pour tous les appels

L'edge function accepte trois modes d'auth : `Authorization: Bearer [jeton]`, header `x-mnemos-key: [jeton]`, ou `?api_key=[jeton]` en query param.

```
curl -s -X POST "https://api.mycelora.ai/functions/v1/mycelora-mcp" \
  -H "Content-Type: application/json" -H "Authorization: Bearer [jeton B1]" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"TOOL_NAME","arguments":{"userId":"USER_UUID",...}},"id":1}'
```

Parsing : JSON-RPC → `result.content[0].text`. Timeout : 30s standard, 60s pour cross_insights/extract_atoms.

## Fallback REST direct (si Edge Function en panne)

Uniquement depuis le Mac (la service_role ne vit que la) :

```
curl -s "https://hpbsowihyydzdnxuzoxs.supabase.co/rest/v1/TABLE?FILTERS" \
  -H "apikey: [SERVICE_ROLE]" -H "Authorization: Bearer [SERVICE_ROLE]"
```

Tables utiles : spaces, memory_atoms, handovers, user_profiles, task_queue, secrets.

## Cloture Mode B — BUG CONNU

L'Edge Function `write_memory` ne remplit pas `summary` (NOT NULL). Contournement :

```
curl -s -X POST "https://hpbsowihyydzdnxuzoxs.supabase.co/rest/v1/handovers" \
  -H "apikey: [SERVICE_ROLE]" -H "Authorization: Bearer [SERVICE_ROLE]" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" \
  -d '{"user_id":"USER_UUID","space_id":"SPACE_UUID","summary":"VERSION_COURTE","content":"VERSION_LONGUE","session_id":"SESSION_ID"}'
```

Note : `session_id` provient du `session_start` precedent. Si non disponible, generer un UUID v4.

## Exemples concrets

### initialize (test de connexion)

```
curl -s -X POST "https://api.mycelora.ai/functions/v1/mycelora-mcp" \
  -H "Content-Type: application/json" -H "Authorization: Bearer [jeton B1]" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cowork","version":"1.0"}},"id":1}'
```

### mnemos_session_start

```
curl -s -X POST "https://api.mycelora.ai/functions/v1/mycelora-mcp" \
  -H "Content-Type: application/json" -H "Authorization: Bearer [jeton B1]" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"mnemos_session_start","arguments":{"userId":"USER_UUID","sessionId":"SESSION_ID"}},"id":1}'
```

## Historique

- 09/07/2026 : bascule stdio → HTTP, rotation MNEMOS_API_KEY (ancien jeton 78f25137 revoque).
- 10/07/2026 : rotation SUPABASE_SERVICE_ROLE_KEY (sb_secret), ANTHROPIC_API_KEY et VOYAGE_API_KEY ; table secrets mise a jour ; les 13 edge functions redeployees. L'ancien Mode B base sur claude_desktop_config.json est definitivement mort.

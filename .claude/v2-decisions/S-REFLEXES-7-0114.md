# S-REFLEXES-7 : plugin 0.11.4, DDL en ligne (psql -c) et Desktop Commander

Fil Cowork du 03/09/2026 (cowork-2026-09-03-1016-dev-mycelora), modification
chirurgicale par Cowork dans le worktree reflexe-0114, pas de CC.

## Constat de depart (prouve en reel le 03/09)

- `psql "postgresql://…" -c "ALTER TABLE atoms ADD COLUMN …"` = no-match : le
  motif DDL est ancre en tete de ligne (^\s*alter table, MULTILINE) et
  nettoyer_sql efface les litteraux '…' avant le matching. Seuls le heredoc
  et `< fichier.sql` etaient vus.
- Les commandes Desktop Commander sortaient au chemin rapide (tool_name !=
  Bash, brief 4.2 v1). Or l'outil Bash de Cowork tourne dans la VM cloud,
  sans cle ssh ni sql.sh : le seul chemin vers la prod est Desktop Commander.
  Le reflexe ne voyait donc jamais un geste prod reel.
- Le geste infra `docker exec … psql` refuse bien un ssh + psql, mais en
  aveugle (aucun objet, "verifiez manuellement", carte jamais consultee).

## Decisions (Stephane, 03/09 10h40)

1. Extraire les arguments de `-c` / `--command` de psql AVANT le nettoyage
   et les ajouter comme lignes propres du texte analyse. Seulement si psql
   precede le -c dans le meme segment shell.
2. Desktop Commander `start_process` entre dans le reflexe (pre et post),
   par suffixe de nom d'outil, casse ignoree. `interact_with_process`
   (texte envoye a un programme deja lance) reste HORS perimetre : dette
   explicite, contournement connu.
3. Prix accepte : ~110 ms de python par start_process, et un refus unique
   par objet et par fil sur tout ssh + docker exec + psql, sql.sh compris.

## Revue adversariale (reviewer frais, Opus), trois defauts confirmes et corriges avant merge

- Gate `\bpsql\b` global : `grep -c "alter table" /var/log/psql.log`
  produisait un refus absurde. Corrige : psql doit preceder le -c dans le
  meme segment (`&&`, `||`, `;`, `|`, saut de ligne).
- Nettoyage sur le texte concatene : une apostrophe impaire dans la commande
  (`# l'admin`, `don't`) s'appariait avec la ligne ajoutee et effacait le
  DDL. Corrige : nettoyage fragment par fragment.
- Regression de refus unique : un DDL ssh classe ddl ne consommait plus
  `infra:ssh_psql`, un SELECT ssh suivant redeclenchait un refus, et
  l'avertissement "acces direct a la base de prod" disparaissait. Corrige :
  `infra:ssh_psql` est AJOUTE aux objets du geste ddl/update_delete quand
  la commande porte le wrapper ; le rapport garde la ligne infra, le
  pseudo-objet ne compte ni pour rapport_vide ni pour le lookup serveur.

## Dettes explicites

- `psql -c "$SQL"` (variable) et `-c ALTER` non quote : invisibles, comme au
  shell reel. Limite documentee.
- Desktop Commander `write_file` / `edit_block` n'ont pas d'equivalent
  Edit/Write : un fichier sensible ecrit par DC ne pose aucun jalon.
- `interact_with_process` : porte ouverte connue (start_process psql puis
  DDL injecte).
- `head -n 1` sur tool_name dans le JSON brut : une commande contenant
  litteralement `"tool_name": "…"` peut detourner la detection (pre-existant).
- Jalon PostToolUse sur start_process : pose quand DC rend le PID, avant la
  fin reelle du SQL. Cosmetique.
- Observe le 03/09 : pas de jalon quand la commande Bash echoue (PostToolUse
  ne semble pas se declencher sur une erreur d'outil). A verifier.

## Tests

133/133 (120 de la 0.11.3 + 13). Fixtures : psql -c double quote, simple
quote, ssh + -c \"DDL\" (objets + ligne infra), ssh SELECT meme fil
(passage), psql -c SELECT avec litteral (no-match), grep -c psql.log
(no-match), apostrophe impaire (refus), DC ddl (refus, journal
outil=Desktop_Commander), DC rejeu (passage), DC no-match, DC read_file
(hors perimetre), PostToolUse DC (jalon).

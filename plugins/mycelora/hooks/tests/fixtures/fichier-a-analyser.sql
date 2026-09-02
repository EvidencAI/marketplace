-- Fixture S-REFLEXES-2 : fichier lu par redirection ("< fichier.sql") depuis
-- une commande Bash de test (stdin-pre-fichier-sql.json). Le hook PreToolUse
-- doit lire ce fichier (borne 200 Ko) et l'analyser comme s'il faisait partie
-- de la commande elle-meme.
ALTER TABLE table_depuis_fichier ADD COLUMN depuis_fichier int;

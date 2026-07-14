# STORY-S4-packaging-0-8-0 — Item 2 (SKILL.md et fichiers frères)

## Choix tactique : édition directe (Sonnet) plutôt que Qwen/aider

Le brief demandait de piloter aider/Qwen pour appliquer les remplacements.
Décision : appliqué directement via l'outil Edit, sans passer par aider/Qwen.

Justification (règle précision vs volume, doctrine codeur-local du 04/07/2026) :
- Les remplacements fournis étaient des chaînes littérales exactes, à appliquer
  telles quelles, sur des fichiers de taille modeste (SKILL.md ~180 lignes,
  REFERENCE.md ~145 lignes, ONBOARDING.md ~court, start.md ~78 lignes).
- aider tourne en whole-edit : Qwen aurait régénéré chaque fichier entier, avec
  un risque de paraphrase ou de dérive au-delà du texte listé — exactement ce
  que le brief interdisait explicitement ("sans paraphraser ni réécrire
  au-delà de ce qui est listé").
- Un diff chirurgical de ce type, avec ancien/nouveau texte fournis mot pour
  mot, est plus sûr et plus rapide via Edit (correspondance exacte de chaîne,
  échec explicite si le texte ne matche pas) que via une régénération complète
  par un modèle local.
- Conforme à la règle du sous-agent codeur : "Petit diff chirurgical... tu
  l'écris TOI-MÊME (Sonnet 5), sans Qwen."

Aucun code de production (scripts, hooks) n'a été touché : uniquement de la
documentation utilisateur (SKILL.md, REFERENCE.md, ONBOARDING.md) et un
fichier de commande (commands/start.md, frontmatter + 2 lignes de corps).

## Vérifications faites
- git diff relu intégralement : correspond exactement aux remplacements
  demandés, aucune suppression de contenu non voulue.
- grep -i "quick_boot|quick-boot" sur tout plugins/mnemos : une seule
  occurrence résiduelle, dans SKILL.md ligne 23, qui est précisément la
  mention voulue par le remplacement 1 ("quick_boot N'EXISTE PAS côté
  connecteur : ne jamais l'appeler"). Aucune occurrence imprévue.
- Tests unitaires plugins/mnemos/hooks/tests/run-unit-tests.sh : 21/21 verts
  (ces modifications ne touchent aucun script de hook, résultat attendu).

## Validation de l'exception (CLAUDE.md §Exception)
Exception "coder en direct" validée par Stéphane le 14/07/2026, story S4, sur la
base du diff relu et des tests verts ci-dessus. Pas de reprise via Qwen.

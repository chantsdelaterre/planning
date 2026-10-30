# CLAUDE.md — planning

Application de planification du travail de Chants de la Terre (SCEA, SAS, SARL Les 6 Saveurs).
Le **pourquoi** des décisions vit dans le plan de projet (Claude Docs, « Planning de travail —
plan de projet »). Ce fichier porte les **règles de travail** sur ce dépôt.

## Contexte technique

- Base : le projet Supabase **partagé** avec Suivi des temps (`public`), le plan de culture
  (`production`) et la cantine (`cantine`). Le planning vit dans le schéma **`planning`**.
- Front : pages statiques servies par GitHub Pages depuis ce dépôt.
- Règles héritées de Suivi des temps (voir son CLAUDE.md, branche `supabase`) :
  - la clé publique (`anon`) ne lit ni n'écrit rien du schéma `planning` ;
  - toute lecture et toute écriture passe par une **Edge Function** préfixée `planning-` ;
  - l'identité se résout côté serveur à partir du jeton existant (`public.collab_session`),
    jamais en lisant `collaborateurs.token` ;
  - dates en `YYYY-MM-DD` ; le « Max rows » du projet est 1000 → paginer toute lecture longue.
- Fuseau de la base : UTC. Les dates et heures du planning sont des dates et heures locales
  (Europe/Paris) **sans fuseau** : `date` + `time`, jamais `timestamptz` pour une séance.

## ⚠️ Dépôt PUBLIC

Les journaux des GitHub Actions sont publics. **Jamais de donnée de la base en clair dans un
journal** : ni nom, ni heure, ni contrat. Toute lecture de données passe par
`.github/workflows/lecture-chiffree.yml` (sortie chiffrée, déchiffrée par `outils/dechiffrer.sh`
dans l'espace de travail de Claude). Aucune donnée personnelle dans un commit, un fichier
de test ou une issue : les jeux de test utilisent des personnes fictives.

## Déploiement — `.github/workflows/deploy.yml`

Un envoi sur `main` applique les migrations nouvelles de `migrations/` puis déploie les
Edge Functions `supabase/functions/planning-*` modifiées.

Chaque migration commence par une ligne d'en-tête :

```sql
-- portee: planning      -- appliquée automatiquement
-- portee: validation    -- attend l'approbation de Coco (environnement « validation-coco »)
-- sauvegarde: public.collaborateurs, planning.seance   -- facultatif, copie avant application
```

- **`planning`** : exécutée sous le rôle `planning_proprietaire`, qui ne possède que le schéma
  `planning` et ne peut que **lire** quelques colonnes de Suivi des temps. Une erreur ne peut pas
  toucher Suivi des temps, le plan de culture ni la cantine.
- Passe **automatiquement en validation**, quel que soit l'en-tête : `drop`, `truncate`,
  `delete from`, changement de rôle, méta-commande psql, ou en-tête absent.
- **`validation`** : exécutée en `postgres`, après sauvegarde des tables listées dans le schéma
  `planning_sauvegardes` (non exposé par l'API).
- Les migrations appliquées sont tracées dans `planning._migrations` — suivi **séparé** de
  `supabase_migrations` (utilisé par le plan de culture depuis le dépôt `suivi-temps`).
  Ne jamais utiliser `supabase db push` depuis ce dépôt.
- Une migration appliquée ne se modifie jamais : on en ajoute une nouvelle.

## Méthode

- **Tester avant d'envoyer** : `outils/tester.sh` rejoue toutes les migrations sur un PostgreSQL
  local avec une réplique minimale des tables Suivi des temps (`outils/banc-test/`).
- Chaque table du schéma `planning` active la RLS (`enable row level security`) : défense en
  profondeur, même si le schéma n'est pas exposé.
- Ce qui était vrai à l'époque ne se réécrit pas : on archive au lieu de supprimer ; la société
  d'une séance est figée à sa création.
- Les décisions prises seul sont notées dans la section « Décisions » du plan de projet.
- Messages de commit et interface en français.

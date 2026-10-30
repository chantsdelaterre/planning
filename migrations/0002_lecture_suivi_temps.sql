-- portee: validation
-- Les tables de Suivi des temps ont la RLS activée : sans politique, le rôle du planning
-- ne voit aucune ligne malgré ses droits de lecture sur colonnes (0001).
-- Ajoute UNIQUEMENT des politiques de LECTURE pour planning_proprietaire.
-- Aucun autre rôle n'est concerné ; les colonnes lisibles restent celles de 0001.

create policy planning_lecture on public.structures
  for select to planning_proprietaire using (true);
create policy planning_lecture on public.collaborateurs
  for select to planning_proprietaire using (true);
create policy planning_lecture on public.historique_contrats
  for select to planning_proprietaire using (true);
create policy planning_lecture on public.jours
  for select to planning_proprietaire using (true);

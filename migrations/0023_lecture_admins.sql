-- portee: validation
-- Le planning lit le NOM et l'état ACTIF des administrateurs de Suivi des temps (jamais le jeton),
-- pour la rubrique « Administrateurs » de l'écran Accès et la validité de leurs liens planning.
grant select (admin_id, nom, actif) on public.admins to planning_proprietaire;
create policy planning_lecture on public.admins for select to planning_proprietaire using (true);

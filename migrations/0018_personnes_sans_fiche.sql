-- portee: validation
-- sauvegarde: public.personne
-- Le planning peut créer des personnes SANS fiche (collaborateur à venir, externe), les renommer
-- et les supprimer (après rattachement à la vraie personne). Il ne peut toucher à AUCUNE personne
-- qui a une fiche dans Suivi des temps : les politiques ci-dessous l'interdisent en base.
grant insert (prenom, nom, externe), update (prenom, nom), delete on public.personne to planning_proprietaire;

create policy planning_creer_sans_fiche on public.personne for insert to planning_proprietaire
  with check (externe and fiche_principale is null);
create policy planning_modifier_sans_fiche on public.personne for update to planning_proprietaire
  using (externe and fiche_principale is null
         and not exists (select 1 from public.collaborateurs c where c.personne_id = personne.personne_id))
  with check (externe and fiche_principale is null);
create policy planning_supprimer_sans_fiche on public.personne for delete to planning_proprietaire
  using (externe and fiche_principale is null
         and not exists (select 1 from public.collaborateurs c where c.personne_id = personne.personne_id));

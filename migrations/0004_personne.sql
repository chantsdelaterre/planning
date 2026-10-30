-- portee: validation
-- sauvegarde: public.collaborateurs
-- Étape 1 de la table commune « personne » (décidée avec Coco le 30/10/2026).
-- Une personne = un être humain ; une fiche (public.collaborateurs) = un emploi chez un employeur.
-- Purement additif pour Suivi des temps :
--   - nouvelle table public.personne ;
--   - nouvelle colonne collaborateurs.personne_id, remplie pour toutes les fiches ;
--   - un déclencheur crée la personne d'une fiche créée plus tard, et suit ses changements de nom.
-- Aucune fonction, aucune page, aucune Edge Function de Suivi des temps n'est modifiée.

create table public.personne (
  personne_id      bigint generated always as identity primary key,
  prenom           text not null,
  nom              text not null,
  externe          boolean not null default false,   -- intérimaire, prestataire : aucune fiche
  -- Contrôle différé : à la création d'une fiche, la personne est créée juste avant la fiche.
  fiche_principale text references public.collaborateurs (collab_id) deferrable initially deferred,
  created_at       timestamptz not null default now()
);
comment on table public.personne is
  'Un être humain. Une fiche collaborateurs = un emploi chez un employeur (personne_id). Créée pour le planning, le 30/10/2026.';

-- Comme pour collaborateurs : rien pour la clé publique.
revoke all on public.personne from anon, authenticated;
grant select, insert, update on public.personne to service_role;  -- Edge Functions (externes)
alter table public.personne enable row level security;

alter table public.collaborateurs add column personne_id bigint references public.personne (personne_id);
create index collaborateurs_personne on public.collaborateurs (personne_id);

-- Une personne par fiche existante…
do $$
declare f record; p bigint;
begin
  for f in select collab_id, prenom, nom from public.collaborateurs order by collab_id loop
    insert into public.personne (prenom, nom, fiche_principale)
      values (f.prenom, f.nom, f.collab_id) returning personne_id into p;
    update public.collaborateurs set personne_id = p where collab_id = f.collab_id;
  end loop;
end $$;

-- …puis les deux personnes à deux employeurs sont regroupées (fiches SAS + SARL).
-- La fiche principale garde la personne ; l'autre fiche la rejoint ; la personne en trop est supprimée.
do $$
declare paire record; garde bigint; jette bigint;
begin
  for paire in select * from (values ('COLL028', 'COLL035'), ('COLL032', 'COLL043')) v(principale, autre) loop
    select personne_id into garde from public.collaborateurs where collab_id = paire.principale;
    select personne_id into jette from public.collaborateurs where collab_id = paire.autre;
    if garde is null or jette is null then
      raise exception 'Fiche introuvable pour le regroupement % / %', paire.principale, paire.autre;
    end if;
    update public.collaborateurs set personne_id = garde where collab_id = paire.autre;
    delete from public.personne where personne_id = jette;
  end loop;
end $$;

-- Noms propres pour les personnes regroupées : on retire la société collée au nom de famille.
update public.personne p
   set nom = btrim(regexp_replace(p.nom, '\s+(SAS|6 SAVEURS|SARL|\(.*\))$', '', 'i'))
 where p.fiche_principale in ('COLL028', 'COLL032');

alter table public.collaborateurs alter column personne_id set not null;

-- Fiches créées plus tard : une personne est créée automatiquement.
create function public.personne_pour_nouvelle_fiche() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.personne_id is null then
    insert into public.personne (prenom, nom, fiche_principale)
      values (new.prenom, new.nom, new.collab_id)
      returning personne_id into new.personne_id;
  end if;
  return new;
end $$;
revoke execute on function public.personne_pour_nouvelle_fiche() from public, anon, authenticated;
create trigger personne_pour_nouvelle_fiche before insert on public.collaborateurs
  for each row execute function public.personne_pour_nouvelle_fiche();

-- Changement de nom sur une fiche : répercuté sur la personne si elle n'a que cette fiche.
create function public.personne_suit_nom_fiche() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.prenom, new.nom) is distinct from (old.prenom, old.nom)
     and (select count(*) from public.collaborateurs c where c.personne_id = new.personne_id) = 1 then
    update public.personne set prenom = new.prenom, nom = new.nom where personne_id = new.personne_id;
  end if;
  return new;
end $$;
revoke execute on function public.personne_suit_nom_fiche() from public, anon, authenticated;
create trigger personne_suit_nom_fiche after update of prenom, nom on public.collaborateurs
  for each row execute function public.personne_suit_nom_fiche();

-- Le planning lit les personnes et la colonne de lien (RLS : politique de lecture dédiée).
grant select, references on public.personne to planning_proprietaire;
create policy planning_lecture on public.personne for select to planning_proprietaire using (true);
grant select (personne_id) on public.collaborateurs to planning_proprietaire;

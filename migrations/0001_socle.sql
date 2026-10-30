-- portee: validation
-- Socle du planning : rôle propriétaire, schéma, suivi des migrations, droits de lecture.
-- Ne modifie aucune table existante. Ajoute seulement des droits de LECTURE sur quelques
-- colonnes de Suivi des temps (jamais les jetons, e-mails, téléphones, matricules, taux, NSS).

-- 1. Rôle propriétaire du schéma planning (sans connexion possible).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'planning_proprietaire') then
    create role planning_proprietaire nologin;
  end if;
end $$;
grant planning_proprietaire to postgres with inherit true, set true;

-- 2. Schémas.
create schema if not exists planning authorization planning_proprietaire;
revoke all on schema planning from public;
create schema if not exists planning_sauvegardes;
revoke all on schema planning_sauvegardes from public;

-- 3. Suivi des migrations du planning (distinct de supabase_migrations).
create table if not exists planning._migrations (
  nom         text primary key,
  classe      text not null check (classe in ('planning', 'validation')),
  empreinte   text not null,
  appliquee_le timestamptz not null default now()
);
alter table planning._migrations owner to planning_proprietaire;
alter table planning._migrations enable row level security;

-- 4. Lecture de Suivi des temps : colonnes non sensibles uniquement.
grant usage on schema public to planning_proprietaire;
grant select (code_structure, nom_legal) on public.structures to planning_proprietaire;
grant select (collab_id, prenom, nom, nom_affiche, structure, type_contrat, heures_hebdo,
              type_periode, actif, statut, role, equipe_id)
  on public.collaborateurs to planning_proprietaire;
grant select (id, collab_id, date_debut, date_fin, structure, type_contrat, heures_hebdo,
              type_periode, rupture_anticipee)
  on public.historique_contrats to planning_proprietaire;
grant select (jour_id, collab_id, date_jour, type_jour, c1_debut, c1_fin, c2_debut, c2_fin,
              c3_debut, c3_fin, total_heures)
  on public.jours to planning_proprietaire;

-- 5. Les Edge Functions (service_role) utilisent le schéma planning ; anon et authenticated : rien.
grant usage on schema planning to service_role;
alter default privileges for role planning_proprietaire in schema planning
  grant select, insert, update, delete on tables to service_role;
alter default privileges for role planning_proprietaire in schema planning
  grant usage, select on sequences to service_role;
alter default privileges for role planning_proprietaire in schema planning
  grant execute on functions to service_role;
alter default privileges for role planning_proprietaire in schema planning
  revoke execute on functions from public;

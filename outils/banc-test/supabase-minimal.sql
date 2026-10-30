-- Réplique MINIMALE et FICTIVE de ce que le planning utilise dans la base partagée.
-- Colonnes recopiées de SCHEMA_REEL.md (suivi-temps, branche supabase). Aucune donnée réelle.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;

create table public.structures (structure_id text, code_structure text not null, nom_legal text,
  adresse text, siret text, siege text);
insert into public.structures values
  ('S1','SCEA','SCEA Exemple',null,null,null), ('S2','SAS','SAS Exemple',null,null,null),
  ('S3','SARL','SARL Exemple',null,null,null);

create table public.collaborateurs (collab_id text primary key, prenom text not null, nom text not null,
  nom_affiche text, email text, structure text, equipe_id text, type_contrat text, type_periode text,
  heures_hebdo numeric, statut text default 'en_attente', date_activation date, actif boolean default false,
  role text default 'collab', employeur text, matricule_silae text, token text, created_at timestamptz default now(),
  telephone text, urgence_prenom text, urgence_nom text, urgence_telephone text, urgence_lien text,
  numero_securite_sociale text);
insert into public.collaborateurs (collab_id, prenom, nom, structure, type_contrat, heures_hebdo, actif, token) values
  ('T001','Anna','Test','SAS','CDI',35,true,'jetonA'),
  ('T002','Bruno','Essai SAS','SAS','TESA',16,true,'jetonB1'),
  ('T003','Bruno','Essai SARL','SARL','TESA',15,true,'jetonB2'),
  ('T004','Chloé','Exemple','SCEA','CDI',35,true,'jetonC'),
  -- Mêmes identifiants que les deux personnes réelles à deux fiches ; noms fictifs.
  ('COLL028','Zoé','FICTIVE','SARL','CDI',35,true,'jZ1'),
  ('COLL035','Zoé','F. (CHANTS DE LA TERRE)','SAS','TESA',8,true,'jZ2'),
  ('COLL032','Yann','EXEMPLE SAS','SAS','TESA',16,true,'jY1'),
  ('COLL043','Yann','EXEMPLE 6 SAVEURS','SARL','TESA',15,true,'jY2');

create table public.historique_contrats (id bigint generated always as identity primary key,
  collab_id text not null references public.collaborateurs, date_debut date not null, date_fin date,
  structure text, type_contrat text, heures_hebdo numeric, matricule_silae text, created_at timestamptz default now(),
  type_periode text, modifie_le timestamptz, modifie_par text, taux_horaire numeric,
  rupture_anticipee boolean not null default false);

create table public.jours (jour_id text primary key, collab_id text references public.collaborateurs,
  date_jour date, jour_semaine text, periode_id text, type_jour text,
  c1_debut text, c1_fin text, c2_debut text, c2_fin text, c3_debut text, c3_fin text,
  commentaire text, total_heures numeric default 0, total_hebdo_prog numeric default 0,
  nb_modifications integer default 0, date_derniere_modif text, remarque_manager text,
  created_at timestamptz default now());

grant usage on schema public to anon, authenticated, service_role;

-- Comme en production : RLS activée sur les tables de Suivi des temps (rls_auto_enable).
alter table public.structures enable row level security;
alter table public.collaborateurs enable row level security;
alter table public.historique_contrats enable row level security;
alter table public.jours enable row level security;

create table public.admins (admin_id text primary key, nom text, token text, actif boolean default true);
insert into public.admins values ('admin_test1', 'Test un', 'jA1', true), ('admin_test2', 'Test deux', 'jA2', true);
alter table public.admins enable row level security;

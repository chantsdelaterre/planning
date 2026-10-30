-- portee: planning
-- Cœur du planning : droits, sélections, séries, séances, affectations, indisponibilités,
-- jours fermés, journal. Les règles de calcul (génération des séances, fiche imputée,
-- chevauchements, heures) viennent dans la migration suivante.
-- Dates et heures : locales (Europe/Paris), sans fuseau (date + time).

-- Droits ---------------------------------------------------------------------------------

create table planning.atelier_responsable (
  atelier_id  bigint not null references planning.atelier,
  personne_id bigint not null references public.personne (personne_id),
  primary key (atelier_id, personne_id)
);

-- Administrateurs de Suivi des temps (public.admins.admin_id). Pas de ligne = consultation.
create table planning.acces_admin (
  admin_id text primary key,
  niveau   text not null check (niveau in ('complet', 'consultation'))
);

-- Ateliers habituels d'une personne : filtre par défaut du panneau, pas une barrière.
create table planning.personne_atelier (
  personne_id bigint not null references public.personne (personne_id),
  atelier_id  bigint not null references planning.atelier,
  primary key (personne_id, atelier_id)
);

-- Sélections -----------------------------------------------------------------------------

create table planning.selection (
  id                bigint generated always as identity primary key,
  nom               text not null check (btrim(nom) <> ''),
  proprietaire_type text not null check (proprietaire_type in ('personne', 'admin')),
  proprietaire_id   text not null,          -- personne_id ou admin_id
  partagee          boolean not null default false,
  cree_le           timestamptz not null default now()
);

create table planning.selection_element (
  selection_id bigint not null references planning.selection on delete cascade,
  type         text not null check (type in ('activite', 'atelier', 'regroupement', 'tache')),
  element_id   bigint not null,
  primary key (selection_id, type, element_id)
);

-- Programmation --------------------------------------------------------------------------

create table planning.serie (
  id          bigint generated always as identity primary key,
  tache_id    bigint not null references planning.tache,
  titre       text,                          -- facultatif ; sinon le nom de la tâche
  lieu        text,
  jours       smallint[] not null check (cardinality(jours) between 1 and 7
                                         and jours <@ array[1,2,3,4,5,6,7]::smallint[]),  -- 1 = lundi
  heure_debut time not null,
  heure_fin   time not null check (heure_fin > heure_debut),
  date_debut  date not null,
  date_fin    date check (date_fin is null or date_fin >= date_debut),
  cree_le     timestamptz not null default now(),
  cree_par    text
);

create table planning.serie_personne (
  serie_id    bigint not null references planning.serie on delete cascade,
  personne_id bigint not null references public.personne (personne_id),
  primary key (serie_id, personne_id)
);

create table planning.seance (
  id          bigint generated always as identity primary key,
  tache_id    bigint not null references planning.tache,
  serie_id    bigint references planning.serie,
  date_serie  date,                          -- date prévue par la série (clé de génération)
  societe     text not null,                 -- figée à la création (société de l'atelier)
  date_seance date not null,                 -- date effective (après déplacement éventuel)
  heure_debut time not null,
  heure_fin   time not null check (heure_fin > heure_debut),
  titre       text,
  lieu        text,
  statut      text not null default 'prevue' check (statut in ('prevue', 'suspendue')),
  motif       text,                          -- facultatif (suspension)
  modifiee    boolean not null default false,-- retouchée à la main : la série ne l'écrase plus
  cree_le     timestamptz not null default now(),
  modifie_le  timestamptz,
  check ((serie_id is null) = (date_serie is null))
);
create unique index seance_serie_date on planning.seance (serie_id, date_serie) where serie_id is not null;
create index seance_date on planning.seance (date_seance);
create index seance_tache on planning.seance (tache_id);
create trigger seance_societe before insert or update of societe on planning.seance
  for each row execute function planning.verifier_societe();

create table planning.affectation (
  seance_id   bigint not null references planning.seance on delete cascade,
  personne_id bigint not null references public.personne (personne_id),
  collab_id   text,                          -- fiche imputée (null pour un externe)
  mad         boolean not null default false,-- mise à disposition (fiche d'une autre société)
  primary key (seance_id, personne_id)
);
create index affectation_personne on planning.affectation (personne_id);

create table planning.indisponibilite (
  id          bigint generated always as identity primary key,
  personne_id bigint not null references public.personne (personne_id),
  date_debut  date not null,
  date_fin    date not null check (date_fin >= date_debut),
  jours       smallint[] check (jours is null or jours <@ array[1,2,3,4,5,6,7]::smallint[]),  -- null = tous les jours
  heure_debut time,                          -- null = toute la journée
  heure_fin   time,
  motif       text,
  cree_le     timestamptz not null default now(),
  check ((heure_debut is null) = (heure_fin is null)),
  check (heure_fin is null or heure_fin > heure_debut)
);
create index indisponibilite_personne on planning.indisponibilite (personne_id, date_debut);

create table planning.jour_ferme (
  id      bigint generated always as identity primary key,
  date    date not null,
  societe text,                              -- null = toute l'entreprise
  motif   text,
  cree_le timestamptz not null default now()
);
create unique index jour_ferme_unique on planning.jour_ferme (date, coalesce(societe, ''));
create trigger jour_ferme_societe before insert or update of societe on planning.jour_ferme
  for each row when (new.societe is not null) execute function planning.verifier_societe();

-- Journal --------------------------------------------------------------------------------

create table planning.journal (
  id       bigint generated always as identity primary key,
  quand    timestamptz not null default now(),
  qui      text not null,                    -- personne:<id> ou admin:<id>
  objet    text not null,                    -- seance, serie, affectation, referentiel…
  objet_id bigint,
  action   text not null,
  avant    jsonb,
  apres    jsonb
);
create index journal_objet on planning.journal (objet, objet_id);

-- Défense en profondeur ------------------------------------------------------------------
alter table planning.atelier_responsable enable row level security;
alter table planning.acces_admin         enable row level security;
alter table planning.personne_atelier    enable row level security;
alter table planning.selection           enable row level security;
alter table planning.selection_element   enable row level security;
alter table planning.serie               enable row level security;
alter table planning.serie_personne      enable row level security;
alter table planning.seance              enable row level security;
alter table planning.affectation         enable row level security;
alter table planning.indisponibilite     enable row level security;
alter table planning.jour_ferme          enable row level security;
alter table planning.journal             enable row level security;

-- portee: planning
-- Référentiel du travail : activités, ateliers, regroupements, tâches.
-- Contenu validé par Coco le 30/10/2026 (onglet « Référentiel à valider » du plan de projet).
-- Rien n'est supprimé : un élément qui a servi s'archive (archive_le renseignée).

create table planning.activite (
  id          bigint generated always as identity primary key,
  nom         text not null check (btrim(nom) <> ''),
  ordre       integer not null default 0,
  archive_le  timestamptz,
  cree_le     timestamptz not null default now()
);
create unique index activite_nom_actif on planning.activite (lower(nom)) where archive_le is null;

create table planning.atelier (
  id           bigint generated always as identity primary key,
  activite_id  bigint not null references planning.activite,
  nom          text not null check (btrim(nom) <> ''),
  societe      text not null,                      -- public.structures.code_structure
  couleur      text not null default '#6B7280' check (couleur ~ '^#[0-9A-Fa-f]{6}$'),
  ordre        integer not null default 0,
  au_demarrage boolean not null default false,     -- présent dans le planning dès le lancement
  archive_le   timestamptz,
  cree_le      timestamptz not null default now()
);
create unique index atelier_nom_actif on planning.atelier (lower(nom)) where archive_le is null;

-- La société doit exister dans public.structures (pas de clé étrangère possible : code non unique côté Suivi des temps).
create function planning.verifier_societe() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.structures s where s.code_structure = new.societe) then
    raise exception 'Société inconnue : %', new.societe using errcode = 'foreign_key_violation';
  end if;
  return new;
end $$;
create trigger atelier_societe before insert or update of societe on planning.atelier
  for each row execute function planning.verifier_societe();

create table planning.regroupement (
  id          bigint generated always as identity primary key,
  nom         text not null check (btrim(nom) <> ''),
  ordre       integer not null default 0,
  archive_le  timestamptz,
  cree_le     timestamptz not null default now()
);
create unique index regroupement_nom_actif on planning.regroupement (lower(nom)) where archive_le is null;

create table planning.tache (
  id              bigint generated always as identity primary key,
  atelier_id      bigint not null references planning.atelier,
  regroupement_id bigint references planning.regroupement,
  nom             text not null check (btrim(nom) <> ''),
  ordre           integer not null default 0,
  archive_le      timestamptz,
  cree_le         timestamptz not null default now()
);
create unique index tache_nom_actif on planning.tache (atelier_id, lower(nom)) where archive_le is null;
create index tache_regroupement on planning.tache (regroupement_id);

alter table planning.activite     enable row level security;
alter table planning.atelier      enable row level security;
alter table planning.regroupement enable row level security;
alter table planning.tache        enable row level security;

-- Contenu initial ------------------------------------------------------------------------

insert into planning.activite (nom, ordre) values
  ('Commerce', 1), ('Production agricole', 2), ('Les Halles', 3);

insert into planning.atelier (activite_id, nom, societe, couleur, ordre, au_demarrage)
select a.id, v.nom, v.societe, v.couleur, v.ordre, v.demarrage
from (values
  ('Commerce',            'Paniers',        'SAS',  '#B04A78', 1, true),
  ('Commerce',            'Appros-marchés', 'SAS',  '#3A6EA5', 2, true),
  ('Production agricole', 'Lavage',         'SCEA', '#2E8B8B', 1, false),
  ('Production agricole', 'Plein-champ',    'SCEA', '#3F8A5A', 2, false),
  ('Production agricole', 'Jardin',         'SCEA', '#7A9A2E', 3, false),
  ('Production agricole', 'Support',        'SCEA', '#6E5AA8', 4, false),
  ('Les Halles',          'Halles',         'SARL', '#B86E25', 1, false)
) as v(activite, nom, societe, couleur, ordre, demarrage)
join planning.activite a on a.nom = v.activite;

insert into planning.regroupement (nom, ordre) values
  ('Logistique', 1), ('Halles', 2), ('St Jo', 3), ('Vente ferme', 4),
  ('Préparation des paniers', 5), ('Administration commerciale', 6);

insert into planning.tache (atelier_id, regroupement_id, nom, ordre)
select at.id, r.id, v.nom, v.ordre
from (values
  ('Appros-marchés', 'Réception, préparation',  'Logistique',                 1),
  ('Appros-marchés', 'Montage Halles',          'Halles',                     2),
  ('Appros-marchés', 'Montage St Jo.',          'St Jo',                      3),
  ('Appros-marchés', 'Retour St Jo.',           'St Jo',                      4),
  ('Appros-marchés', 'Vente St Jo',             'St Jo',                      5),
  ('Appros-marchés', 'Commandes, prix etc',     'Administration commerciale', 6),
  ('Appros-marchés', 'Montage-vente',           'Vente ferme',                7),
  ('Paniers',        'Préparation des paniers', 'Préparation des paniers',    1),
  ('Paniers',        'Livraisons des paniers',  'Préparation des paniers',    2),
  ('Paniers',        'Ensachage',               'Préparation des paniers',    3),
  ('Paniers',        'Commandes, prix etc',     'Administration commerciale', 4),
  ('Plein-champ',    'Récolte',                 null,                         1),
  ('Plein-champ',    'MeC, entretien cultures', null,                         2),
  ('Jardin',         'Récolte',                 null,                         1),
  ('Jardin',         'MeC, entretien cultures', null,                         2)
) as v(atelier, nom, regroupement, ordre)
join planning.atelier at on at.nom = v.atelier
left join planning.regroupement r on r.nom = v.regroupement;

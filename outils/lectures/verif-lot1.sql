-- Lecture seule : contrôle après déploiement du lot 1.
\pset format unaligned
\pset fieldsep ' | '
select 'migrations: ' || string_agg(nom || ' (' || classe || ')', ', ' order by nom) from planning._migrations;
select 'fiches: ' || count(*) || ', sans personne: ' || count(*) filter (where personne_id is null) from public.collaborateurs;
select 'personnes: ' || count(*) || ', externes: ' || count(*) filter (where externe) from public.personne;
select 'personnes à plusieurs fiches: ' || string_agg(p.prenom || ' ' || p.nom || ' = ' || f.fiches, ' ; ')
from public.personne p join (select personne_id, string_agg(collab_id || '/' || structure, ', ' order by collab_id) fiches
  from public.collaborateurs group by personne_id having count(*) > 1) f using (personne_id);
select 'accès admin: ' || string_agg(admin_id || '=' || niveau, ', ') from planning.acces_admin;
select 'référentiel: ' || (select count(*) from planning.activite) || ' activités, ' || (select count(*) from planning.atelier) || ' ateliers, '
  || (select count(*) from planning.regroupement) || ' regroupements, ' || (select count(*) from planning.tache) || ' tâches';
select 'déclencheurs sur collaborateurs: ' || string_agg(tgname, ', ') from pg_trigger where tgrelid = 'public.collaborateurs'::regclass and not tgisinternal;
select 'sauvegardes: ' || string_agg(table_name, ', ') from information_schema.tables where table_schema = 'planning_sauvegardes';
select 'anon sur personne: ' || has_table_privilege('anon', 'public.personne', 'select') || ', anon sur schéma planning: ' || has_schema_privilege('anon', 'planning', 'usage');
set role planning_proprietaire;
select 'planning voit: ' || (select count(*) from public.collaborateurs where actif) || ' fiches actives, ' || (select count(*) from planning.v_realise_jour where date_jour >= current_date - 7) || ' jours saisis sur 7 jours';
reset role;

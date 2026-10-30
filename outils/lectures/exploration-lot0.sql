-- Lecture seule : exploration pour le référentiel du lot 0.
-- Aucun jeton, e-mail, téléphone ni matricule n'est lu.
\pset format unaligned
\pset fieldsep ' | '
\echo '== Schémas'
select nspname from pg_namespace where nspname not like 'pg\_%' and nspname <> 'information_schema' order by 1;
\echo '== Tables public'
select table_name from information_schema.tables where table_schema = 'public' order by 1;
\echo '== Colonnes collaborateurs'
select column_name, data_type from information_schema.columns where table_schema='public' and table_name='collaborateurs' order by ordinal_position;
\echo '== Structures (toutes fiches)'
select coalesce(structure,'(vide)') structure, count(*) total, count(*) filter (where actif) actifs from public.collaborateurs group by 1 order by 1;
\echo '== Employeur x structure (actifs)'
select coalesce(employeur,'(vide)'), coalesce(structure,'(vide)'), count(*) from public.collaborateurs where actif group by 1,2 order by 1,2;
\echo '== Types de contrat (actifs)'
select coalesce(structure,'(vide)'), coalesce(type_contrat,'(vide)'), count(*) from public.collaborateurs where actif group by 1,2 order by 1,2;
\echo '== Rôles'
select coalesce(role,'(vide)'), count(*) from public.collaborateurs group by 1 order by 1;
\echo '== Équipes (sans jetons)'
select equipe_id, nom_equipe, nom_manager, actif, (select count(*) from public.collaborateurs c where c.equipe_id = e.equipe_id and c.actif) membres_actifs from public.equipes e order by nom_equipe;
\echo '== Fiches actives'
select collab_id, prenom, nom, nom_affiche, structure, type_contrat, heures_hebdo, type_periode, equipe_id, role from public.collaborateurs where actif order by structure, nom, prenom;
\echo '== Personnes à plusieurs fiches (même prénom + nom, toutes fiches)'
select lower(prenom)||' '||lower(nom) personne, string_agg(collab_id||':'||coalesce(structure,'?')||':'||case when actif then 'actif' else 'inactif' end, ', ' order by collab_id) fiches
from public.collaborateurs group by lower(prenom), lower(nom) having count(*) > 1 order by 1;
\echo '== Même nom de famille, plusieurs fiches actives (vérification manuelle)'
select lower(nom), string_agg(prenom||' ('||collab_id||', '||coalesce(structure,'?')||')', ', ') from public.collaborateurs where actif group by lower(nom) having count(*) > 1 order by 1;
\echo '== Format des créneaux saisis (30 derniers jours)'
select length(c1_debut) longueur, count(*) from public.jours where date_jour >= current_date - 30 and c1_debut is not null group by 1 order by 1;
\echo '== Saisies des 30 derniers jours par structure'
select coalesce(c.structure,'?'), count(*) jours, count(*) filter (where j.total_heures > 0) avec_heures, round(sum(j.total_heures)::numeric,1) heures from public.jours j join public.collaborateurs c using (collab_id) where j.date_jour >= current_date - 30 group by 1 order by 1;
\echo '== Types de jour (30 derniers jours)'
select coalesce(type_jour,'(vide)'), count(*) from public.jours where date_jour >= current_date - 30 group by 1 order by 1;
\echo '== Admins (colonnes seulement)'
select column_name from information_schema.columns where table_schema='public' and table_name='admins' order by ordinal_position;
\echo '== Rôles Postgres utiles'
select rolname, rolcanlogin, rolcreaterole, rolsuper from pg_roles where rolname in ('postgres','anon','authenticated','service_role','authenticator') order by 1;
select 'postgres peut créer des rôles: ' || rolcreaterole from pg_roles where rolname = current_user;
\echo '== Fonctions public (noms)'
select string_agg(proname, ', ' order by proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';
\echo '== Extensions'
select extname, extversion from pg_extension order by 1;

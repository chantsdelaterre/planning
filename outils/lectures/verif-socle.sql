-- Lecture seule : vérifications avant la migration de socle.
\pset format unaligned
\pset fieldsep ' | '
\echo '== Colonnes structures'
select column_name, data_type, is_nullable from information_schema.columns where table_schema='public' and table_name='structures' order by ordinal_position;
\echo '== Contenu structures'
select * from public.structures;
\echo '== rls_auto_enable'
select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='rls_auto_enable';
\echo '== Event triggers'
select evtname, evtevent, evtenabled, evtfoid::regproc from pg_event_trigger;
\echo '== Schémas cantine et production : propriétaire et droits'
select nspname, pg_get_userbyid(nspowner), nspacl from pg_namespace where nspname in ('cantine','production','public');
\echo '== Tables cantine'
select table_name from information_schema.tables where table_schema='cantine' order by 1;
\echo '== Migrations Supabase enregistrées'
select version, name from supabase_migrations.schema_migrations order by version desc limit 25;
\echo '== Droits de postgres sur les tables public (extrait)'
select table_name, string_agg(privilege_type, ',' order by privilege_type) from information_schema.table_privileges where table_schema='public' and grantee='postgres' and table_name in ('collaborateurs','jours','historique_contrats') group by 1;
\echo '== postgres membre de'
select string_agg(b.rolname, ', ') from pg_auth_members m join pg_roles b on b.oid=m.roleid join pg_roles r on r.oid=m.member where r.rolname='postgres';
\echo '== Fuseau'
show timezone;

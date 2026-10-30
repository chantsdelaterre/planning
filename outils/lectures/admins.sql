-- Lecture seule : administrateurs de Suivi des temps (jamais le jeton).
\pset format unaligned
\pset fieldsep ' | '
select admin_id, nom, actif from public.admins order by admin_id;
select 'RLS admins: ' || relrowsecurity from pg_class where oid = 'public.admins'::regclass;
select 'policies admins: ' || count(*) from pg_policies where schemaname='public' and tablename='admins';

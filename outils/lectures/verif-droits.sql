-- Lecture seule : postgres peut-il accorder la lecture des tables Suivi des temps ?
\pset format unaligned
\pset fieldsep ' | '
select c.relname, pg_get_userbyid(c.relowner) proprietaire,
  has_table_privilege('postgres', c.oid, 'SELECT WITH GRANT OPTION') peut_accorder
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('structures','collaborateurs','historique_contrats','jours')
order by 1;
select 'version: ' || current_setting('server_version');
select 'createrole_self_grant: ' || current_setting('createrole_self_grant', true);

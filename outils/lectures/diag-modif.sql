-- Lecture seule : diagnostic d'une modification d'horaire.
\pset format unaligned
\pset fieldsep ' | '
\echo '== Journal (20 dernières écritures)'
select id, to_char(quand at time zone 'Europe/Paris', 'DD/MM HH24:MI:SS') quand, objet, objet_id, action,
       jsonb_strip_nulls(apres - 'personnes') apres,
       case when avant is not null then jsonb_build_object('date_seance', avant->'date_seance', 'heure_debut', avant->'heure_debut', 'heure_fin', avant->'heure_fin', 'serie_id', avant->'serie_id', 'date_serie', avant->'date_serie') end avant
from planning.journal order by id desc limit 20;
\echo '== Séries'
select id, tache_id, jours, heure_debut, heure_fin, date_debut, date_fin from planning.serie order by id;
\echo '== Séances des 3 prochaines semaines'
select id, serie_id, date_serie, date_seance, heure_debut, heure_fin, statut, modifiee, supprimee_le is not null supprimee
from planning.seance where date_seance between current_date - 7 and current_date + 21 order by date_seance, heure_debut;

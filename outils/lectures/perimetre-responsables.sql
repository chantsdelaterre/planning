-- Pourquoi une personne est dans le périmètre d'un responsable (semaines 44 et 45) :
-- atelier habituel, ou séance d'un de ses ateliers.
select r.prenom || ' ' || r.nom as responsable, at.nom as atelier_resp, q.prenom || ' ' || q.nom as personne,
       'habituel' as raison, null::text as detail
  from planning.atelier_responsable ar
  join public.personne r on r.personne_id = ar.personne_id
  join planning.atelier at on at.id = ar.atelier_id
  join planning.personne_atelier pa on pa.atelier_id = ar.atelier_id
  join public.personne q on q.personne_id = pa.personne_id
union all
select r.prenom || ' ' || r.nom, at.nom, q.prenom || ' ' || q.nom, 'séance',
       string_agg(distinct t.nom || ' ' || to_char(s.date_seance, 'DD/MM') || ' ' || to_char(s.heure_debut, 'HH24:MI'), ', ')
  from planning.atelier_responsable ar
  join public.personne r on r.personne_id = ar.personne_id
  join planning.atelier at on at.id = ar.atelier_id
  join planning.tache t on t.atelier_id = ar.atelier_id
  join planning.seance s on s.tache_id = t.id and s.supprimee_le is null and s.date_seance between date '2026-10-26' and date '2026-11-08'
  join planning.affectation a on a.seance_id = s.id
  join public.personne q on q.personne_id = a.personne_id
 group by 1, 2, 3
 order by 1, 2, 3, 4;

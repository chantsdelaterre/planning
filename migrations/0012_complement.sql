-- portee: planning
-- Le titre d'une séance devient un complément du nom de la tâche (« Récolte · haricots »).
-- La vue expose le complément seul, en dernière colonne (seul ajout possible sur une vue existante).
create or replace view planning.v_seance as
select s.id, s.date_seance, s.heure_debut, s.heure_fin,
       extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0 as duree_h,
       s.statut, s.motif, s.modifiee, s.serie_id, s.date_serie,
       (s.serie_id is not null and s.date_serie <> s.date_seance) as deplacee,
       coalesce(s.titre, t.nom) as titre, s.lieu, s.societe,
       t.id as tache_id, t.nom as tache, r.id as regroupement_id, r.nom as regroupement,
       at.id as atelier_id, at.nom as atelier, at.couleur, ac.id as activite_id, ac.nom as activite,
       (select count(*) from planning.affectation a where a.seance_id = s.id) as nb_personnes,
       case when s.statut = 'prevue'
            then extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0
                 * (select count(*) from planning.affectation a where a.seance_id = s.id)
            else 0 end as main_oeuvre_h,
       s.titre as complement
from planning.seance s
join planning.tache t on t.id = s.tache_id
left join planning.regroupement r on r.id = t.regroupement_id
join planning.atelier at on at.id = t.atelier_id
join planning.activite ac on ac.id = at.activite_id
where s.supprimee_le is null;

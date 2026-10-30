-- portee: planning
-- Supprimer une séance.
--   - ponctuelle : supprimée pour de bon (le journal garde son contenu) ;
--   - d'une série : marquée supprimée (supprimee_le), sinon la génération la recréerait.
-- Une séance marquée supprimée n'apparaît plus nulle part : grille, totaux, chevauchements.

alter table planning.seance add column supprimee_le timestamptz;

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
            else 0 end as main_oeuvre_h
from planning.seance s
join planning.tache t on t.id = s.tache_id
left join planning.regroupement r on r.id = t.regroupement_id
join planning.atelier at on at.id = t.atelier_id
join planning.activite ac on ac.id = at.activite_id
where s.supprimee_le is null;

create or replace view planning.v_prevu_jour as
select a.personne_id, a.collab_id, a.mad, s.date_seance as date_jour, s.societe,
       t.atelier_id, sum(extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0) as heures
from planning.affectation a
join planning.seance s on s.id = a.seance_id and s.statut = 'prevue' and s.supprimee_le is null
join planning.tache t on t.id = s.tache_id
group by a.personne_id, a.collab_id, a.mad, s.date_seance, s.societe, t.atelier_id;

create or replace view planning.v_chevauchement as
select a1.personne_id, s1.date_seance as date_jour,
       'seance'::text as nature, s1.id as seance_id, s2.id as autre_seance_id, null::bigint as indisponibilite_id,
       greatest(s1.heure_debut, s2.heure_debut) as debut, least(s1.heure_fin, s2.heure_fin) as fin
from planning.affectation a1
join planning.seance s1 on s1.id = a1.seance_id and s1.statut = 'prevue' and s1.supprimee_le is null
join planning.affectation a2 on a2.personne_id = a1.personne_id and a2.seance_id <> a1.seance_id
join planning.seance s2 on s2.id = a2.seance_id and s2.statut = 'prevue' and s2.supprimee_le is null
where s2.date_seance = s1.date_seance
  and s1.heure_debut < s2.heure_fin and s2.heure_debut < s1.heure_fin
union all
select a.personne_id, s.date_seance, 'indisponibilite', s.id, null, i.id,
       greatest(s.heure_debut, coalesce(i.heure_debut, '00:00')), least(s.heure_fin, coalesce(i.heure_fin, '23:59:59'))
from planning.affectation a
join planning.seance s on s.id = a.seance_id and s.statut = 'prevue' and s.supprimee_le is null
join planning.indisponibilite i on i.personne_id = a.personne_id
where s.date_seance between i.date_debut and i.date_fin
  and (i.jours is null or extract(isodow from s.date_seance)::smallint = any (i.jours))
  and (i.heure_debut is null or (s.heure_debut < i.heure_fin and i.heure_debut < s.heure_fin));

create function planning.supprimer_seance(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s record; v_avant jsonb;
begin
  select * into s from planning.seance where id = (p->>'seance_id')::bigint and supprimee_le is null for update;
  if s.id is null then raise exception 'Séance introuvable'; end if;
  perform planning.exiger_atelier(p_droits, planning.atelier_de_seance(s.id));
  v_avant := to_jsonb(s) || jsonb_build_object('personnes',
    (select coalesce(jsonb_agg(a.personne_id), '[]') from planning.affectation a where a.seance_id = s.id));
  if s.serie_id is null then
    delete from planning.seance where id = s.id;
  else
    update planning.seance set supprimee_le = now(), modifiee = true, modifie_le = now() where id = s.id;
  end if;
  perform planning.noter(p_identite, 'seance', s.id, 'supprimer', v_avant, null);
  return jsonb_build_object('seance_id', s.id);
end $$;

-- Aiguillage : on ajoute l'action (le reste est inchangé).
create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_droits jsonb := planning.droits(p_identite);
begin
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel());
  elsif p_action = 'semaine' then
    return planning.lire_semaine(coalesce((p_params->>'lundi')::date, date_trunc('week', current_date)::date));
  end if;
  if v_droits->>'niveau' in ('consultation', 'collaborateur') then
    raise exception 'Accès en consultation : modification impossible';
  end if;
  case p_action
    when 'seance_creer'     then return planning.creer_seance(p_identite, v_droits, p_params);
    when 'seance_modifier'  then return planning.modifier_seance(p_identite, v_droits, p_params);
    when 'seance_supprimer' then return planning.supprimer_seance(p_identite, v_droits, p_params);
    when 'serie_creer'      then return planning.creer_serie(p_identite, v_droits, p_params);
    when 'serie_arreter'    then return planning.arreter_serie(p_identite, v_droits, p_params);
    when 'affecter'         then return planning.changer_affectation(p_identite, v_droits, p_params, true);
    when 'retirer'          then return planning.changer_affectation(p_identite, v_droits, p_params, false);
    when 'suspendre'        then return planning.changer_statut(p_identite, v_droits, p_params, true);
    when 'reprendre'        then return planning.changer_statut(p_identite, v_droits, p_params, false);
    when 'jour_fermer'      then return planning.fermer_jour(p_identite, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
end $$;

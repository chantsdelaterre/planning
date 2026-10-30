-- portee: planning
-- La répétition se règle dans la fenêtre de modification :
--  - une séance isolée peut devenir une série (jours + fin facultative) ;
--  - les jours et la fin d'une série se modifient, pour cette séance et les suivantes.

create or replace function planning.modifier_seance(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s record; v_avant jsonb; v_date date; v_debut time; v_fin time; v_portee text;
        se record; v_nouv bigint; v_tache bigint; v_societe text; v_pers bigint[]; v_decalage integer; v_n integer := 0; v_jours smallint[];
        v_jours_p smallint[]; v_fin_serie date; v_change_fin boolean := p ? 'date_fin_serie';
begin
  select * into s from planning.seance where id = (p->>'seance_id')::bigint and supprimee_le is null for update;
  if s.id is null then raise exception 'Séance introuvable'; end if;
  perform planning.exiger_atelier(p_droits, planning.atelier_de_seance(s.id));
  v_avant := to_jsonb(s);
  v_date  := coalesce((p->>'date')::date, s.date_seance);
  v_debut := coalesce((p->>'debut')::time, s.heure_debut);
  v_fin   := coalesce((p->>'fin')::time, s.heure_fin);
  if v_fin <= v_debut then raise exception 'La fin doit être après le début'; end if;
  v_portee := coalesce(p->>'portee', 'seance');
  -- Changement de tâche : droits sur le nouvel atelier, société de ce nouvel atelier.
  v_tache := coalesce((p->>'tache_id')::bigint, s.tache_id);
  select at.societe into v_societe from planning.tache t join planning.atelier at on at.id = t.atelier_id
   where t.id = v_tache and (t.archive_le is null or t.id = s.tache_id);
  if v_societe is null then raise exception 'Tâche introuvable ou archivée'; end if;
  -- Liste complète des personnes (facultative) : remplace les affectations.
  if p ? 'personnes' then
    select coalesce(array_agg(distinct x::bigint), '{}') into v_pers from jsonb_array_elements_text(p->'personnes') x;
  end if;
  if v_tache <> s.tache_id then
    perform planning.exiger_atelier(p_droits, (select atelier_id from planning.tache where id = v_tache));
  end if;
  -- Répétition (facultative) : jours de la semaine (1 = lundi) et date de fin de la série.
  if p ? 'jours' then
    select array_agg(distinct x::smallint order by x::smallint) into v_jours_p from jsonb_array_elements_text(p->'jours') x;
    if v_jours_p is null then raise exception 'Choisis au moins un jour'; end if;
    if exists (select 1 from unnest(v_jours_p) j where j not between 1 and 7) then raise exception 'Jour invalide'; end if;
  end if;
  if v_change_fin then
    v_fin_serie := nullif(p->>'date_fin_serie', '')::date;
    if v_fin_serie < v_date then raise exception 'La fin de la série doit être après la date de la séance'; end if;
  end if;

  -- Séance isolée qui devient une série : la série démarre à sa date, la séance isolée s'efface
  -- (elle est recréée par la série si son jour en fait partie).
  if s.serie_id is null and v_jours_p is not null then
    insert into planning.serie (tache_id, titre, lieu, jours, heure_debut, heure_fin, date_debut, date_fin, cree_par)
    values (v_tache,
            case when p ? 'titre' then nullif(p->>'titre', '') else s.titre end,
            case when p ? 'lieu' then nullif(p->>'lieu', '') else s.lieu end,
            v_jours_p, v_debut, v_fin, v_date, v_fin_serie, planning.qui(p_identite))
    returning id into v_nouv;
    insert into planning.serie_personne
      select v_nouv, x from unnest(coalesce(v_pers, (select array_agg(personne_id) from planning.affectation where seance_id = s.id), '{}')) x;
    delete from planning.seance where id = s.id;
    v_n := planning.generer_seances(greatest(current_date, v_date) + 56, v_date);
    perform planning.noter(p_identite, 'serie', v_nouv, 'creer', v_avant, p);
    return jsonb_build_object('serie_id', v_nouv, 'seances_creees', v_n);
  end if;
  -- Changer les jours ou la fin d'une série vaut forcément pour la suite.
  if s.serie_id is not null and (v_jours_p is not null or v_change_fin) then v_portee := 'suivantes'; end if;

  if v_portee = 'seance' or s.serie_id is null then
    update planning.seance
       set date_seance = v_date, heure_debut = v_debut, heure_fin = v_fin,
           tache_id = v_tache, societe = v_societe,
           titre = case when p ? 'titre' then nullif(p->>'titre', '') else titre end,
           lieu  = case when p ? 'lieu'  then nullif(p->>'lieu', '')  else lieu end,
           modifiee = true, modifie_le = now()
     where id = s.id;
    if v_societe is distinct from s.societe then
      -- Autre société : chaque personne est rattachée à la bonne fiche (mise à disposition ou non).
      update planning.affectation a set collab_id = f.collab_id, mad = coalesce(f.mad, false)
        from planning.affectation a2
        cross join lateral planning.fiche_imputee(a2.personne_id, v_societe, v_date) f
       where a2.seance_id = s.id and a.seance_id = a2.seance_id and a.personne_id = a2.personne_id;
    end if;
    if v_pers is not null then
      delete from planning.affectation where seance_id = s.id and personne_id <> all (v_pers);
      perform planning.affecter(s.id, x) from unnest(v_pers) x;
    end if;
    perform planning.noter(p_identite, 'seance', s.id, 'modifier', v_avant, p);
    return jsonb_build_object('seance_id', s.id);
  end if;

  if v_portee <> 'suivantes' then raise exception 'Portée inconnue : %', v_portee; end if;

  select * into se from planning.serie where id = s.serie_id for update;
  v_decalage := v_date - s.date_serie;  -- déplacement en jours (ex. mardi -> mercredi = 1)
  select array_agg(distinct (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint
                   order by (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint)
    into v_jours from unnest(se.jours) j;
  if v_jours_p is not null then v_jours := v_jours_p; end if;
  if not v_change_fin then v_fin_serie := se.date_fin; end if;

  -- Les séances de la série à partir de celle-ci, non retouchées à la main, sont retirées
  -- puis régénérées avec les nouveaux réglages. Celle qu'on modifie l'est aussi.
  delete from planning.seance
   where serie_id = se.id and date_serie >= s.date_serie and (not modifiee or id = s.id);

  if s.date_serie - 1 < se.date_debut
     or not exists (select 1 from planning.seance o where o.serie_id = se.id and o.date_serie < s.date_serie) then
    -- Première séance de la série : rien avant, on modifie la série sur place.
    update planning.serie
       set tache_id = v_tache, jours = v_jours, heure_debut = v_debut, heure_fin = v_fin,
           date_debut = se.date_debut + v_decalage, date_fin = v_fin_serie,
           titre = case when p ? 'titre' then nullif(p->>'titre', '') else titre end,
           lieu  = case when p ? 'lieu'  then nullif(p->>'lieu', '')  else lieu end
     where id = se.id;
    v_nouv := se.id;
    if v_pers is not null then
      delete from planning.serie_personne where serie_id = se.id;
      insert into planning.serie_personne select se.id, x from unnest(v_pers) x;
    end if;
  else
    -- Sinon : la série s'arrête la veille, une nouvelle reprend avec les nouveaux réglages.
    update planning.serie set date_fin = s.date_serie - 1 where id = se.id;
    insert into planning.serie (tache_id, titre, lieu, jours, heure_debut, heure_fin, date_debut, date_fin, cree_par)
    values (v_tache,
            case when p ? 'titre' then nullif(p->>'titre', '') else se.titre end,
            case when p ? 'lieu' then nullif(p->>'lieu', '') else se.lieu end,
            v_jours, v_debut, v_fin, s.date_serie + v_decalage, v_fin_serie, planning.qui(p_identite))
    returning id into v_nouv;
    if v_pers is not null then
      insert into planning.serie_personne select v_nouv, x from unnest(v_pers) x;
    else
      insert into planning.serie_personne select v_nouv, personne_id from planning.serie_personne where serie_id = se.id;
    end if;
  end if;

  v_n := planning.generer_seances(greatest(current_date, s.date_serie) + 56, s.date_serie + least(v_decalage, 0));
  perform planning.noter(p_identite, 'serie', se.id, case when v_nouv = se.id then 'modifier' else 'couper' end,
                         v_avant, p || jsonb_build_object('serie', v_nouv));
  return jsonb_build_object('serie_id', v_nouv, 'seances_creees', v_n);
end $$;


-- La vue expose les jours et la fin de la série (affichés dans la fenêtre de modification).
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
       s.titre as complement,
       sr.jours as serie_jours, sr.date_fin as serie_fin
from planning.seance s
left join planning.serie sr on sr.id = s.serie_id
join planning.tache t on t.id = s.tache_id
left join planning.regroupement r on r.id = t.regroupement_id
join planning.atelier at on at.id = t.atelier_id
join planning.activite ac on ac.id = at.activite_id
where s.supprimee_le is null;

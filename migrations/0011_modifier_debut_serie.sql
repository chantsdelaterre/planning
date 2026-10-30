-- portee: planning
-- Correctif : « cette séance et les suivantes » sur la PREMIÈRE séance d'une série échouait
-- (la série était coupée la veille de son propre début : fin < début, refusé par la base).
-- Dans ce cas, il n'y a rien à garder avant : la série est modifiée sur place.
-- Aussi : une erreur inattendue renvoie désormais son code (sans donnée) au lieu de « Erreur base ».

create or replace function planning.modifier_seance(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s record; v_avant jsonb; v_date date; v_debut time; v_fin time; v_portee text;
        se record; v_nouv bigint; v_decalage integer; v_n integer := 0; v_jours smallint[];
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

  if v_portee = 'seance' or s.serie_id is null then
    update planning.seance
       set date_seance = v_date, heure_debut = v_debut, heure_fin = v_fin,
           titre = case when p ? 'titre' then nullif(p->>'titre', '') else titre end,
           lieu  = case when p ? 'lieu'  then nullif(p->>'lieu', '')  else lieu end,
           modifiee = true, modifie_le = now()
     where id = s.id;
    perform planning.noter(p_identite, 'seance', s.id, 'modifier', v_avant, p);
    return jsonb_build_object('seance_id', s.id);
  end if;

  if v_portee <> 'suivantes' then raise exception 'Portée inconnue : %', v_portee; end if;

  select * into se from planning.serie where id = s.serie_id for update;
  v_decalage := v_date - s.date_serie;  -- déplacement en jours (ex. mardi -> mercredi = 1)
  select array_agg(distinct (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint
                   order by (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint)
    into v_jours from unnest(se.jours) j;

  -- Les séances de la série à partir de celle-ci, non retouchées à la main, sont retirées
  -- puis régénérées avec les nouveaux réglages. Celle qu'on modifie l'est aussi.
  delete from planning.seance
   where serie_id = se.id and date_serie >= s.date_serie and (not modifiee or id = s.id);

  if s.date_serie - 1 < se.date_debut
     or not exists (select 1 from planning.seance o where o.serie_id = se.id and o.date_serie < s.date_serie) then
    -- Première séance de la série : rien avant, on modifie la série sur place.
    update planning.serie
       set jours = v_jours, heure_debut = v_debut, heure_fin = v_fin,
           date_debut = se.date_debut + v_decalage,
           titre = case when p ? 'titre' then nullif(p->>'titre', '') else titre end,
           lieu  = case when p ? 'lieu'  then nullif(p->>'lieu', '')  else lieu end
     where id = se.id;
    v_nouv := se.id;
  else
    -- Sinon : la série s'arrête la veille, une nouvelle reprend avec les nouveaux réglages.
    update planning.serie set date_fin = s.date_serie - 1 where id = se.id;
    insert into planning.serie (tache_id, titre, lieu, jours, heure_debut, heure_fin, date_debut, date_fin, cree_par)
    values (se.tache_id,
            case when p ? 'titre' then nullif(p->>'titre', '') else se.titre end,
            case when p ? 'lieu' then nullif(p->>'lieu', '') else se.lieu end,
            v_jours, v_debut, v_fin, s.date_serie + v_decalage, se.date_fin, planning.qui(p_identite))
    returning id into v_nouv;
    insert into planning.serie_personne select v_nouv, personne_id from planning.serie_personne where serie_id = se.id;
  end if;

  v_n := planning.generer_seances(greatest(current_date, s.date_serie) + 56, s.date_serie + least(v_decalage, 0));
  perform planning.noter(p_identite, 'serie', se.id, case when v_nouv = se.id then 'modifier' else 'couper' end,
                         v_avant, p || jsonb_build_object('serie', v_nouv));
  return jsonb_build_object('serie_id', v_nouv, 'seances_creees', v_n);
end $$;

-- Aiguillage : une erreur inattendue renvoie un message utile (code d'erreur, jamais de donnée).
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
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

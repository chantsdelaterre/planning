-- portee: planning
-- Vue « Par personne » : les créneaux réellement saisis dans Suivi des temps pour une semaine,
-- à côté des séances prévues. Un collaborateur ne lit que les siens.

create function planning.lire_realise(p_droits jsonb, p_personne bigint, p_lundi date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_personne is null or p_lundi is null then raise exception 'Personne ou semaine manquante'; end if;
  if p_droits->>'niveau' = 'collaborateur' and p_personne is distinct from (p_droits->>'personne_id')::bigint then
    raise exception 'Tu ne peux voir que tes propres heures'; end if;
  return jsonb_build_object('personne_id', p_personne, 'lundi', p_lundi,
    -- Une ligne par fiche et par jour saisi (une personne à deux fiches peut en avoir deux).
    'jours', (select coalesce(jsonb_agg(jsonb_build_object('date', r.date_jour, 'collab_id', r.collab_id, 'type', r.type_jour,
                 'heures', r.heures, 'creneaux', (select coalesce(jsonb_agg(jsonb_build_array(c.d, c.f)), '[]')
                    from (values (r.c1_debut, r.c1_fin), (r.c2_debut, r.c2_fin), (r.c3_debut, r.c3_fin)) c(d, f)
                   where c.d ~ '^\d{1,2}:\d{2}' and c.f ~ '^\d{1,2}:\d{2}')) order by r.date_jour, r.collab_id), '[]')
              from planning.v_realise_jour r
              where r.personne_id = p_personne and r.date_jour between p_lundi and p_lundi + 6));
end $$;

-- Aiguillage : lecture « realise ».
create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_droits jsonb := planning.droits(p_identite);
begin
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel());
  elsif p_action = 'recap' then
    return planning.lire_recap(v_droits, (p_params->>'debut')::date, (p_params->>'fin')::date);
  elsif p_action = 'semaine' then
    return planning.lire_semaine(coalesce((p_params->>'lundi')::date, date_trunc('week', current_date)::date));
  end if;
  if p_action = 'realise' then
    return planning.lire_realise(v_droits, (p_params->>'personne_id')::bigint, (p_params->>'lundi')::date);
  end if;
  if p_action = 'admin_lire' then
    if v_droits->>'niveau' not in ('complet', 'consultation') then raise exception 'Réservé aux administrateurs'; end if;
    return planning.admin_lire();
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
    when 'personne_creer'    then return planning.personne_creer(p_identite, v_droits, p_params);
    when 'personne_modifier' then return planning.personne_modifier(p_identite, v_droits, p_params);
    when 'personne_archiver' then return planning.personne_archiver(p_identite, v_droits, p_params);
    when 'personne_rattacher' then return planning.personne_rattacher(p_identite, v_droits, p_params);
    when 'ref_enregistrer'   then return planning.ref_enregistrer(p_identite, v_droits, p_params);
    when 'ref_archiver'      then return planning.ref_archiver(p_identite, v_droits, p_params);
    when 'responsable'       then return planning.changer_responsable(p_identite, v_droits, p_params);
    when 'habituel'          then return planning.changer_habituel(p_identite, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

-- portee: planning
-- Import de séances en lot (depuis un agenda extérieur) : une séance par ligne, réservé aux accès
-- complets. Chaque ligne passe par la création habituelle (droits, société, fiche imputée) ; les règles
-- de durée sont contrôlées une fois pour tout le lot par l'aiguillage.

create function planning.importer_seances(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l jsonb; n integer := 0;
begin
  perform planning.exiger_complet(p_droits);
  if jsonb_typeof(p->'lignes') <> 'array' then raise exception 'Aucune ligne à importer'; end if;
  if jsonb_array_length(p->'lignes') > 2000 then raise exception 'Trop de lignes : 2000 au plus par import'; end if;
  for l in select * from jsonb_array_elements(p->'lignes') loop
    perform planning.creer_seance(p_identite, p_droits, jsonb_build_object(
      'tache_id', l->'tache_id', 'date', l->>'date', 'debut', l->>'debut', 'fin', l->>'fin',
      'titre', coalesce(l->>'titre', ''), 'personnes', coalesce(l->'personnes', '[]'::jsonb)));
    n := n + 1;
  end loop;
  perform planning.noter(p_identite, 'import', null, 'importer', null, jsonb_build_object('lignes', n, 'source', p->>'source'));
  return jsonb_build_object('seances_creees', n);
end $$;

-- Aiguillage : import en lot.
create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ident jsonb := planning.resoudre_identite(p_identite);
        v_droits jsonb := planning.droits(v_ident);
        v_res jsonb; v_avant text[]; v_nouv jsonb;
begin
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel_vue(v_droits),
      'alertes_non_vues', case when v_droits->>'niveau' in ('complet', 'consultation') then (select count(*) from planning.alerte where vue_le is null) end);
  elsif p_action = 'recap' then
    return planning.lire_recap(v_droits, (p_params->>'debut')::date, (p_params->>'fin')::date);
  elsif p_action = 'semaine' then
    return planning.lire_semaine_vue(v_droits, coalesce((p_params->>'lundi')::date, date_trunc('week', current_date)::date));
  end if;
  if p_action = 'realise' then
    if not planning.personne_visible(v_droits, (p_params->>'personne_id')::bigint, (p_params->>'lundi')::date, (p_params->>'lundi')::date + 6) then
      raise exception 'Tu ne peux pas voir les heures de cette personne'; end if;
    return planning.lire_realise(v_droits, (p_params->>'personne_id')::bigint, (p_params->>'lundi')::date);
  end if;
  if p_action = 'alertes_lire' then
    if v_droits->>'niveau' not in ('complet', 'consultation') then raise exception 'Réservé aux administrateurs'; end if;
    return planning.alertes_lire();
  end if;
  if p_action = 'admin_lire' then
    if v_droits->>'niveau' not in ('complet', 'consultation') then raise exception 'Réservé aux administrateurs'; end if;
    return planning.admin_lire() || planning.admin_lire_acces() || planning.admin_lire_liens();
  end if;
  if v_droits->>'niveau' in ('consultation', 'collaborateur') then
    raise exception 'Accès en consultation : modification impossible';
  end if;
  v_avant := planning.cles_infractions();
  case p_action
    when 'seance_creer'     then v_res := planning.creer_seance(v_ident, v_droits, p_params);
    when 'seance_modifier'  then v_res := planning.modifier_seance(v_ident, v_droits, p_params);
    when 'seance_supprimer' then v_res := planning.supprimer_seance(v_ident, v_droits, p_params);
    when 'serie_creer'      then v_res := planning.creer_serie(v_ident, v_droits, p_params);
    when 'serie_arreter'    then v_res := planning.arreter_serie(v_ident, v_droits, p_params);
    when 'affecter'         then v_res := planning.changer_affectation(v_ident, v_droits, p_params, true);
    when 'retirer'          then v_res := planning.changer_affectation(v_ident, v_droits, p_params, false);
    when 'suspendre'        then v_res := planning.changer_statut(v_ident, v_droits, p_params, true);
    when 'reprendre'        then v_res := planning.changer_statut(v_ident, v_droits, p_params, false);
    when 'jour_fermer'      then v_res := planning.fermer_jour(v_ident, v_droits, p_params);
    when 'personne_creer'    then v_res := planning.personne_creer(v_ident, v_droits, p_params);
    when 'personne_modifier' then v_res := planning.personne_modifier(v_ident, v_droits, p_params);
    when 'personne_archiver' then v_res := planning.personne_archiver(v_ident, v_droits, p_params);
    when 'personne_rattacher' then v_res := planning.personne_rattacher(v_ident, v_droits, p_params);
    when 'ref_enregistrer'   then v_res := planning.ref_enregistrer(v_ident, v_droits, p_params);
    when 'ref_archiver'      then v_res := planning.ref_archiver(v_ident, v_droits, p_params);
    when 'responsable'       then v_res := planning.changer_responsable(v_ident, v_droits, p_params);
    when 'habituel'          then v_res := planning.changer_habituel(v_ident, v_droits, p_params);
    when 'acces_regler'      then v_res := planning.acces_regler(v_ident, v_droits, p_params);
    when 'lien_generer'      then v_res := planning.lien_generer(v_ident, v_droits, p_params);
    when 'lien_revoquer'     then v_res := planning.lien_revoquer(v_ident, v_droits, p_params);
    when 'admin_niveau'      then v_res := planning.admin_niveau(v_ident, v_droits, p_params);
    when 'alertes_vues'      then v_res := planning.alertes_vues(v_ident, v_droits, p_params);
    when 'import_seances'    then v_res := planning.importer_seances(v_ident, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
  -- Règles de durée : une action qui crée une nouvelle infraction est annulée, sauf forçage
  -- (alors inscrite aux alertes, pour les administrateurs).
  v_nouv := planning.nouvelles_infractions(v_avant);
  if jsonb_array_length(v_nouv) > 0 then
    if not coalesce((p_params->>'forcer')::boolean, false) then
      raise exception 'REGLES|%', v_nouv::text;
    end if;
    insert into planning.alerte (qui, action, motif, personne_id, date_jour, regle, detail)
    select planning.qui(v_ident), p_action, nullif(p_params->>'motif', ''), (x->>'personne_id')::bigint, (x->>'date')::date, x->>'regle', x->>'detail'
      from jsonb_array_elements(v_nouv) x;
  end if;
  return v_res;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

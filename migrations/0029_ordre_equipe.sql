-- portee: planning
-- Vue Équipe : ordre des personnes réglé à la main, par atelier (partagé par tous ceux qui
-- regardent cet atelier). Réglable par un responsable de l'atelier ou un accès complet.
-- La session renvoie aussi le nom de la personne connectée (en-tête de la page).

create table planning.ordre_equipe (
  atelier_id  bigint not null references planning.atelier,
  personne_id bigint not null references public.personne (personne_id) on delete cascade,
  rang        integer not null,
  primary key (atelier_id, personne_id)
);
alter table planning.ordre_equipe enable row level security;

create function planning.ordre_equipe_regler(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_at bigint := (p->>'atelier_id')::bigint;
begin
  perform planning.exiger_atelier(p_droits, v_at);
  if jsonb_typeof(p->'personnes') is distinct from 'array' then raise exception 'Liste de personnes attendue'; end if;
  delete from planning.ordre_equipe where atelier_id = v_at;
  insert into planning.ordre_equipe (atelier_id, personne_id, rang)
  select v_at, x.v::bigint, min(x.n)::int from jsonb_array_elements_text(p->'personnes') with ordinality x(v, n)
   where exists (select 1 from public.personne q where q.personne_id = x.v::bigint)
   group by x.v::bigint;
  return jsonb_build_object('atelier_id', v_at);
end $$;

create function planning.nom_connecte(p_identite jsonb) returns text
language sql stable security definer set search_path = '' as $$
  select case p_identite->>'type'
    when 'admin' then (select a.nom from public.admins a where a.admin_id::text = p_identite->>'admin_id')
    else (select q.prenom || ' ' || q.nom from public.personne q where q.personne_id = (p_identite->>'personne_id')::bigint) end;
$$;

create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ident jsonb := planning.resoudre_identite(p_identite);
        v_droits jsonb := planning.droits(v_ident);
        v_res jsonb; v_avant text[]; v_nouv jsonb;
begin
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel_vue(v_droits),
      'nom', planning.nom_connecte(v_ident),
      'ordres', (select coalesce(jsonb_agg(jsonb_build_array(atelier_id, personne_id, rang) order by atelier_id, rang), '[]') from planning.ordre_equipe),
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
    when 'personne_couleur'  then v_res := planning.personne_couleur(v_ident, v_droits, p_params);
    when 'ordre_equipe'      then v_res := planning.ordre_equipe_regler(v_ident, v_droits, p_params);
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

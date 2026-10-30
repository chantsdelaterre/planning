-- portee: planning
-- Liens planning pour les administrateurs (même principe que pour les personnes : jeton propre au
-- planning, empreinte seule, révocable ; mort si l'administrateur est désactivé dans Suivi des temps).
-- Niveau d'un administrateur (complet ou consultation) réglable dans l'écran Accès.

alter table planning.lien alter column personne_id drop not null;
alter table planning.lien add column admin_id text;
alter table planning.lien add constraint lien_un_titulaire check (num_nonnulls(personne_id, admin_id) = 1);
create unique index lien_un_actif_admin on planning.lien (admin_id) where revoque_le is null;

create or replace function planning.resoudre_identite(p_identite jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_lien record;
begin
  if p_identite->>'type' <> 'lien' then return p_identite; end if;
  select * into v_lien from planning.lien
   where empreinte = planning.empreinte(coalesce(p_identite->>'jeton', '')) and revoque_le is null;
  if v_lien.id is null then raise exception 'lien_invalide'; end if;
  if v_lien.admin_id is not null then
    if not exists (select 1 from public.admins a where a.admin_id = v_lien.admin_id and a.actif) then raise exception 'lien_invalide'; end if;
  elsif not planning.lien_valide(v_lien.personne_id) then
    raise exception 'lien_invalide';
  end if;
  update planning.lien set dernier_usage = now() where id = v_lien.id and (dernier_usage is null or dernier_usage < now() - interval '10 minutes');
  if v_lien.admin_id is not null then
    return jsonb_build_object('type', 'admin', 'admin_id', v_lien.admin_id, 'par_lien', true);
  end if;
  return jsonb_build_object('type', 'collab', 'personne_id', v_lien.personne_id, 'par_lien', true);
end $$;

create or replace function planning.lien_generer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint; v_a text := nullif(p->>'admin_id', ''); v_jeton text;
begin
  perform planning.exiger_complet(p_droits);
  if v_a is not null then
    if not exists (select 1 from public.admins a where a.admin_id = v_a and a.actif) then raise exception 'Administrateur inconnu ou désactivé'; end if;
    update planning.lien set revoque_le = now() where admin_id = v_a and revoque_le is null;
  else
    if not planning.lien_valide(v_p) then raise exception 'Cette personne n''a pas de fiche active : son lien ne fonctionnerait pas'; end if;
    update planning.lien set revoque_le = now() where personne_id = v_p and revoque_le is null;
  end if;
  v_jeton := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into planning.lien (personne_id, admin_id, empreinte, cree_par)
  values (case when v_a is null then v_p end, v_a, planning.empreinte(v_jeton), planning.qui(p_identite));
  perform planning.noter(p_identite, 'lien', v_p, 'generer', null, case when v_a is not null then jsonb_build_object('admin_id', v_a) end);
  return jsonb_build_object('personne_id', v_p, 'admin_id', v_a, 'jeton', v_jeton);
end $$;

create or replace function planning.lien_revoquer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint; v_a text := nullif(p->>'admin_id', '');
begin
  perform planning.exiger_complet(p_droits);
  update planning.lien set revoque_le = now()
   where revoque_le is null and (case when v_a is not null then admin_id = v_a else personne_id = v_p end);
  perform planning.noter(p_identite, 'lien', v_p, 'revoquer', null, case when v_a is not null then jsonb_build_object('admin_id', v_a) end);
  return jsonb_build_object('personne_id', v_p, 'admin_id', v_a);
end $$;

-- Niveau d'un administrateur. On ne peut pas retirer le dernier accès complet.
create function planning.admin_niveau(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_a text := p->>'admin_id'; v_n text := p->>'niveau';
begin
  perform planning.exiger_complet(p_droits);
  if v_n not in ('complet', 'consultation') then raise exception 'Niveau inconnu'; end if;
  if not exists (select 1 from public.admins where admin_id = v_a) then raise exception 'Administrateur inconnu'; end if;
  if v_n = 'consultation' and not exists (select 1 from planning.acces_admin where niveau = 'complet' and admin_id <> v_a) then
    raise exception 'Il faut garder au moins un accès complet'; end if;
  insert into planning.acces_admin (admin_id, niveau) values (v_a, v_n) on conflict (admin_id) do update set niveau = excluded.niveau;
  perform planning.noter(p_identite, 'acces_admin', null, 'niveau', null, p);
  return jsonb_build_object('admin_id', v_a, 'niveau', v_n);
end $$;

create or replace function planning.admin_lire_liens() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'liens', (select coalesce(jsonb_agg(jsonb_build_object('personne_id', personne_id, 'admin_id', admin_id, 'cree_le', cree_le,
               'dernier_usage', dernier_usage,
               'valide', case when admin_id is not null then exists (select 1 from public.admins a where a.admin_id = l.admin_id and a.actif)
                              else planning.lien_valide(personne_id) end)), '[]')
              from planning.lien l where revoque_le is null),
    -- Administrateurs actifs de Suivi des temps : nom et niveau dans le planning (sans ligne = consultation).
    'admins', (select coalesce(jsonb_agg(jsonb_build_object('admin_id', a.admin_id, 'nom', a.nom, 'niveau', coalesce(x.niveau, 'consultation'))
                 order by a.nom), '[]')
               from public.admins a left join planning.acces_admin x on x.admin_id = a.admin_id where a.actif));
$$;

-- Aiguillage : niveau des administrateurs.
create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ident jsonb := planning.resoudre_identite(p_identite);
        v_droits jsonb := planning.droits(v_ident);
begin
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel_vue(v_droits));
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
  if p_action = 'admin_lire' then
    if v_droits->>'niveau' not in ('complet', 'consultation') then raise exception 'Réservé aux administrateurs'; end if;
    return planning.admin_lire() || planning.admin_lire_acces() || planning.admin_lire_liens();
  end if;
  if v_droits->>'niveau' in ('consultation', 'collaborateur') then
    raise exception 'Accès en consultation : modification impossible';
  end if;
  case p_action
    when 'seance_creer'     then return planning.creer_seance(v_ident, v_droits, p_params);
    when 'seance_modifier'  then return planning.modifier_seance(v_ident, v_droits, p_params);
    when 'seance_supprimer' then return planning.supprimer_seance(v_ident, v_droits, p_params);
    when 'serie_creer'      then return planning.creer_serie(v_ident, v_droits, p_params);
    when 'serie_arreter'    then return planning.arreter_serie(v_ident, v_droits, p_params);
    when 'affecter'         then return planning.changer_affectation(v_ident, v_droits, p_params, true);
    when 'retirer'          then return planning.changer_affectation(v_ident, v_droits, p_params, false);
    when 'suspendre'        then return planning.changer_statut(v_ident, v_droits, p_params, true);
    when 'reprendre'        then return planning.changer_statut(v_ident, v_droits, p_params, false);
    when 'jour_fermer'      then return planning.fermer_jour(v_ident, v_droits, p_params);
    when 'personne_creer'    then return planning.personne_creer(v_ident, v_droits, p_params);
    when 'personne_modifier' then return planning.personne_modifier(v_ident, v_droits, p_params);
    when 'personne_archiver' then return planning.personne_archiver(v_ident, v_droits, p_params);
    when 'personne_rattacher' then return planning.personne_rattacher(v_ident, v_droits, p_params);
    when 'ref_enregistrer'   then return planning.ref_enregistrer(v_ident, v_droits, p_params);
    when 'ref_archiver'      then return planning.ref_archiver(v_ident, v_droits, p_params);
    when 'responsable'       then return planning.changer_responsable(v_ident, v_droits, p_params);
    when 'habituel'          then return planning.changer_habituel(v_ident, v_droits, p_params);
    when 'acces_regler'      then return planning.acces_regler(v_ident, v_droits, p_params);
    when 'lien_generer'      then return planning.lien_generer(v_ident, v_droits, p_params);
    when 'lien_revoquer'     then return planning.lien_revoquer(v_ident, v_droits, p_params);
    when 'admin_niveau'      then return planning.admin_niveau(v_ident, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

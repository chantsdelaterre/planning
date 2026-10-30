-- portee: planning
-- Règles de durée, par personne et par jour, toutes séances confondues (décidées par Coco le 30/10) :
--  - plus de 6 h de travail d'affilée sans coupure d'au moins 30 min : « pause obligatoire » ;
--  - plus de 10 h dans la journée : « maximum journalier ».
-- Contrôlées à chaque modification, sur les jours à venir : une action qui crée une nouvelle infraction
-- est refusée, sauf forçage ; un forçage est inscrit aux alertes pour les administrateurs.

create table planning.alerte (
  id          bigint generated always as identity primary key,
  quand       timestamptz not null default now(),
  qui         text not null,
  action      text,
  motif       text,
  personne_id bigint references public.personne (personne_id) on delete cascade,
  date_jour   date not null,
  regle       text not null check (regle in ('pause', 'max_jour')),
  detail      text,
  vue_le      timestamptz,
  vue_par     text
);
alter table planning.alerte enable row level security;

-- Durée lisible : 6,75 -> « 6 h 45 ».
create function planning.hm(h numeric) returns text
language sql immutable set search_path = '' as $$
  select floor(h)::int || ' h' || case when round((h - floor(h)) * 60) > 0 then ' ' || to_char(round((h - floor(h)) * 60), 'FM00') else '' end;
$$;

-- Infractions sur une période. Seuils : 6 h d'affilée, coupure de 30 min, 10 h par jour.
create function planning.infractions(p_debut date, p_fin date)
returns table (personne_id bigint, date_jour date, regle text, detail text)
language sql stable security definer set search_path = '' as $$
  with t as (
    select a.personne_id, s.date_seance as d, s.heure_debut as deb, s.heure_fin as fin
    from planning.affectation a join planning.seance s on s.id = a.seance_id
    where s.statut = 'prevue' and s.supprimee_le is null and s.date_seance between p_debut and p_fin),
  prec as (
    select *, max(fin) over (partition by personne_id, d order by deb, fin rows between unbounded preceding and 1 preceding) as fin_prec
    from t),
  blocs as (
    select *, sum(case when fin_prec is null or deb >= fin_prec + interval '30 minutes' then 1 else 0 end)
                over (partition by personne_id, d order by deb, fin) as bloc
    from prec),
  -- Temps travaillé d'un bloc = étendue moins les petites coupures (< 30 min), sans compter deux fois un recouvrement.
  b as (
    select personne_id, d, bloc, min(deb) as deb, max(fin) as fin,
           extract(epoch from (max(fin) - min(deb)) - sum(case when fin_prec is not null and deb > fin_prec and deb < fin_prec + interval '30 minutes' then deb - fin_prec else interval '0' end)) / 3600.0 as h
    from blocs group by personne_id, d, bloc)
  select personne_id, d, 'pause', 'Pause obligatoire au bout de 6 h : ' || planning.hm(h) || ' d''affilée (' || to_char(deb, 'HH24:MI') || '–' || to_char(fin, 'HH24:MI') || ')'
    from b where h > 6
  union all
  select personne_id, d, 'max_jour', 'Plus de 10 h dans la journée : ' || planning.hm(sum(h))
    from b group by personne_id, d having sum(h) > 10;
$$;

-- Clés des infractions à venir (aujourd'hui et après).
create function planning.cles_infractions() returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(personne_id || '|' || date_jour || '|' || regle), '{}')
  from planning.infractions(current_date, current_date + 400);
$$;

-- Infractions à venir qui n'existaient pas avant l'action.
create function planning.nouvelles_infractions(p_avant text[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('personne_id', i.personne_id, 'nom', p.prenom || ' ' || p.nom,
           'date', i.date_jour, 'regle', i.regle, 'detail', i.detail) order by i.date_jour, p.prenom), '[]')
  from planning.infractions(current_date, current_date + 400) i
  join public.personne p on p.personne_id = i.personne_id
  where not (i.personne_id || '|' || i.date_jour || '|' || i.regle) = any (p_avant);
$$;

create function planning.alertes_lire() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('alertes', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'quand', a.quand, 'qui', a.qui,
           'qui_nom', coalesce((select ad.nom from public.admins ad where 'admin:' || ad.admin_id = a.qui),
                               (select q.prenom || ' ' || q.nom from public.personne q where 'personne:' || q.personne_id = a.qui), a.qui),
           'action', a.action, 'motif', a.motif, 'personne_id', a.personne_id, 'personne', p.prenom || ' ' || p.nom,
           'date', a.date_jour, 'regle', a.regle, 'detail', a.detail, 'vue', a.vue_le is not null) order by a.quand desc), '[]')
         from planning.alerte a left join public.personne p on p.personne_id = a.personne_id
         where a.quand > now() - interval '120 days'));
$$;

create function planning.alertes_vues(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform planning.exiger_complet(p_droits);
  update planning.alerte set vue_le = now(), vue_par = planning.qui(p_identite) where vue_le is null;
  return '{}'::jsonb;
end $$;

-- Aiguillage : contrôle des règles après chaque action, alertes.
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

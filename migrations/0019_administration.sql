-- portee: planning
-- Administration : personnes sans fiche (à venir, externes) et leur rattachement à la vraie
-- personne quand la fiche est créée dans Suivi des temps ; référentiel (activités, ateliers,
-- tâches, regroupements) ; responsables d'atelier ; ateliers habituels.

-- Ce que le planning sait d'une personne sans fiche.
create table planning.personne_planning (
  personne_id bigint primary key references public.personne (personne_id) on delete cascade,
  nature      text not null default 'a_venir' check (nature in ('a_venir', 'externe')),
  cree_par    text,
  cree_le     timestamptz not null default now(),
  archive_le  timestamptz
);
alter table planning.personne_planning enable row level security;

create function planning.exiger_complet(p_droits jsonb) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_droits->>'niveau' <> 'complet' then raise exception 'Réservé aux accès complets'; end if;
end $$;

create function planning.sans_accent(t text) returns text
language sql immutable set search_path = '' as $$
  select lower(translate(btrim(t), 'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇàâäéèêëîïôöùûüç', 'AAAEEEEIIOOUUUCaaaeeeeiioouuuc'));
$$;

-- Personnes sans fiche ------------------------------------------------------------------------
create function planning.personne_creer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_prenom text := btrim(coalesce(p->>'prenom', '')); v_nom text := btrim(coalesce(p->>'nom', ''));
begin
  if p_droits->>'niveau' not in ('complet', 'responsable') then raise exception 'Réservé aux responsables et aux accès complets'; end if;
  if v_prenom = '' then raise exception 'Le prénom est obligatoire'; end if;
  insert into public.personne (prenom, nom, externe) values (v_prenom, v_nom, true) returning personne_id into v_id;
  insert into planning.personne_planning (personne_id, nature, cree_par)
  values (v_id, coalesce(nullif(p->>'nature', ''), 'a_venir'), planning.qui(p_identite));
  perform planning.noter(p_identite, 'personne', v_id, 'creer', null, p);
  return jsonb_build_object('personne_id', v_id);
end $$;

create function planning.personne_modifier(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id bigint := (p->>'personne_id')::bigint; v_avant jsonb;
begin
  if p_droits->>'niveau' not in ('complet', 'responsable') then raise exception 'Réservé aux responsables et aux accès complets'; end if;
  select to_jsonb(x) into v_avant from public.personne x where personne_id = v_id and externe;
  if v_avant is null then raise exception 'Seule une personne sans fiche se modifie ici'; end if;
  if p ? 'prenom' and btrim(p->>'prenom') = '' then raise exception 'Le prénom est obligatoire'; end if;
  update public.personne
     set prenom = case when p ? 'prenom' then btrim(p->>'prenom') else prenom end,
         nom    = case when p ? 'nom' then btrim(coalesce(p->>'nom', '')) else nom end
   where personne_id = v_id;
  insert into planning.personne_planning (personne_id, nature, cree_par) values (v_id, coalesce(nullif(p->>'nature', ''), 'a_venir'), planning.qui(p_identite))
  on conflict (personne_id) do update set nature = coalesce(nullif(p->>'nature', ''), planning.personne_planning.nature);
  perform planning.noter(p_identite, 'personne', v_id, 'modifier', v_avant, p);
  return jsonb_build_object('personne_id', v_id);
end $$;

create function planning.personne_archiver(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id bigint := (p->>'personne_id')::bigint; v_arch boolean := coalesce((p->>'archiver')::boolean, true);
begin
  perform planning.exiger_complet(p_droits);
  if not exists (select 1 from public.personne where personne_id = v_id and externe) then raise exception 'Seule une personne sans fiche s''archive ici'; end if;
  insert into planning.personne_planning (personne_id, nature) values (v_id, 'externe') on conflict (personne_id) do nothing;
  update planning.personne_planning set archive_le = case when v_arch then now() end where personne_id = v_id;
  perform planning.noter(p_identite, 'personne', v_id, case when v_arch then 'archiver' else 'restaurer' end, null, p);
  return jsonb_build_object('personne_id', v_id);
end $$;

-- Rattacher une personne sans fiche à la personne qui a désormais une fiche : tout son planning
-- (séances passées et futures, séries, ateliers, responsabilités, indisponibilités) passe sur la
-- vraie personne, les heures sont imputées sur la bonne fiche, puis la personne provisoire disparaît.
create function planning.personne_rattacher(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_src bigint := (p->>'source')::bigint; v_dst bigint := (p->>'cible')::bigint; v_avant jsonb; n integer;
begin
  perform planning.exiger_complet(p_droits);
  select to_jsonb(x) into v_avant from public.personne x where personne_id = v_src and externe;
  if v_avant is null or exists (select 1 from public.collaborateurs c where c.personne_id = v_src) then
    raise exception 'La personne à rattacher doit être sans fiche'; end if;
  if v_src = v_dst or not exists (select 1 from public.collaborateurs c where c.personne_id = v_dst) then
    raise exception 'Choisis une personne qui a une fiche dans Suivi des temps'; end if;
  -- Séances : si la vraie personne y est déjà, on garde sa ligne.
  delete from planning.affectation a where a.personne_id = v_src
     and exists (select 1 from planning.affectation b where b.seance_id = a.seance_id and b.personne_id = v_dst);
  update planning.affectation a set personne_id = v_dst, collab_id = f.collab_id, mad = coalesce(f.mad, false)
    from planning.seance s cross join lateral planning.fiche_imputee(v_dst, s.societe, s.date_seance) f
   where a.personne_id = v_src and s.id = a.seance_id;
  get diagnostics n = row_count;
  insert into planning.serie_personne select serie_id, v_dst from planning.serie_personne where personne_id = v_src on conflict do nothing;
  delete from planning.serie_personne where personne_id = v_src;
  insert into planning.personne_atelier select v_dst, atelier_id from planning.personne_atelier where personne_id = v_src on conflict do nothing;
  delete from planning.personne_atelier where personne_id = v_src;
  insert into planning.atelier_responsable select atelier_id, v_dst from planning.atelier_responsable where personne_id = v_src on conflict do nothing;
  delete from planning.atelier_responsable where personne_id = v_src;
  update planning.indisponibilite set personne_id = v_dst where personne_id = v_src;
  perform planning.noter(p_identite, 'personne', v_src, 'rattacher', v_avant, p || jsonb_build_object('seances', n));
  delete from public.personne where personne_id = v_src;
  return jsonb_build_object('personne_id', v_dst, 'seances', n);
end $$;

-- Référentiel ---------------------------------------------------------------------------------
create function planning.ref_enregistrer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_type text := p->>'type'; v_id bigint := nullif(p->>'id', '')::bigint; v_avant jsonb;
begin
  perform planning.exiger_complet(p_droits);
  if p ? 'nom' and btrim(coalesce(p->>'nom', '')) = '' then raise exception 'Le nom est obligatoire'; end if;
  if v_id is null and not p ? 'nom' then raise exception 'Le nom est obligatoire'; end if;
  if v_type = 'activite' then
    if v_id is null then
      insert into planning.activite (nom, ordre) values (btrim(p->>'nom'), coalesce((p->>'ordre')::int, 0)) returning id into v_id;
    else
      select to_jsonb(x) into v_avant from planning.activite x where id = v_id;
      update planning.activite set nom = case when p ? 'nom' then btrim(p->>'nom') else nom end,
                                   ordre = coalesce((p->>'ordre')::int, ordre) where id = v_id;
    end if;
  elsif v_type = 'atelier' then
    if v_id is null then
      insert into planning.atelier (activite_id, nom, societe, couleur, au_demarrage, ordre)
      values ((p->>'activite_id')::bigint, btrim(p->>'nom'), p->>'societe', coalesce(nullif(p->>'couleur', ''), '#6B7280'),
              coalesce((p->>'au_demarrage')::boolean, false), coalesce((p->>'ordre')::int, 0)) returning id into v_id;
    else
      select to_jsonb(x) into v_avant from planning.atelier x where id = v_id;
      update planning.atelier set
        nom = case when p ? 'nom' then btrim(p->>'nom') else nom end,
        activite_id = coalesce((p->>'activite_id')::bigint, activite_id),
        societe = coalesce(nullif(p->>'societe', ''), societe),
        couleur = coalesce(nullif(p->>'couleur', ''), couleur),
        au_demarrage = coalesce((p->>'au_demarrage')::boolean, au_demarrage),
        ordre = coalesce((p->>'ordre')::int, ordre)
      where id = v_id;
    end if;
  elsif v_type = 'regroupement' then
    if v_id is null then
      insert into planning.regroupement (nom, ordre) values (btrim(p->>'nom'), coalesce((p->>'ordre')::int, 0)) returning id into v_id;
    else
      select to_jsonb(x) into v_avant from planning.regroupement x where id = v_id;
      update planning.regroupement set nom = case when p ? 'nom' then btrim(p->>'nom') else nom end,
                                       ordre = coalesce((p->>'ordre')::int, ordre) where id = v_id;
    end if;
  elsif v_type = 'tache' then
    if v_id is null then
      insert into planning.tache (atelier_id, regroupement_id, nom, ordre)
      values ((p->>'atelier_id')::bigint, nullif(p->>'regroupement_id', '')::bigint, btrim(p->>'nom'), coalesce((p->>'ordre')::int, 0))
      returning id into v_id;
    else
      select to_jsonb(x) into v_avant from planning.tache x where id = v_id;
      update planning.tache set
        nom = case when p ? 'nom' then btrim(p->>'nom') else nom end,
        atelier_id = coalesce((p->>'atelier_id')::bigint, atelier_id),
        regroupement_id = case when p ? 'regroupement_id' then nullif(p->>'regroupement_id', '')::bigint else regroupement_id end,
        ordre = coalesce((p->>'ordre')::int, ordre)
      where id = v_id;
    end if;
  else
    raise exception 'Type inconnu : %', v_type;
  end if;
  if not found and v_avant is not null then raise exception 'Élément introuvable'; end if;
  perform planning.noter(p_identite, 'referentiel', v_id, case when v_avant is null then 'creer_' else 'modifier_' end || v_type, v_avant, p);
  return jsonb_build_object('id', v_id);
end $$;

-- Archiver (ou rétablir) : un élément qui a servi ne se supprime pas. On n'archive pas un parent
-- dont des enfants sont encore actifs, pour ne rien laisser d'orphelin dans le planning.
create function planning.ref_archiver(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_type text := p->>'type'; v_id bigint := (p->>'id')::bigint; v_arch boolean := coalesce((p->>'archiver')::boolean, true);
        v_quand timestamptz := case when coalesce((p->>'archiver')::boolean, true) then now() end;
begin
  perform planning.exiger_complet(p_droits);
  if v_type = 'activite' then
    if v_arch and exists (select 1 from planning.atelier where activite_id = v_id and archive_le is null) then
      raise exception 'Archive d''abord les ateliers de cette activité'; end if;
    update planning.activite set archive_le = v_quand where id = v_id;
  elsif v_type = 'atelier' then
    if v_arch and exists (select 1 from planning.tache where atelier_id = v_id and archive_le is null) then
      raise exception 'Archive d''abord les tâches de cet atelier'; end if;
    if not v_arch and exists (select 1 from planning.atelier a join planning.activite ac on ac.id = a.activite_id where a.id = v_id and ac.archive_le is not null) then
      raise exception 'Rétablis d''abord son activité'; end if;
    update planning.atelier set archive_le = v_quand where id = v_id;
  elsif v_type = 'tache' then
    if not v_arch and exists (select 1 from planning.tache t join planning.atelier a on a.id = t.atelier_id where t.id = v_id and a.archive_le is not null) then
      raise exception 'Rétablis d''abord son atelier'; end if;
    update planning.tache set archive_le = v_quand where id = v_id;
  elsif v_type = 'regroupement' then
    update planning.regroupement set archive_le = v_quand where id = v_id;
  else
    raise exception 'Type inconnu : %', v_type;
  end if;
  if not found then raise exception 'Élément introuvable'; end if;
  perform planning.noter(p_identite, 'referentiel', v_id, case when v_arch then 'archiver_' else 'retablir_' end || v_type, null, p);
  return jsonb_build_object('id', v_id);
end $$;

-- Responsables et ateliers habituels ----------------------------------------------------------
create function planning.changer_responsable(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_at bigint := (p->>'atelier_id')::bigint; v_pers bigint := (p->>'personne_id')::bigint;
begin
  perform planning.exiger_complet(p_droits);
  if coalesce((p->>'ajouter')::boolean, true) then
    if not exists (select 1 from public.collaborateurs c where c.personne_id = v_pers) then
      raise exception 'Un responsable doit avoir une fiche dans Suivi des temps (il se connecte avec son lien)'; end if;
    insert into planning.atelier_responsable values (v_at, v_pers) on conflict do nothing;
  else
    delete from planning.atelier_responsable where atelier_id = v_at and personne_id = v_pers;
  end if;
  perform planning.noter(p_identite, 'responsable', v_at, case when coalesce((p->>'ajouter')::boolean, true) then 'ajouter' else 'retirer' end, null, p);
  return jsonb_build_object('atelier_id', v_at);
end $$;

create function planning.changer_habituel(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_at bigint := (p->>'atelier_id')::bigint; v_pers bigint := (p->>'personne_id')::bigint;
begin
  perform planning.exiger_atelier(p_droits, v_at);
  if coalesce((p->>'ajouter')::boolean, true) then
    insert into planning.personne_atelier values (v_pers, v_at) on conflict do nothing;
  else
    delete from planning.personne_atelier where atelier_id = v_at and personne_id = v_pers;
  end if;
  return jsonb_build_object('atelier_id', v_at);
end $$;

-- Lecture de l'écran d'administration --------------------------------------------------------
create function planning.admin_lire() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'activites', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'ordre', ordre, 'archive', archive_le is not null) order by archive_le nulls first, ordre, nom), '[]') from planning.activite),
    'ateliers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'activite_id', activite_id, 'societe', societe, 'couleur', couleur,
                  'au_demarrage', au_demarrage, 'ordre', ordre, 'archive', archive_le is not null) order by archive_le nulls first, ordre, nom), '[]') from planning.atelier),
    'regroupements', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'ordre', ordre, 'archive', archive_le is not null) order by archive_le nulls first, ordre, nom), '[]') from planning.regroupement),
    'taches', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nom', t.nom, 'atelier_id', t.atelier_id, 'regroupement_id', t.regroupement_id,
                'ordre', t.ordre, 'archive', t.archive_le is not null,
                'seances', (select count(*) from planning.seance s where s.tache_id = t.id and s.supprimee_le is null)) order by t.archive_le nulls first, t.ordre, t.nom), '[]') from planning.tache t),
    'societes', (select coalesce(jsonb_agg(jsonb_build_object('code', code_structure, 'nom', nom_legal) order by code_structure), '[]') from public.structures),
    'responsables', (select coalesce(jsonb_agg(jsonb_build_array(atelier_id, personne_id)), '[]') from planning.atelier_responsable),
    'habituels', (select coalesce(jsonb_agg(jsonb_build_array(personne_id, atelier_id)), '[]') from planning.personne_atelier),
    -- Toutes les personnes : avec fiche (même inactive : un nouveau venu l'est jusqu'à son contrat) et sans fiche.
    'personnes', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', p.personne_id, 'prenom', p.prenom, 'nom', p.nom,
                    'sans_fiche', not exists (select 1 from public.collaborateurs c where c.personne_id = p.personne_id),
                    'active', exists (select 1 from public.collaborateurs c where c.personne_id = p.personne_id and c.actif),
                    'societes', (select coalesce(jsonb_agg(distinct c.structure), '[]') from public.collaborateurs c where c.personne_id = p.personne_id and c.actif),
                    'nature', pp.nature, 'archive', pp.archive_le is not null, 'cree_le', coalesce(pp.cree_le, p.created_at),
                    'seances', (select count(*) from planning.affectation a where a.personne_id = p.personne_id),
                    -- Pour une personne sans fiche : celles qui ont une fiche et le même nom (suggestion de rattachement).
                    'suggestions', case when p.externe then (select coalesce(jsonb_agg(q.personne_id), '[]') from public.personne q
                                    where q.personne_id <> p.personne_id
                                      and exists (select 1 from public.collaborateurs c where c.personne_id = q.personne_id)
                                      and ((planning.sans_accent(p.nom) <> '' and planning.sans_accent(q.nom) = planning.sans_accent(p.nom))
                                           or planning.sans_accent(q.prenom) = planning.sans_accent(p.prenom))) end)
                  order by p.prenom, p.nom), '[]')
                  from public.personne p left join planning.personne_planning pp on pp.personne_id = p.personne_id));
$$;

-- Les personnes du volet montrent la nature d'une personne sans fiche et masquent les archivées.
create or replace function planning.lire_personnes(p_lundi date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with fiches as (
    select c.personne_id, jsonb_agg(jsonb_build_object('collab_id', c.collab_id, 'societe', c.structure,
             'contrat', c.type_contrat, 'heures_hebdo', c.heures_hebdo) order by c.collab_id) as fiches
    from public.collaborateurs c where c.actif group by c.personne_id),
  prevu as (
    select personne_id, sum(heures) as heures from planning.v_prevu_jour
    where date_jour between p_lundi and p_lundi + 6 group by personne_id),
  habituels as (
    select personne_id, jsonb_agg(atelier_id) as ateliers from planning.personne_atelier group by personne_id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.personne_id, 'prenom', p.prenom, 'nom', p.nom, 'externe', p.externe,
           'fiches', coalesce(f.fiches, '[]'), 'prevu_h', coalesce(pr.heures, 0),
           'ateliers_habituels', coalesce(h.ateliers, '[]'),
           'nature', case when p.externe then coalesce(pp.nature, 'externe') end) order by p.prenom, p.nom), '[]')
  from public.personne p
  left join fiches f on f.personne_id = p.personne_id
  left join prevu pr on pr.personne_id = p.personne_id
  left join habituels h on h.personne_id = p.personne_id
  left join planning.personne_planning pp on pp.personne_id = p.personne_id
  where f.personne_id is not null or (p.externe and pp.archive_le is null);
$$;

-- Aiguillage : actions d'administration.
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

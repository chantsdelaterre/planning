-- portee: planning
-- Accès en lecture (décidé avec Coco le 30/10, option b) :
--  - accès complet et consultation : tout ;
--  - collaborateur et responsable : leurs propres séances, toujours ; les tâches des ateliers dont ils sont
--    responsables ou habituels ; plus ce que les administrateurs ouvrent à la personne (ou « tout »).
-- Le filtrage se fait ici, dans la base : une personne ne reçoit jamais ce qu'elle n'a pas le droit de voir.

create table planning.acces_personne (
  personne_id bigint primary key references public.personne (personne_id) on delete cascade,
  tout        boolean not null default false,
  modifie_le  timestamptz not null default now()
);
create table planning.acces_element (
  personne_id bigint not null references public.personne (personne_id) on delete cascade,
  type        text not null check (type in ('activite', 'atelier', 'regroupement', 'tache')),
  element_id  bigint not null,
  primary key (personne_id, type, element_id)
);
alter table planning.acces_personne enable row level security;
alter table planning.acces_element enable row level security;

-- Tâches visibles ; null = toutes.
create function planning.taches_visibles(p_droits jsonb) returns bigint[]
language plpgsql stable security definer set search_path = '' as $$
declare v_p bigint := (p_droits->>'personne_id')::bigint;
begin
  if p_droits->>'niveau' in ('complet', 'consultation') then return null; end if;
  if exists (select 1 from planning.acces_personne where personne_id = v_p and tout) then return null; end if;
  return array(
    select t.id from planning.tache t join planning.atelier a on a.id = t.atelier_id
     where t.atelier_id in (select atelier_id from planning.personne_atelier where personne_id = v_p
                            union select atelier_id from planning.atelier_responsable where personne_id = v_p)
        or exists (select 1 from planning.acces_element e where e.personne_id = v_p and (
                     (e.type = 'tache' and e.element_id = t.id) or (e.type = 'atelier' and e.element_id = t.atelier_id)
                  or (e.type = 'regroupement' and e.element_id = t.regroupement_id) or (e.type = 'activite' and e.element_id = a.activite_id))));
end $$;

-- Personnes dont on peut lire les heures (prévu, réalisé, contrat) sur une période ; null = toutes.
-- Collaborateur : lui seul. Responsable : lui, et les personnes affectées aux séances de ses ateliers
-- sur la période, ou habituelles de ses ateliers.
create function planning.personnes_visibles(p_droits jsonb, p_debut date, p_fin date) returns bigint[]
language plpgsql stable security definer set search_path = '' as $$
declare v_p bigint := (p_droits->>'personne_id')::bigint;
begin
  if p_droits->>'niveau' in ('complet', 'consultation') then return null; end if;
  if p_droits->>'niveau' = 'collaborateur' then return array[coalesce(v_p, -1)]; end if;
  return array(
    select v_p
    union select a.personne_id from planning.affectation a join planning.seance s on s.id = a.seance_id join planning.tache t on t.id = s.tache_id
           where t.atelier_id in (select atelier_id from planning.atelier_responsable where personne_id = v_p)
             and s.date_seance between p_debut and p_fin and s.supprimee_le is null
    union select pa.personne_id from planning.personne_atelier pa
           where pa.atelier_id in (select atelier_id from planning.atelier_responsable where personne_id = v_p));
end $$;

create function planning.personne_visible(p_droits jsonb, p_personne bigint, p_debut date, p_fin date) returns boolean
language sql stable security definer set search_path = '' as $$
  select v is null or p_personne = any (v) from (select planning.personnes_visibles(p_droits, p_debut, p_fin) as v) x;
$$;

-- Référentiel réduit à ce que la personne peut voir.
create function planning.lire_referentiel_vue(p_droits jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb := planning.lire_referentiel(); v bigint[] := planning.taches_visibles(p_droits); t jsonb;
begin
  if v is null then return r; end if;
  t := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(r->'taches') x where (x->>'id')::bigint = any (v));
  return jsonb_build_object(
    'taches', t,
    'ateliers', (select coalesce(jsonb_agg(a), '[]') from jsonb_array_elements(r->'ateliers') a
                  where exists (select 1 from jsonb_array_elements(t) x where x->'atelier_id' = a->'id')),
    'activites', (select coalesce(jsonb_agg(ac), '[]') from jsonb_array_elements(r->'activites') ac
                   where exists (select 1 from jsonb_array_elements(r->'ateliers') a, jsonb_array_elements(t) x
                                  where a->'activite_id' = ac->'id' and x->'atelier_id' = a->'id')),
    'regroupements', (select coalesce(jsonb_agg(g), '[]') from jsonb_array_elements(r->'regroupements') g
                       where exists (select 1 from jsonb_array_elements(t) x where x->'regroupement_id' = g->'id')));
end $$;

-- Semaine réduite : séances des tâches visibles + les siennes ; pour un collaborateur, les autres
-- personnes n'apparaissent que par leur nom (ni contrat, ni heures, ni indisponibilités).
create function planning.lire_semaine_vue(p_droits jsonb, p_lundi date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb := planning.lire_semaine(p_lundi); v bigint[] := planning.taches_visibles(p_droits);
        v_p bigint := (p_droits->>'personne_id')::bigint; s jsonb;
begin
  if p_droits->>'niveau' in ('complet', 'consultation') then return r; end if;
  s := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(r->'seances') x
         where (v is null or (x->>'tache_id')::bigint = any (v))
            or x->'personnes' @> jsonb_build_array(jsonb_build_object('personne_id', v_p)));
  r := r || jsonb_build_object('seances', s, 'chevauchements', '[]'::jsonb,
         'indisponibilites', (select coalesce(jsonb_agg(i), '[]') from jsonb_array_elements(r->'indisponibilites') i where (i->>'personne_id')::bigint = v_p));
  if p_droits->>'niveau' = 'collaborateur' then
    r := r || jsonb_build_object('personnes', (select coalesce(jsonb_agg(
           case when (p->>'id')::bigint = v_p then p
                else jsonb_build_object('id', p->'id', 'prenom', p->'prenom', 'nom', p->'nom', 'externe', p->'externe',
                                        'fiches', '[]'::jsonb, 'prevu_h', 0, 'ateliers_habituels', '[]'::jsonb, 'nature', p->'nature') end), '[]')
         from jsonb_array_elements(r->'personnes') p
        where (p->>'id')::bigint = v_p
           or exists (select 1 from jsonb_array_elements(s) x, jsonb_array_elements(x->'personnes') y where y->'personne_id' = p->'id')));
  end if;
  return r;
end $$;

-- Réglage des accès d'une personne (accès complet) : « tout », ou une liste d'éléments en plus.
create function planning.acces_regler(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint; e jsonb;
begin
  perform planning.exiger_complet(p_droits);
  if not exists (select 1 from public.personne where personne_id = v_p) then raise exception 'Personne introuvable'; end if;
  insert into planning.acces_personne (personne_id, tout) values (v_p, coalesce((p->>'tout')::boolean, false))
  on conflict (personne_id) do update set tout = excluded.tout, modifie_le = now();
  if p ? 'elements' then
    delete from planning.acces_element where personne_id = v_p;
    for e in select * from jsonb_array_elements(p->'elements') loop
      insert into planning.acces_element values (v_p, e->>0, (e->>1)::bigint) on conflict do nothing;
    end loop;
  end if;
  perform planning.noter(p_identite, 'acces', v_p, 'regler', null, p);
  return jsonb_build_object('personne_id', v_p);
end $$;

-- L'écran d'administration lit aussi les accès.
create function planning.admin_lire_acces() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'acces_tout', (select coalesce(jsonb_agg(personne_id), '[]') from planning.acces_personne where tout),
    'acces_elements', (select coalesce(jsonb_agg(jsonb_build_array(personne_id, type, element_id)), '[]') from planning.acces_element));
$$;

-- Récapitulatifs : même règle de visibilité (personnes et tâches).
create or replace function planning.lire_recap(p_droits jsonb, p_debut date, p_fin date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_moi bigint := null;
        v_pers bigint[] := planning.personnes_visibles(p_droits, p_debut, p_fin);
        v_taches bigint[] := planning.taches_visibles(p_droits);
begin
  if p_debut is null or p_fin is null then raise exception 'Période incomplète'; end if;
  if p_fin < p_debut then raise exception 'La fin de la période doit être après son début'; end if;
  if p_fin - p_debut > 400 then raise exception 'Période trop longue : 13 mois au plus'; end if;
  return jsonb_build_object(
    'debut', p_debut, 'fin', p_fin,
    -- [personne, date, atelier, heures, mise à disposition]
    'prevu', (select coalesce(jsonb_agg(jsonb_build_array(personne_id, date_jour, atelier_id, round(h::numeric, 2), mad) order by date_jour), '[]')
              from (select personne_id, date_jour, atelier_id, bool_or(mad) as mad, sum(heures) as h
                      from planning.v_prevu_jour
                     where date_jour between p_debut and p_fin and (v_pers is null or personne_id = any (v_pers))
                     group by 1, 2, 3) x),
    -- [personne, date, type (T, CP, AT), heures]
    'realise', (select coalesce(jsonb_agg(jsonb_build_array(personne_id, date_jour, t, round(h::numeric, 2)) order by date_jour), '[]')
                from (select personne_id, date_jour,
                             case when bool_or(type_jour = 'AT') then 'AT' when bool_or(type_jour = 'CP') then 'CP' else 'T' end as t,
                             sum(heures) as h
                        from planning.v_realise_jour
                       where date_jour between p_debut and p_fin and (v_pers is null or personne_id = any (v_pers))
                       group by 1, 2
                      having sum(heures) > 0 or bool_or(type_jour in ('CP', 'AT'))) x),
    -- [personne, fiche, société, contrat, heures hebdo, début, fin]
    'contrats', (select coalesce(jsonb_agg(jsonb_build_array(c.personne_id, h.collab_id, h.structure, h.type_contrat, h.heures_hebdo, h.date_debut, h.date_fin)
                                           order by c.personne_id, h.date_debut), '[]')
                 from public.historique_contrats h join public.collaborateurs c on c.collab_id = h.collab_id
                 where h.date_debut <= p_fin and (h.date_fin is null or h.date_fin >= p_debut)
                   and (v_pers is null or c.personne_id = any (v_pers))),
    -- [date, tâche, main-d'œuvre, séances] (pas pour un collaborateur)
    'mo', (select coalesce(jsonb_agg(jsonb_build_array(date_seance, tache_id, round(mo::numeric, 2), n) order by date_seance), '[]')
           from (select date_seance, tache_id, sum(main_oeuvre_h) as mo, count(*) as n
                   from planning.v_seance
                  where p_droits->>'niveau' <> 'collaborateur' and (v_taches is null or tache_id = any (v_taches))
                    and statut = 'prevue' and date_seance between p_debut and p_fin
                  group by 1, 2) x),
    -- [personne, prénom, nom, externe] : celles qui apparaissent ci-dessus
    'personnes', (select coalesce(jsonb_agg(jsonb_build_array(p.personne_id, p.prenom, p.nom, p.externe) order by p.prenom, p.nom), '[]')
                  from public.personne p
                  where (v_pers is null or p.personne_id = any (v_pers))
                    and (exists (select 1 from planning.affectation a join planning.seance s on s.id = a.seance_id
                                  where a.personne_id = p.personne_id and s.date_seance between p_debut and p_fin and s.supprimee_le is null)
                         or exists (select 1 from public.collaborateurs c join public.historique_contrats h on h.collab_id = c.collab_id
                                     where c.personne_id = p.personne_id and h.date_debut <= p_fin and (h.date_fin is null or h.date_fin >= p_debut))))
  );
end $$;


-- Aiguillage : lectures filtrées selon les droits ; réglage des accès.
create or replace function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_droits jsonb := planning.droits(p_identite);
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
    return planning.admin_lire() || planning.admin_lire_acces();
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
    when 'acces_regler'      then return planning.acces_regler(p_identite, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

-- portee: planning
-- API du planning, appelée par public.planning_appel (Edge Function planning-api).
-- Identité (établie par l'Edge Function à partir du jeton) :
--   {"type":"admin","admin_id":"…"} | {"type":"collab","collab_id":"…","personne_id":n}
-- Erreurs : exception avec un message en français, transmis tel quel à la page.

-- Droits ---------------------------------------------------------------------------------
-- niveau : complet | consultation | responsable | collaborateur ; ateliers : ceux qu'on peut modifier.
create function planning.droits(p_identite jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_niveau text; v_ateliers bigint[]; v_personne bigint;
begin
  if p_identite->>'type' = 'admin' then
    select niveau into v_niveau from planning.acces_admin where admin_id = p_identite->>'admin_id';
    v_niveau := coalesce(v_niveau, 'consultation');
  elsif p_identite->>'type' = 'collab' then
    v_personne := (p_identite->>'personne_id')::bigint;
    select array_agg(atelier_id order by atelier_id) into v_ateliers
      from planning.atelier_responsable where personne_id = v_personne;
    v_niveau := case when v_ateliers is null then 'collaborateur' else 'responsable' end;
  else
    raise exception 'Identité inconnue';
  end if;
  if v_niveau = 'complet' then
    select array_agg(id order by id) into v_ateliers from planning.atelier where archive_le is null;
  end if;
  return jsonb_build_object('niveau', v_niveau, 'personne_id', v_personne,
                            'ateliers', coalesce(to_jsonb(v_ateliers), '[]'::jsonb),
                            'referentiel', v_niveau = 'complet');
end $$;

create function planning.exiger_atelier(p_droits jsonb, p_atelier bigint) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if not (p_droits->'ateliers') @> to_jsonb(p_atelier) then
    raise exception 'Vous ne pouvez pas modifier cet atelier';
  end if;
end $$;

create function planning.atelier_de_seance(p_seance bigint) returns bigint
language sql stable set search_path = '' as $$
  select t.atelier_id from planning.seance s join planning.tache t on t.id = s.tache_id where s.id = p_seance;
$$;

create function planning.qui(p_identite jsonb) returns text
language sql immutable set search_path = '' as $$
  select case p_identite->>'type' when 'admin' then 'admin:' || (p_identite->>'admin_id')
                                  else 'personne:' || (p_identite->>'personne_id') end;
$$;

create function planning.noter(p_identite jsonb, p_objet text, p_id bigint, p_action text, p_avant jsonb, p_apres jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into planning.journal (qui, objet, objet_id, action, avant, apres)
  values (planning.qui(p_identite), p_objet, p_id, p_action, p_avant, p_apres);
$$;

-- Lecture --------------------------------------------------------------------------------

create function planning.lire_referentiel() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'activites', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom) order by ordre, nom), '[]')
                  from planning.activite where archive_le is null),
    'ateliers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'activite_id', activite_id,
                  'societe', societe, 'couleur', couleur, 'au_demarrage', au_demarrage) order by ordre, nom), '[]')
                 from planning.atelier where archive_le is null),
    'regroupements', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom) order by ordre, nom), '[]')
                      from planning.regroupement where archive_le is null),
    'taches', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'atelier_id', atelier_id,
                'regroupement_id', regroupement_id) order by ordre, nom), '[]')
               from planning.tache where archive_le is null));
$$;

-- Personnes planifiables : fiches actives + externes, avec contrats et heures prévues de la semaine.
create function planning.lire_personnes(p_lundi date) returns jsonb
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
           'ateliers_habituels', coalesce(h.ateliers, '[]')) order by p.prenom, p.nom), '[]')
  from public.personne p
  left join fiches f on f.personne_id = p.personne_id
  left join prevu pr on pr.personne_id = p.personne_id
  left join habituels h on h.personne_id = p.personne_id
  where f.personne_id is not null or p.externe;
$$;

-- La semaine : séances (et traces de séances déplacées hors de la semaine), jours fermés,
-- indisponibilités, chevauchements, personnes.
create function planning.lire_semaine(p_lundi date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with sem as (select p_lundi as d0, p_lundi + 6 as d6),
  aff as (
    select a.seance_id, jsonb_agg(jsonb_build_object('personne_id', a.personne_id,
             'prenom', p.prenom, 'nom', p.nom, 'collab_id', a.collab_id, 'mad', a.mad)
             order by p.prenom, p.nom) as personnes
    from planning.affectation a join public.personne p on p.personne_id = a.personne_id
    group by a.seance_id),
  chev as (select distinct seance_id, personne_id from planning.v_chevauchement, sem
           where date_jour between sem.d0 and sem.d6)
  select jsonb_build_object(
    'lundi', p_lundi,
    'seances', (select coalesce(jsonb_agg(to_jsonb(v) || jsonb_build_object(
                  'trace', not (v.date_seance between sem.d0 and sem.d6),
                  'personnes', coalesce(aff.personnes, '[]'),
                  'chevauchements', coalesce((select jsonb_agg(c.personne_id) from chev c where c.seance_id = v.id), '[]'))
                  order by v.date_seance, v.heure_debut), '[]')
                from planning.v_seance v cross join sem
                left join aff on aff.seance_id = v.id
                where v.date_seance between sem.d0 and sem.d6
                   or (v.deplacee and v.date_serie between sem.d0 and sem.d6)),
    'jours_fermes', (select coalesce(jsonb_agg(jsonb_build_object('date', j.date, 'societe', j.societe, 'motif', j.motif)), '[]')
                     from planning.jour_ferme j, sem where j.date between sem.d0 and sem.d6),
    'indisponibilites', (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from planning.indisponibilite i, sem
                         where i.date_debut <= sem.d6 and i.date_fin >= sem.d0),
    'chevauchements', (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from planning.v_chevauchement c, sem
                       where c.date_jour between sem.d0 and sem.d6),
    'personnes', planning.lire_personnes(p_lundi))
  from sem;
$$;

-- Écriture -------------------------------------------------------------------------------

create function planning.creer_seance(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_tache record; v_id bigint; v_pers bigint;
begin
  select t.id, t.atelier_id, a.societe into v_tache
    from planning.tache t join planning.atelier a on a.id = t.atelier_id
    where t.id = (p->>'tache_id')::bigint and t.archive_le is null;
  if v_tache.id is null then raise exception 'Tâche introuvable'; end if;
  perform planning.exiger_atelier(p_droits, v_tache.atelier_id);
  insert into planning.seance (tache_id, societe, date_seance, heure_debut, heure_fin, titre, lieu, statut, motif)
  values (v_tache.id, v_tache.societe, (p->>'date')::date, (p->>'debut')::time, (p->>'fin')::time,
          nullif(p->>'titre', ''), nullif(p->>'lieu', ''),
          case when planning.est_ferme((p->>'date')::date, v_tache.societe) then 'suspendue' else 'prevue' end,
          case when planning.est_ferme((p->>'date')::date, v_tache.societe) then 'Jour fermé' end)
  returning id into v_id;
  for v_pers in select (jsonb_array_elements_text(coalesce(p->'personnes', '[]')))::bigint loop
    perform planning.affecter(v_id, v_pers);
  end loop;
  perform planning.noter(p_identite, 'seance', v_id, 'creer', null, p);
  return jsonb_build_object('seance_id', v_id);
end $$;

-- Création d'une série + génération immédiate de ses séances.
create function planning.creer_serie(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_tache record; v_id bigint; v_pers bigint; v_n integer; v_debut date;
begin
  select t.id, t.atelier_id into v_tache from planning.tache t
    where t.id = (p->>'tache_id')::bigint and t.archive_le is null;
  if v_tache.id is null then raise exception 'Tâche introuvable'; end if;
  perform planning.exiger_atelier(p_droits, v_tache.atelier_id);
  v_debut := (p->>'date_debut')::date;
  insert into planning.serie (tache_id, titre, lieu, jours, heure_debut, heure_fin, date_debut, date_fin, cree_par)
  values (v_tache.id, nullif(p->>'titre', ''), nullif(p->>'lieu', ''),
          (select array_agg(x::smallint order by x::smallint) from jsonb_array_elements_text(p->'jours') x),
          (p->>'debut')::time, (p->>'fin')::time, v_debut, nullif(p->>'date_fin', '')::date,
          planning.qui(p_identite))
  returning id into v_id;
  for v_pers in select (jsonb_array_elements_text(coalesce(p->'personnes', '[]')))::bigint loop
    insert into planning.serie_personne values (v_id, v_pers) on conflict do nothing;
  end loop;
  v_n := planning.generer_seances(greatest(current_date, v_debut) + 56, v_debut);
  perform planning.noter(p_identite, 'serie', v_id, 'creer', null, p);
  return jsonb_build_object('serie_id', v_id, 'seances_creees', v_n);
end $$;

-- Modifier une séance. portee = 'seance' (elle seule) ou 'suivantes' (elle et la suite de la série :
-- la série est coupée la veille et une nouvelle série reprend avec les nouveaux réglages).
create function planning.modifier_seance(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s record; v_avant jsonb; v_date date; v_debut time; v_fin time; v_portee text;
        se record; v_nouv bigint; v_decalage integer; v_n integer := 0;
begin
  select * into s from planning.seance where id = (p->>'seance_id')::bigint for update;
  if s.id is null then raise exception 'Séance introuvable'; end if;
  perform planning.exiger_atelier(p_droits, planning.atelier_de_seance(s.id));
  v_avant := to_jsonb(s);
  v_date  := coalesce((p->>'date')::date, s.date_seance);
  v_debut := coalesce((p->>'debut')::time, s.heure_debut);
  v_fin   := coalesce((p->>'fin')::time, s.heure_fin);
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

  -- Cette séance et les suivantes : on coupe la série la veille de la date de série de cette séance.
  select * into se from planning.serie where id = s.serie_id for update;
  v_decalage := v_date - s.date_serie;  -- déplacement en jours (ex. mardi -> mercredi = 1)
  update planning.serie set date_fin = s.date_serie - 1 where id = se.id;
  insert into planning.serie (tache_id, titre, lieu, jours, heure_debut, heure_fin, date_debut, date_fin, cree_par)
  values (se.tache_id,
          case when p ? 'titre' then nullif(p->>'titre', '') else se.titre end,
          case when p ? 'lieu' then nullif(p->>'lieu', '') else se.lieu end,
          (select array_agg(distinct (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint order by (((j - 1 + v_decalage) % 7 + 7) % 7 + 1)::smallint)
             from unnest(se.jours) j),
          v_debut, v_fin, s.date_serie + v_decalage, se.date_fin, planning.qui(p_identite))
  returning id into v_nouv;
  insert into planning.serie_personne select v_nouv, personne_id from planning.serie_personne where serie_id = se.id;
  -- Les séances à venir non retouchées de l'ancienne série sont retirées puis régénérées par la nouvelle.
  delete from planning.seance
   where serie_id = se.id and date_serie >= s.date_serie and not modifiee and id <> s.id;
  delete from planning.seance where id = s.id;
  v_n := planning.generer_seances(greatest(current_date, s.date_serie) + 56, s.date_serie + v_decalage);
  perform planning.noter(p_identite, 'serie', se.id, 'couper', v_avant, p || jsonb_build_object('nouvelle_serie', v_nouv));
  return jsonb_build_object('serie_id', v_nouv, 'seances_creees', v_n);
end $$;

create function planning.arreter_serie(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare se record; v_fin date; v_n integer;
begin
  select s.*, t.atelier_id into se from planning.serie s join planning.tache t on t.id = s.tache_id
   where s.id = (p->>'serie_id')::bigint for update;
  if se.id is null then raise exception 'Série introuvable'; end if;
  perform planning.exiger_atelier(p_droits, se.atelier_id);
  v_fin := (p->>'date_fin')::date;
  update planning.serie set date_fin = v_fin where id = se.id;
  -- Les séances à venir au-delà de la fin disparaissent ; le passé reste.
  delete from planning.seance where serie_id = se.id and date_seance > v_fin and date_seance >= current_date;
  get diagnostics v_n = row_count;
  perform planning.noter(p_identite, 'serie', se.id, 'arreter', to_jsonb(se), p);
  return jsonb_build_object('seances_retirees', v_n);
end $$;

create function planning.changer_affectation(p_identite jsonb, p_droits jsonb, p jsonb, p_ajouter boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_seance bigint := (p->>'seance_id')::bigint; v_pers bigint := (p->>'personne_id')::bigint; v_date date;
begin
  perform planning.exiger_atelier(p_droits, planning.atelier_de_seance(v_seance));
  if p_ajouter then
    perform planning.affecter(v_seance, v_pers);
  else
    delete from planning.affectation where seance_id = v_seance and personne_id = v_pers;
  end if;
  update planning.seance set modifiee = true, modifie_le = now() where id = v_seance and serie_id is not null;
  perform planning.noter(p_identite, 'affectation', v_seance, case when p_ajouter then 'ajouter' else 'retirer' end, null, p);
  select date_seance into v_date from planning.seance where id = v_seance;
  return jsonb_build_object('chevauchements',
    (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from planning.v_chevauchement c
      where c.personne_id = v_pers and c.date_jour = v_date));
end $$;

create function planning.changer_statut(p_identite jsonb, p_droits jsonb, p jsonb, p_suspendre boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_seance bigint := (p->>'seance_id')::bigint;
begin
  perform planning.exiger_atelier(p_droits, planning.atelier_de_seance(v_seance));
  update planning.seance
     set statut = case when p_suspendre then 'suspendue' else 'prevue' end,
         motif = case when p_suspendre then nullif(p->>'motif', '') end,
         modifiee = true, modifie_le = now()
   where id = v_seance;
  perform planning.noter(p_identite, 'seance', v_seance, case when p_suspendre then 'suspendre' else 'reprendre' end, null, p);
  return jsonb_build_object('seance_id', v_seance);
end $$;

-- Fermer une journée : réservé aux accès complets.
create function planning.fermer_jour(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_date date := (p->>'date')::date; v_societe text := nullif(p->>'societe', ''); v_n integer;
begin
  if p_droits->>'niveau' <> 'complet' then raise exception 'Seuls les accès complets peuvent fermer une journée'; end if;
  insert into planning.jour_ferme (date, societe, motif) values (v_date, v_societe, nullif(p->>'motif', ''))
  on conflict do nothing;
  update planning.seance set statut = 'suspendue', motif = coalesce(nullif(p->>'motif', ''), 'Jour fermé')
   where date_seance = v_date and statut = 'prevue' and (v_societe is null or societe = v_societe);
  get diagnostics v_n = row_count;
  perform planning.noter(p_identite, 'jour_ferme', null, 'fermer', null, p);
  return jsonb_build_object('seances_suspendues', v_n);
end $$;

-- Aiguillage -----------------------------------------------------------------------------

create function planning.api(p_identite jsonb, p_action text, p_params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_droits jsonb := planning.droits(p_identite);
begin
  -- Lecture : tout le monde.
  if p_action = 'session' then
    return jsonb_build_object('droits', v_droits, 'referentiel', planning.lire_referentiel());
  elsif p_action = 'semaine' then
    return planning.lire_semaine(coalesce((p_params->>'lundi')::date, date_trunc('week', current_date)::date));
  end if;
  -- Écriture : jamais en consultation ni pour un simple collaborateur.
  if v_droits->>'niveau' in ('consultation', 'collaborateur') then
    raise exception 'Accès en consultation : modification impossible';
  end if;
  case p_action
    when 'seance_creer'    then return planning.creer_seance(p_identite, v_droits, p_params);
    when 'seance_modifier' then return planning.modifier_seance(p_identite, v_droits, p_params);
    when 'serie_creer'     then return planning.creer_serie(p_identite, v_droits, p_params);
    when 'serie_arreter'   then return planning.arreter_serie(p_identite, v_droits, p_params);
    when 'affecter'        then return planning.changer_affectation(p_identite, v_droits, p_params, true);
    when 'retirer'         then return planning.changer_affectation(p_identite, v_droits, p_params, false);
    when 'suspendre'       then return planning.changer_statut(p_identite, v_droits, p_params, true);
    when 'reprendre'       then return planning.changer_statut(p_identite, v_droits, p_params, false);
    when 'jour_fermer'     then return planning.fermer_jour(p_identite, v_droits, p_params);
    else raise exception 'Action inconnue : %', p_action;
  end case;
end $$;

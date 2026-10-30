-- portee: planning
-- Liens personnels du planning (pour les responsables sur ordinateur, les externes…).
-- Un jeton long et aléatoire, propre au planning : il n'ouvre ni la saisie des heures ni la paie.
-- Seule son empreinte (SHA-256) est gardée ; il ne s'affiche qu'à sa création. Révocable.
-- Il ne fonctionne que si la personne a une fiche ACTIVE dans Suivi des temps (désactivée = lien mort),
-- ou, pour une personne sans fiche, tant qu'elle n'est pas archivée.

create table planning.lien (
  id            bigint generated always as identity primary key,
  personne_id   bigint not null references public.personne (personne_id) on delete cascade,
  empreinte     text not null unique,
  cree_par      text,
  cree_le       timestamptz not null default now(),
  revoque_le    timestamptz,
  dernier_usage timestamptz
);
create unique index lien_un_actif on planning.lien (personne_id) where revoque_le is null;
alter table planning.lien enable row level security;

create function planning.empreinte(p_jeton text) returns text
language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(p_jeton, 'UTF8')), 'hex');
$$;

-- Le lien est-il utilisable aujourd'hui ?
create function planning.lien_valide(p_personne bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.collaborateurs c where c.personne_id = p_personne and c.actif)
      or exists (select 1 from public.personne p left join planning.personne_planning pp on pp.personne_id = p.personne_id
                  where p.personne_id = p_personne and p.externe and pp.archive_le is null
                    and not exists (select 1 from public.collaborateurs c where c.personne_id = p.personne_id));
$$;

-- Identité : un lien planning devient l'identité « collab » de sa personne ; le reste passe tel quel.
create function planning.resoudre_identite(p_identite jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_lien record;
begin
  if p_identite->>'type' <> 'lien' then return p_identite; end if;
  select * into v_lien from planning.lien
   where empreinte = planning.empreinte(coalesce(p_identite->>'jeton', '')) and revoque_le is null;
  if v_lien.id is null or not planning.lien_valide(v_lien.personne_id) then raise exception 'lien_invalide'; end if;
  update planning.lien set dernier_usage = now() where id = v_lien.id and (dernier_usage is null or dernier_usage < now() - interval '10 minutes');
  return jsonb_build_object('type', 'collab', 'personne_id', v_lien.personne_id, 'par_lien', true);
end $$;

-- Créer (ou recréer) le lien d'une personne : l'ancien est révoqué. Le jeton n'est rendu qu'ici.
create function planning.lien_generer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint; v_jeton text;
begin
  perform planning.exiger_complet(p_droits);
  if not planning.lien_valide(v_p) then raise exception 'Cette personne n''a pas de fiche active : son lien ne fonctionnerait pas'; end if;
  update planning.lien set revoque_le = now() where personne_id = v_p and revoque_le is null;
  v_jeton := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into planning.lien (personne_id, empreinte, cree_par) values (v_p, planning.empreinte(v_jeton), planning.qui(p_identite));
  perform planning.noter(p_identite, 'lien', v_p, 'generer', null, null);
  return jsonb_build_object('personne_id', v_p, 'jeton', v_jeton);
end $$;

create function planning.lien_revoquer(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint;
begin
  perform planning.exiger_complet(p_droits);
  update planning.lien set revoque_le = now() where personne_id = v_p and revoque_le is null;
  perform planning.noter(p_identite, 'lien', v_p, 'revoquer', null, null);
  return jsonb_build_object('personne_id', v_p);
end $$;

create function planning.admin_lire_liens() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('liens', (select coalesce(jsonb_agg(jsonb_build_object('personne_id', personne_id, 'cree_le', cree_le,
           'dernier_usage', dernier_usage, 'valide', planning.lien_valide(personne_id))), '[]')
         from planning.lien where revoque_le is null));
$$;

-- Aiguillage : identité résolue (liens) avant les droits ; actions des liens.
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
    else raise exception 'Action inconnue : %', p_action;
  end case;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

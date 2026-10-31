-- portee: planning
-- Couleur de chaque personne (mode « couleurs par personne ») : une palette de 20 couleurs distinctes,
-- foncées pour du texte blanc. Attribuée d'office dans l'ordre des personnes (stable : une nouvelle
-- personne prend la suivante), modifiable par un accès complet.

create table planning.couleur_personne (
  personne_id bigint primary key references public.personne (personne_id) on delete cascade,
  couleur     text not null check (couleur ~ '^#[0-9A-Fa-f]{6}$')
);
alter table planning.couleur_personne enable row level security;

create function planning.palette() returns text[]
language sql immutable set search_path = '' as $$
  select array['#C62828','#1565C0','#2E7D32','#EF6C00','#6A1B9A','#00838F','#AD1457','#827717','#4527A0','#8D6E63',
               '#0277BD','#558B2F','#D84315','#00695C','#880E4F','#37474F','#B8860B','#5D4037','#7B1FA2','#1B5E20'];
$$;

create function planning.couleur_de(p_personne bigint) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select couleur from planning.couleur_personne where personne_id = p_personne),
    (planning.palette())[1 + ((select count(*) from public.personne q where q.personne_id < p_personne) % 20)::int]);
$$;

create function planning.personne_couleur(p_identite jsonb, p_droits jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p bigint := (p->>'personne_id')::bigint; v_c text := upper(nullif(p->>'couleur', ''));
begin
  perform planning.exiger_complet(p_droits);
  if v_c is null then delete from planning.couleur_personne where personne_id = v_p;
  else
    if v_c !~ '^#[0-9A-F]{6}$' then raise exception 'Couleur invalide'; end if;
    insert into planning.couleur_personne values (v_p, v_c) on conflict (personne_id) do update set couleur = excluded.couleur;
  end if;
  return jsonb_build_object('personne_id', v_p, 'couleur', planning.couleur_de(v_p));
end $$;

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
           'nature', case when p.externe then coalesce(pp.nature, 'externe') end,
           'couleur', planning.couleur_de(p.personne_id)) order by p.prenom, p.nom), '[]')
  from public.personne p
  left join fiches f on f.personne_id = p.personne_id
  left join prevu pr on pr.personne_id = p.personne_id
  left join habituels h on h.personne_id = p.personne_id
  left join planning.personne_planning pp on pp.personne_id = p.personne_id
  where f.personne_id is not null or (p.externe and pp.archive_le is null);
$$;

create or replace function planning.admin_lire() returns jsonb
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
                    'nature', pp.nature, 'archive', pp.archive_le is not null, 'couleur', planning.couleur_de(p.personne_id), 'cree_le', coalesce(pp.cree_le, p.created_at),
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

-- Aiguillage : couleur d'une personne.
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
    when 'personne_couleur'  then v_res := planning.personne_couleur(v_ident, v_droits, p_params);
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

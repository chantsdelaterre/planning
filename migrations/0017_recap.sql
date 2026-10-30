-- portee: planning
-- Récapitulatifs (lot 5) : sur une période, heures prévues (planning), réalisées (Suivi des temps)
-- et contrats en vigueur, plus la main-d'œuvre par tâche. Un collaborateur ne lit que ses chiffres.
-- Données compactes (tableaux) : le calcul par semaine, mois, atelier… se fait dans la page.

create function planning.lire_recap(p_droits jsonb, p_debut date, p_fin date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_moi bigint := case when p_droits->>'niveau' = 'collaborateur' then coalesce((p_droits->>'personne_id')::bigint, -1) end;
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
                     where date_jour between p_debut and p_fin and (v_moi is null or personne_id = v_moi)
                     group by 1, 2, 3) x),
    -- [personne, date, type (T, CP, AT), heures]
    'realise', (select coalesce(jsonb_agg(jsonb_build_array(personne_id, date_jour, t, round(h::numeric, 2)) order by date_jour), '[]')
                from (select personne_id, date_jour,
                             case when bool_or(type_jour = 'AT') then 'AT' when bool_or(type_jour = 'CP') then 'CP' else 'T' end as t,
                             sum(heures) as h
                        from planning.v_realise_jour
                       where date_jour between p_debut and p_fin and (v_moi is null or personne_id = v_moi)
                       group by 1, 2
                      having sum(heures) > 0 or bool_or(type_jour in ('CP', 'AT'))) x),
    -- [personne, fiche, société, contrat, heures hebdo, début, fin]
    'contrats', (select coalesce(jsonb_agg(jsonb_build_array(c.personne_id, h.collab_id, h.structure, h.type_contrat, h.heures_hebdo, h.date_debut, h.date_fin)
                                           order by c.personne_id, h.date_debut), '[]')
                 from public.historique_contrats h join public.collaborateurs c on c.collab_id = h.collab_id
                 where h.date_debut <= p_fin and (h.date_fin is null or h.date_fin >= p_debut)
                   and (v_moi is null or c.personne_id = v_moi)),
    -- [date, tâche, main-d'œuvre, séances] (pas pour un collaborateur)
    'mo', (select coalesce(jsonb_agg(jsonb_build_array(date_seance, tache_id, round(mo::numeric, 2), n) order by date_seance), '[]')
           from (select date_seance, tache_id, sum(main_oeuvre_h) as mo, count(*) as n
                   from planning.v_seance
                  where v_moi is null and statut = 'prevue' and date_seance between p_debut and p_fin
                  group by 1, 2) x),
    -- [personne, prénom, nom, externe] : celles qui apparaissent ci-dessus
    'personnes', (select coalesce(jsonb_agg(jsonb_build_array(p.personne_id, p.prenom, p.nom, p.externe) order by p.prenom, p.nom), '[]')
                  from public.personne p
                  where (v_moi is null or p.personne_id = v_moi)
                    and (exists (select 1 from planning.affectation a join planning.seance s on s.id = a.seance_id
                                  where a.personne_id = p.personne_id and s.date_seance between p_debut and p_fin and s.supprimee_le is null)
                         or exists (select 1 from public.collaborateurs c join public.historique_contrats h on h.collab_id = c.collab_id
                                     where c.personne_id = p.personne_id and h.date_debut <= p_fin and (h.date_fin is null or h.date_fin >= p_debut))))
  );
end $$;

-- Aiguillage : nouvelle lecture « recap », ouverte à tous les niveaux (filtrée pour un collaborateur).
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
    else raise exception 'Action inconnue : %', p_action;
  end case;
exception
  when raise_exception then raise;           -- messages métier : tels quels
  when check_violation then raise exception 'Valeurs incohérentes, rien n''a été enregistré (code %)', sqlstate;
  when unique_violation then raise exception 'Doublon, rien n''a été enregistré (code %)', sqlstate;
  when others then raise exception 'Erreur inattendue, rien n''a été enregistré (code %)', sqlstate;
end $$;

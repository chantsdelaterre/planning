-- portee: planning
-- Règles de calcul du planning : fiche imputée, génération des séances depuis les séries,
-- vues de détail, chevauchements, heures prévues et réalisées.

-- Fiche imputée -------------------------------------------------------------------------
-- La fiche de la personne chez la société de l'atelier ; à défaut sa fiche principale
-- (mise à disposition) ; rien pour un externe.
create function planning.fiche_imputee(p_personne bigint, p_societe text, p_date date default current_date)
returns table (collab_id text, mad boolean)
language sql stable security definer set search_path = '' as $$
  with p as (select personne_id, externe, fiche_principale from public.personne where personne_id = p_personne)
  select coalesce(
           (select c.collab_id from public.collaborateurs c
             where c.personne_id = p_personne and c.structure = p_societe
             order by c.actif desc, c.collab_id limit 1),
           (select p.fiche_principale from p where not p.externe)) as collab_id,
         not exists (select 1 from public.collaborateurs c
                      where c.personne_id = p_personne and c.structure = p_societe)
         and not (select externe from p) as mad
  from p;
$$;

-- Ajoute une personne à une séance avec la bonne fiche (ne fait rien si déjà affectée).
create function planning.affecter(p_seance bigint, p_personne bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_societe text; v_date date; f record;
begin
  select societe, date_seance into v_societe, v_date from planning.seance where id = p_seance;
  select * into f from planning.fiche_imputee(p_personne, v_societe, v_date);
  insert into planning.affectation (seance_id, personne_id, collab_id, mad)
  values (p_seance, p_personne, f.collab_id, coalesce(f.mad, false))
  on conflict (seance_id, personne_id) do nothing;
end $$;

-- Jour fermé pour une société donnée (ou pour toute l'entreprise) ?
create function planning.est_ferme(p_date date, p_societe text)
returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from planning.jour_ferme j
                  where j.date = p_date and (j.societe is null or j.societe = p_societe));
$$;

-- Génération --------------------------------------------------------------------------
-- Crée les séances manquantes des séries jusqu'à l'horizon, à partir d'aujourd'hui.
-- N'écrase jamais une séance existante (déplacée, retouchée, suspendue) : clé (série, date de série).
-- Retourne le nombre de séances créées.
create function planning.generer_seances(p_jusqu_au date default current_date + 56, p_depuis date default current_date)
returns integer language plpgsql security definer set search_path = '' as $$
declare s record; d date; v_id bigint; v_societe text; n integer := 0; sp record;
begin
  for s in
    select se.*, at.societe as societe_atelier
    from planning.serie se
    join planning.tache t on t.id = se.tache_id
    join planning.atelier at on at.id = t.atelier_id
    where t.archive_le is null and at.archive_le is null
      and (se.date_fin is null or se.date_fin >= p_depuis)
  loop
    for d in select g::date from generate_series(greatest(s.date_debut, p_depuis),
                                                 least(coalesce(s.date_fin, p_jusqu_au), p_jusqu_au),
                                                 interval '1 day') g
    loop
      continue when not (extract(isodow from d)::smallint = any (s.jours));
      insert into planning.seance (tache_id, serie_id, date_serie, societe, date_seance,
                                   heure_debut, heure_fin, titre, lieu, statut, motif)
      values (s.tache_id, s.id, d, s.societe_atelier, d, s.heure_debut, s.heure_fin, s.titre, s.lieu,
              case when planning.est_ferme(d, s.societe_atelier) then 'suspendue' else 'prevue' end,
              case when planning.est_ferme(d, s.societe_atelier) then 'Jour fermé' end)
      on conflict (serie_id, date_serie) where serie_id is not null do nothing
      returning id into v_id;
      if v_id is not null then
        n := n + 1;
        for sp in select personne_id from planning.serie_personne where serie_id = s.id loop
          perform planning.affecter(v_id, sp.personne_id);
        end loop;
        v_id := null;
      end if;
    end loop;
  end loop;
  return n;
end $$;

-- Vues -----------------------------------------------------------------------------------

-- Une ligne par séance, avec tout le contexte et les heures.
create view planning.v_seance as
select s.id, s.date_seance, s.heure_debut, s.heure_fin,
       extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0 as duree_h,
       s.statut, s.motif, s.modifiee, s.serie_id, s.date_serie,
       (s.serie_id is not null and s.date_serie <> s.date_seance) as deplacee,
       coalesce(s.titre, t.nom) as titre, s.lieu, s.societe,
       t.id as tache_id, t.nom as tache, r.id as regroupement_id, r.nom as regroupement,
       at.id as atelier_id, at.nom as atelier, at.couleur, ac.id as activite_id, ac.nom as activite,
       (select count(*) from planning.affectation a where a.seance_id = s.id) as nb_personnes,
       case when s.statut = 'prevue'
            then extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0
                 * (select count(*) from planning.affectation a where a.seance_id = s.id)
            else 0 end as main_oeuvre_h
from planning.seance s
join planning.tache t on t.id = s.tache_id
left join planning.regroupement r on r.id = t.regroupement_id
join planning.atelier at on at.id = t.atelier_id
join planning.activite ac on ac.id = at.activite_id;

-- Heures prévues par personne, fiche et jour (séances prévues seulement).
create view planning.v_prevu_jour as
select a.personne_id, a.collab_id, a.mad, s.date_seance as date_jour, s.societe,
       t.atelier_id, sum(extract(epoch from (s.heure_fin - s.heure_debut)) / 3600.0) as heures
from planning.affectation a
join planning.seance s on s.id = a.seance_id and s.statut = 'prevue'
join planning.tache t on t.id = s.tache_id
group by a.personne_id, a.collab_id, a.mad, s.date_seance, s.societe, t.atelier_id;

-- Heures réalisées par fiche et jour (Suivi des temps, jours « travaillée »).
create view planning.v_realise_jour as
select j.collab_id, c.personne_id, j.date_jour, j.type_jour, coalesce(j.total_heures, 0) as heures,
       nullif(j.c1_debut, '') as c1_debut, nullif(j.c1_fin, '') as c1_fin,
       nullif(j.c2_debut, '') as c2_debut, nullif(j.c2_fin, '') as c2_fin,
       nullif(j.c3_debut, '') as c3_debut, nullif(j.c3_fin, '') as c3_fin
from public.jours j
join public.collaborateurs c on c.collab_id = j.collab_id;

-- Chevauchements : une personne sur deux séances prévues qui se recouvrent,
-- ou sur une séance prévue pendant une indisponibilité. Toutes fiches et tous ateliers confondus.
create view planning.v_chevauchement as
select a1.personne_id, s1.date_seance as date_jour,
       'seance'::text as nature, s1.id as seance_id, s2.id as autre_seance_id, null::bigint as indisponibilite_id,
       greatest(s1.heure_debut, s2.heure_debut) as debut, least(s1.heure_fin, s2.heure_fin) as fin
from planning.affectation a1
join planning.seance s1 on s1.id = a1.seance_id and s1.statut = 'prevue'
join planning.affectation a2 on a2.personne_id = a1.personne_id and a2.seance_id <> a1.seance_id
join planning.seance s2 on s2.id = a2.seance_id and s2.statut = 'prevue'
where s2.date_seance = s1.date_seance
  and s1.heure_debut < s2.heure_fin and s2.heure_debut < s1.heure_fin
union all
select a.personne_id, s.date_seance, 'indisponibilite', s.id, null, i.id,
       greatest(s.heure_debut, coalesce(i.heure_debut, '00:00')), least(s.heure_fin, coalesce(i.heure_fin, '23:59:59'))
from planning.affectation a
join planning.seance s on s.id = a.seance_id and s.statut = 'prevue'
join planning.indisponibilite i on i.personne_id = a.personne_id
where s.date_seance between i.date_debut and i.date_fin
  and (i.jours is null or extract(isodow from s.date_seance)::smallint = any (i.jours))
  and (i.heure_debut is null or (s.heure_debut < i.heure_fin and i.heure_debut < s.heure_fin));

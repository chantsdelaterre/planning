-- portee: planning
-- Un responsable ne lit en entier (contrat, heures, ateliers) que les personnes de son périmètre ;
-- les autres restent proposées par leur nom pour être affectées à ses séances. Chaque personne porte
-- « visible » : la vue « Par personne » ne propose que celles-là.

create or replace function planning.lire_semaine_vue(p_droits jsonb, p_lundi date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb := planning.lire_semaine(p_lundi); v bigint[] := planning.taches_visibles(p_droits);
        v_p bigint := (p_droits->>'personne_id')::bigint; s jsonb; vis bigint[];
begin
  if p_droits->>'niveau' in ('complet', 'consultation') then return r; end if;
  s := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(r->'seances') x
         where (v is null or (x->>'tache_id')::bigint = any (v))
            or x->'personnes' @> jsonb_build_array(jsonb_build_object('personne_id', v_p)));
  r := r || jsonb_build_object('seances', s, 'chevauchements', '[]'::jsonb,
         'indisponibilites', (select coalesce(jsonb_agg(i), '[]') from jsonb_array_elements(r->'indisponibilites') i where (i->>'personne_id')::bigint = v_p));
  -- Personnes : celles du périmètre (soi-même ; pour un responsable, les personnes de ses ateliers) en entier
  -- et marquées « visible » ; les autres par leur nom seulement (un responsable peut les affecter à ses séances ;
  -- un collaborateur ne voit que celles qui figurent sur les séances qu'il voit).
  vis := planning.personnes_visibles(p_droits, p_lundi, p_lundi + 6);
  r := r || jsonb_build_object('personnes', (select coalesce(jsonb_agg(
         case when (p->>'id')::bigint = any (vis) then p || '{"visible": true}'::jsonb
              else jsonb_build_object('id', p->'id', 'prenom', p->'prenom', 'nom', p->'nom', 'externe', p->'externe',
                                      'fiches', '[]'::jsonb, 'prevu_h', 0, 'ateliers_habituels', '[]'::jsonb, 'nature', p->'nature',
                                      'couleur', p->'couleur', 'visible', false) end), '[]')
       from jsonb_array_elements(r->'personnes') p
      where p_droits->>'niveau' = 'responsable'
         or (p->>'id')::bigint = v_p
         or exists (select 1 from jsonb_array_elements(s) x, jsonb_array_elements(x->'personnes') y where y->'personne_id' = p->'id')));
  return r;
end $$;

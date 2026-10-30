-- portee: validation
-- Porte d'entrée unique du planning pour les Edge Functions, et génération quotidienne.
--
-- public.planning_appel : appelable par service_role SEULEMENT (Edge Functions), comme les RPC
-- de Suivi des temps. Elle ne fait que transmettre à planning.api (SECURITY DEFINER, propriété
-- de planning_proprietaire, créée en 0009) : toute la logique s'exécute avec les droits restreints
-- du planning. L'identité (p_identite) est établie par l'Edge Function à partir du jeton.
create function public.planning_appel(p_identite jsonb, p_action text, p_params jsonb default '{}'::jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  return planning.api(p_identite, p_action, coalesce(p_params, '{}'::jsonb));
end $$;
revoke all on function public.planning_appel(jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.planning_appel(jsonb, text, jsonb) to service_role;
comment on function public.planning_appel(jsonb, text, jsonb) is
  'Porte d''entrée de l''appli planning (Edge Function planning-api). Logique dans le schéma planning.';

-- Génération des séances des séries : chaque nuit à 2 h 15 UTC, 8 semaines d'avance.
select cron.schedule('planning-generer-seances', '15 2 * * *', 'select planning.generer_seances()');

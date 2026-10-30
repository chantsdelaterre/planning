-- Vérifications après application des migrations. Chaque contrôle lève une erreur s'il échoue.
do $$
declare ok boolean;
begin
  -- Le rôle propriétaire ne peut pas écrire dans Suivi des temps.
  set local role planning_proprietaire;
  begin
    update public.collaborateurs set nom = nom where false;
    raise exception 'ÉCHEC : planning_proprietaire peut modifier public.collaborateurs';
  exception when insufficient_privilege then null;
  end;
  -- Ni lire les jetons.
  begin
    perform token from public.collaborateurs limit 1;
    raise exception 'ÉCHEC : planning_proprietaire peut lire les jetons';
  exception when insufficient_privilege then null;
  end;
  -- Ni le taux horaire.
  begin
    perform taux_horaire from public.historique_contrats limit 1;
    raise exception 'ÉCHEC : planning_proprietaire peut lire les taux horaires';
  exception when insufficient_privilege then null;
  end;
  -- Mais il lit les colonnes prévues.
  perform collab_id, prenom, nom, structure, heures_hebdo from public.collaborateurs limit 1;
  perform date_jour, c1_debut, total_heures from public.jours limit 1;
  reset role;

  -- anon et authenticated n'ont aucun accès au schéma planning.
  select has_schema_privilege('anon', 'planning', 'usage') into ok;
  if ok then raise exception 'ÉCHEC : anon a accès au schéma planning'; end if;
  select has_schema_privilege('authenticated', 'planning', 'usage') into ok;
  if ok then raise exception 'ÉCHEC : authenticated a accès au schéma planning'; end if;
  select has_schema_privilege('anon', 'planning_sauvegardes', 'usage') into ok;
  if ok then raise exception 'ÉCHEC : anon a accès aux sauvegardes'; end if;
  -- service_role y a accès.
  select has_schema_privilege('service_role', 'planning', 'usage') into ok;
  if not ok then raise exception 'ÉCHEC : service_role n''a pas accès au schéma planning'; end if;
end $$;
select 'Vérifications : toutes réussies';

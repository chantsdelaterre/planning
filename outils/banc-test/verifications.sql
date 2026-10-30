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
-- Référentiel (0002)
do $$
declare n int;
begin
  select count(*) into n from planning.activite;     if n <> 3  then raise exception 'ÉCHEC : % activités', n; end if;
  select count(*) into n from planning.atelier;      if n <> 7  then raise exception 'ÉCHEC : % ateliers', n; end if;
  select count(*) into n from planning.regroupement; if n <> 6  then raise exception 'ÉCHEC : % regroupements', n; end if;
  select count(*) into n from planning.tache;        if n <> 15 then raise exception 'ÉCHEC : % tâches', n; end if;
  select count(*) into n from planning.tache t join planning.regroupement r on r.id = t.regroupement_id
    where r.nom = 'Administration commerciale';      if n <> 2  then raise exception 'ÉCHEC : regroupement partagé'; end if;
  select count(*) into n from planning.atelier where au_demarrage; if n <> 2 then raise exception 'ÉCHEC : ateliers du démarrage'; end if;
  -- Une société inconnue est refusée, même pour service_role (les Edge Functions).
  set local role service_role;
  begin
    insert into planning.atelier (activite_id, nom, societe) select id, 'Test', 'XXX' from planning.activite limit 1;
    raise exception 'ÉCHEC : société inconnue acceptée';
  exception when foreign_key_violation then null;
  end;
  -- Une société connue est acceptée par service_role.
  insert into planning.atelier (activite_id, nom, societe) select id, 'Test service', 'SAS' from planning.activite limit 1;
  delete from planning.atelier where nom = 'Test service';
  -- Deux tâches du même nom dans un atelier : refusé.
  begin
    insert into planning.tache (atelier_id, nom) select id, 'récolte' from planning.atelier where nom = 'Jardin';
    raise exception 'ÉCHEC : doublon de tâche accepté';
  exception when unique_violation then null;
  end;
  reset role;
end $$;
select 'Vérifications : toutes réussies';

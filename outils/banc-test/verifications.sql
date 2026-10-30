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
  -- …et voit réellement les lignes malgré la RLS.
  if (select count(*) from public.structures) < 3 then raise exception 'ÉCHEC : RLS masque les structures'; end if;
  if (select count(*) from public.collaborateurs) < 1 then raise exception 'ÉCHEC : RLS masque les collaborateurs'; end if;
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
-- Personne (0004)
do $$
declare n int; p bigint; q bigint;
begin
  select count(*) into n from public.collaborateurs where personne_id is null;
  if n <> 0 then raise exception 'ÉCHEC : % fiches sans personne', n; end if;
  if (select count(*) from public.personne) <> (select count(*) from public.collaborateurs) - 2 then
    raise exception 'ÉCHEC : nombre de personnes'; end if;
  select personne_id into p from public.collaborateurs where collab_id = 'COLL032';
  select personne_id into q from public.collaborateurs where collab_id = 'COLL043';
  if p <> q then raise exception 'ÉCHEC : Yann non regroupé'; end if;
  if (select nom from public.personne where personne_id = p) <> 'EXEMPLE' then raise exception 'ÉCHEC : nom non nettoyé'; end if;
  select personne_id into p from public.collaborateurs where collab_id = 'COLL028';
  select personne_id into q from public.collaborateurs where collab_id = 'COLL035';
  if p <> q then raise exception 'ÉCHEC : Zoé non regroupée'; end if;
  if (select nom from public.personne where personne_id = p) <> 'FICTIVE' then raise exception 'ÉCHEC : nom de Zoé modifié'; end if;
  -- Nouvelle fiche, comme le fait creer_collaborateur_avec_contrat (colonnes explicites, sans personne_id).
  insert into public.collaborateurs (collab_id, token, prenom, nom, structure, actif) values ('T900','j900','Nouvelle','Fiche','SAS',true);
  select personne_id into p from public.collaborateurs where collab_id = 'T900';
  if p is null then raise exception 'ÉCHEC : personne non créée pour une nouvelle fiche'; end if;
  update public.collaborateurs set nom = 'Renommée' where collab_id = 'T900';
  if (select nom from public.personne where personne_id = p) <> 'Renommée' then raise exception 'ÉCHEC : nom non suivi'; end if;
  -- Une personne à deux fiches ne suit pas un renommage d'une seule fiche.
  update public.collaborateurs set nom = 'AUTRE' where collab_id = 'COLL043';
  if (select p2.nom from public.personne p2 join public.collaborateurs c on c.personne_id = p2.personne_id where c.collab_id = 'COLL043') <> 'EXEMPLE' then
    raise exception 'ÉCHEC : personne à deux fiches renommée'; end if;
  -- Droits : anon n'a rien, le planning lit.
  if has_table_privilege('anon', 'public.personne', 'select') then raise exception 'ÉCHEC : anon lit personne'; end if;
  set local role planning_proprietaire;
  if (select count(*) from public.personne) < 1 then raise exception 'ÉCHEC : planning ne voit pas les personnes'; end if;
  perform personne_id from public.collaborateurs limit 1;
  reset role;
  -- Nettoyage du test
  delete from public.collaborateurs where collab_id = 'T900';
  delete from public.personne where personne_id = p;
end $$;
-- Cœur (0005)
do $$
declare p bigint; t bigint; s bigint;
begin
  select personne_id into p from public.collaborateurs where collab_id = 'T001';
  select id into t from planning.tache where nom = 'Ensachage';
  insert into planning.serie (tache_id, jours, heure_debut, heure_fin, date_debut) values (t, '{2,3}', '09:00', '12:00', '2026-11-02') returning id into s;
  -- Heure de fin avant le début : refusé.
  begin
    insert into planning.serie (tache_id, jours, heure_debut, heure_fin, date_debut) values (t, '{1}', '12:00', '09:00', '2026-11-02');
    raise exception 'ÉCHEC : série à l''envers acceptée';
  exception when check_violation then null; end;
  -- Jour 8 : refusé.
  begin
    insert into planning.serie (tache_id, jours, heure_debut, heure_fin, date_debut) values (t, '{8}', '09:00', '12:00', '2026-11-02');
    raise exception 'ÉCHEC : jour 8 accepté';
  exception when check_violation then null; end;
  -- Deux séances pour la même date de série : refusé.
  insert into planning.seance (tache_id, serie_id, date_serie, societe, date_seance, heure_debut, heure_fin) values (t, s, '2026-11-03', 'SAS', '2026-11-03', '09:00', '12:00');
  begin
    insert into planning.seance (tache_id, serie_id, date_serie, societe, date_seance, heure_debut, heure_fin) values (t, s, '2026-11-03', 'SAS', '2026-11-04', '09:00', '12:00');
    raise exception 'ÉCHEC : séance de série en double acceptée';
  exception when unique_violation then null; end;
  -- Société inconnue sur une séance : refusé.
  begin
    insert into planning.seance (tache_id, societe, date_seance, heure_debut, heure_fin) values (t, 'XXX', '2026-11-05', '09:00', '10:00');
    raise exception 'ÉCHEC : société inconnue acceptée sur une séance';
  exception when foreign_key_violation then null; end;
  -- Jour fermé pour toute l'entreprise, deux fois : refusé.
  insert into planning.jour_ferme (date, motif) values ('2026-11-11', 'Armistice');
  begin
    insert into planning.jour_ferme (date) values ('2026-11-11');
    raise exception 'ÉCHEC : jour fermé en double';
  exception when unique_violation then null; end;
  -- Nettoyage
  delete from planning.jour_ferme; delete from planning.seance; delete from planning.serie;
end $$;
-- Règles (0007)
do $$
declare t bigint; s bigint; yann bigint; chloe bigint; ext bigint; n int; x bigint; r record;
begin
  select id into t from planning.tache where nom = 'Ensachage';
  select personne_id into yann from public.collaborateurs where collab_id = 'COLL032';
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  insert into public.personne (prenom, nom, externe) values ('Intérim', 'Fictif', true) returning personne_id into ext;
  insert into planning.jour_ferme (date, motif) values ('2026-11-11', 'Armistice');
  insert into planning.serie (tache_id, jours, heure_debut, heure_fin, date_debut)
    values (t, '{2,3}', '09:00', '12:00', '2026-11-02') returning id into s;
  insert into planning.serie_personne values (s, yann), (s, chloe), (s, ext);
  n := planning.generer_seances('2026-11-15', '2026-11-02');
  if n <> 4 then raise exception 'ÉCHEC : % séances générées au lieu de 4', n; end if;
  if planning.generer_seances('2026-11-15', '2026-11-02') <> 0 then raise exception 'ÉCHEC : génération non idempotente'; end if;
  if (select statut from planning.seance where serie_id = s and date_serie = '2026-11-11') <> 'suspendue' then
    raise exception 'ÉCHEC : jour fermé non suspendu'; end if;
  -- Fiches imputées : Yann (fiches SAS + SARL) sur un atelier SAS -> fiche SAS ; Chloé (SCEA) -> mise à disposition ; externe -> aucune.
  select * into r from planning.affectation a join planning.seance se on se.id = a.seance_id
    where se.serie_id = s and se.date_serie = '2026-11-03' and a.personne_id = yann;
  if r.collab_id <> 'COLL032' or r.mad then raise exception 'ÉCHEC : fiche de Yann (% %)', r.collab_id, r.mad; end if;
  select * into r from planning.affectation a join planning.seance se on se.id = a.seance_id
    where se.serie_id = s and se.date_serie = '2026-11-03' and a.personne_id = chloe;
  if r.collab_id <> 'T004' or not r.mad then raise exception 'ÉCHEC : màd de Chloé'; end if;
  select * into r from planning.affectation a join planning.seance se on se.id = a.seance_id
    where se.serie_id = s and se.date_serie = '2026-11-03' and a.personne_id = ext;
  if r.collab_id is not null or r.mad then raise exception 'ÉCHEC : externe'; end if;
  -- Main-d'œuvre : 3 h x 3 personnes ; 0 si suspendue.
  if (select main_oeuvre_h from planning.v_seance where serie_id = s and date_serie = '2026-11-03') <> 9 then
    raise exception 'ÉCHEC : main-d''œuvre'; end if;
  if (select main_oeuvre_h from planning.v_seance where serie_id = s and date_serie = '2026-11-11') <> 0 then
    raise exception 'ÉCHEC : séance suspendue comptée'; end if;
  -- Déplacement : la séance du mercredi 4 passe au jeudi 5 ; la série ne la recrée pas.
  update planning.seance set date_seance = '2026-11-05', modifiee = true where serie_id = s and date_serie = '2026-11-04';
  if planning.generer_seances('2026-11-15', '2026-11-02') <> 0 then raise exception 'ÉCHEC : séance déplacée recréée'; end if;
  if not (select deplacee from planning.v_seance where serie_id = s and date_serie = '2026-11-04') then raise exception 'ÉCHEC : déplacement non vu'; end if;
  -- Chevauchement : Yann aussi sur une séance ponctuelle 10:00-11:00 le mardi 3.
  insert into planning.seance (tache_id, societe, date_seance, heure_debut, heure_fin)
    values (t, 'SAS', '2026-11-03', '10:00', '11:00') returning id into x;
  perform planning.affecter(x, yann);
  select count(*) into n from planning.v_chevauchement where personne_id = yann and date_jour = '2026-11-03';
  if n <> 2 then raise exception 'ÉCHEC : % lignes de chevauchement au lieu de 2', n; end if;
  -- Indisponibilité de Chloé le mardi matin.
  insert into planning.indisponibilite (personne_id, date_debut, date_fin, jours, heure_debut, heure_fin, motif)
    values (chloe, '2026-11-01', '2026-11-30', '{2}', '08:00', '10:00', 'Formation');
  if (select count(*) from planning.v_chevauchement where personne_id = chloe and nature = 'indisponibilite') <> 2 then
    raise exception 'ÉCHEC : indisponibilité non détectée'; end if;
  -- Prévu par jour : Yann le 3 = 3 h + 1 h.
  if (select sum(heures) from planning.v_prevu_jour where personne_id = yann and date_jour = '2026-11-03') <> 4 then
    raise exception 'ÉCHEC : prévu du jour'; end if;
  -- Le rôle des Edge Functions lit les vues.
  set local role service_role;
  perform * from planning.v_seance limit 1; perform * from planning.v_chevauchement limit 1;
  perform * from planning.v_realise_jour limit 1; perform * from planning.v_prevu_jour limit 1;
  perform planning.generer_seances('2026-11-15', '2026-11-02');
  reset role;
  delete from planning.indisponibilite; delete from planning.seance; delete from planning.serie; delete from planning.jour_ferme;
  delete from public.personne where personne_id = ext;
end $$;
select 'Vérifications : toutes réussies';

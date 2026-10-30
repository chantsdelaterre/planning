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
-- Porte d'entrée et API (0008, 0009), par la vraie porte, avec le rôle des Edge Functions.
do $$
declare
  adm jsonb := '{"type":"admin","admin_id":"admin_test1"}';
  pauline jsonb := '{"type":"admin","admin_id":"admin_test2"}';
  resp jsonb; collab jsonb; r jsonb; t_appro bigint; t_paniers bigint; lundi date; n int;
  anna bigint; chloe bigint; yann bigint; v_serie bigint; v_seance bigint; v_seance2 bigint;
begin
  if not exists (select 1 from cron.job where jobname = 'planning-generer-seances') then raise exception 'ÉCHEC : cron non planifié'; end if;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  select personne_id into yann from public.collaborateurs where collab_id = 'COLL032';
  select t.id into t_appro from planning.tache t join planning.atelier a on a.id = t.atelier_id where a.nom = 'Appros-marchés' and t.nom = 'Vente St Jo';
  select t.id into t_paniers from planning.tache t join planning.atelier a on a.id = t.atelier_id where a.nom = 'Paniers' and t.nom = 'Ensachage';
  insert into planning.acces_admin values ('admin_test1', 'complet');
  insert into planning.atelier_responsable select id, anna from planning.atelier where nom = 'Appros-marchés';
  resp := jsonb_build_object('type','collab','collab_id','T001','personne_id',anna);
  collab := jsonb_build_object('type','collab','collab_id','T004','personne_id',chloe);
  lundi := date_trunc('week', current_date)::date + 7;

  set local role service_role;
  -- Droits
  r := public.planning_appel(adm, 'session');
  if r->'droits'->>'niveau' <> 'complet' or jsonb_array_length(r->'droits'->'ateliers') <> 7 then raise exception 'ÉCHEC : droits admin %', r->'droits'; end if;
  if jsonb_array_length(r->'referentiel'->'taches') <> 15 then raise exception 'ÉCHEC : référentiel'; end if;
  if public.planning_appel(pauline, 'session')->'droits'->>'niveau' <> 'consultation' then raise exception 'ÉCHEC : admin sans réglage'; end if;
  if public.planning_appel(resp, 'session')->'droits'->>'niveau' <> 'responsable' then raise exception 'ÉCHEC : responsable'; end if;
  if public.planning_appel(collab, 'session')->'droits'->>'niveau' <> 'collaborateur' then raise exception 'ÉCHEC : collaborateur'; end if;

  -- Le responsable crée une série St Jo le samedi, avec Yann et Chloé.
  r := public.planning_appel(resp, 'serie_creer', jsonb_build_object('tache_id', t_appro, 'jours', jsonb_build_array(6),
         'debut', '07:30', 'fin', '12:30', 'date_debut', lundi, 'personnes', jsonb_build_array(yann, chloe)));
  v_serie := (r->>'serie_id')::bigint;
  if (r->>'seances_creees')::int < 8 then raise exception 'ÉCHEC : % séances créées', r->>'seances_creees'; end if;

  -- Il ne peut pas toucher aux Paniers, ni fermer une journée.
  begin perform public.planning_appel(resp, 'seance_creer', jsonb_build_object('tache_id', t_paniers, 'date', lundi, 'debut', '09:00', 'fin', '10:00'));
    raise exception 'ÉCHEC : responsable a modifié un autre atelier'; exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.planning_appel(resp, 'jour_fermer', jsonb_build_object('date', lundi));
    raise exception 'ÉCHEC : responsable a fermé une journée'; exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  -- Ni un collaborateur, ni Pauline ne peuvent écrire.
  begin perform public.planning_appel(collab, 'seance_creer', jsonb_build_object('tache_id', t_appro, 'date', lundi, 'debut', '09:00', 'fin', '10:00'));
    raise exception 'ÉCHEC : collaborateur a écrit'; exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.planning_appel(pauline, 'seance_creer', jsonb_build_object('tache_id', t_appro, 'date', lundi, 'debut', '09:00', 'fin', '10:00'));
    raise exception 'ÉCHEC : consultation a écrit'; exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if; end;

  -- La semaine : la séance du samedi, avec ses deux personnes, Chloé en màd.
  r := public.planning_appel(collab, 'semaine', jsonb_build_object('lundi', lundi));
  if jsonb_array_length(r->'seances') <> 1 then raise exception 'ÉCHEC : % séances dans la semaine', jsonb_array_length(r->'seances'); end if;
  v_seance := (r->'seances'->0->>'id')::bigint;
  if jsonb_array_length(r->'seances'->0->'personnes') <> 2 then raise exception 'ÉCHEC : personnes de la séance'; end if;
  if not exists (select 1 from jsonb_array_elements(r->'seances'->0->'personnes') e where (e->>'personne_id')::bigint = chloe and (e->>'mad')::boolean) then
    raise exception 'ÉCHEC : màd non visible'; end if;
  -- Le panneau complet des personnes : pour la consultation ; un collaborateur ne voit que les noms utiles.
  if jsonb_array_length(public.planning_appel(pauline, 'semaine', jsonb_build_object('lundi', lundi))->'personnes') < 5 then raise exception 'ÉCHEC : panneau des personnes'; end if;

  -- L'admin ajoute une séance Paniers le samedi 9 h avec Yann : chevauchement signalé.
  r := public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t_paniers, 'date', lundi + 5, 'debut', '09:00', 'fin', '10:00'));
  v_seance2 := (r->>'seance_id')::bigint;
  r := public.planning_appel(adm, 'affecter', jsonb_build_object('seance_id', v_seance2, 'personne_id', yann));
  if jsonb_array_length(r->'chevauchements') <> 2 then raise exception 'ÉCHEC : chevauchement à l''affectation'; end if;
  r := public.planning_appel(adm, 'retirer', jsonb_build_object('seance_id', v_seance2, 'personne_id', yann));
  if jsonb_array_length(r->'chevauchements') <> 0 then raise exception 'ÉCHEC : chevauchement après retrait'; end if;

  -- Déplacer cette seule séance au vendredi : la semaine suivante ne bouge pas.
  perform public.planning_appel(resp, 'seance_modifier', jsonb_build_object('seance_id', v_seance, 'date', lundi + 4, 'portee', 'seance'));
  r := public.planning_appel(resp, 'semaine', jsonb_build_object('lundi', lundi + 7));
  if (select count(*) from jsonb_array_elements(r->'seances') e where (e->>'tache_id')::bigint = t_appro and (e->>'date_seance')::date = lundi + 12) <> 1 then
    raise exception 'ÉCHEC : la semaine suivante a bougé'; end if;

  -- Cette séance et les suivantes, semaine d'après : samedi -> dimanche, 08:00-13:00.
  select (e->>'id')::bigint into v_seance from jsonb_array_elements(r->'seances') e where (e->>'tache_id')::bigint = t_appro;
  perform public.planning_appel(resp, 'seance_modifier', jsonb_build_object('seance_id', v_seance, 'date', lundi + 13, 'debut', '08:00', 'fin', '13:00', 'portee', 'suivantes'));
  r := public.planning_appel(resp, 'semaine', jsonb_build_object('lundi', lundi + 14));
  if (select count(*) from jsonb_array_elements(r->'seances') e where (e->>'tache_id')::bigint = t_appro
        and (e->>'date_seance')::date = lundi + 20 and e->>'heure_debut' = '08:00:00') <> 1 then
    raise exception 'ÉCHEC : la série n''a pas suivi (dimanche 08:00)'; end if;
  if (select count(*) from jsonb_array_elements(r->'seances') e where (e->>'tache_id')::bigint = t_appro and (e->>'date_seance')::date = lundi + 19) <> 0 then
    raise exception 'ÉCHEC : l''ancien samedi existe encore'; end if;
  -- La première semaine garde son vendredi.
  r := public.planning_appel(resp, 'semaine', jsonb_build_object('lundi', lundi));
  if (select count(*) from jsonb_array_elements(r->'seances') e where (e->>'tache_id')::bigint = t_appro and (e->>'date_seance')::date = lundi + 4) <> 1 then
    raise exception 'ÉCHEC : la séance déplacée seule a disparu'; end if;

  -- L'admin ferme le dimanche de la 3e semaine : séance suspendue, plus comptée.
  r := public.planning_appel(adm, 'jour_fermer', jsonb_build_object('date', lundi + 20, 'motif', 'Test'));
  if (r->>'seances_suspendues')::int <> 1 then raise exception 'ÉCHEC : fermeture'; end if;

  -- Journal tenu.
  reset role;
  select count(*) into n from planning.journal;
  if n <> 7 then raise exception 'ÉCHEC : journal (% lignes)', n; end if;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie;
  delete from planning.jour_ferme; delete from planning.journal; delete from planning.atelier_responsable; delete from planning.acces_admin;
end $$;
-- Suppression (0010)
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; s bigint; x bigint; lundi date; r jsonb; n int;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select id into t from planning.tache where nom = 'Ensachage';
  lundi := date_trunc('week', current_date)::date + 7;
  set local role service_role;
  -- Ponctuelle : supprimée pour de bon.
  r := public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t, 'date', lundi, 'debut', '09:00', 'fin', '10:00'));
  x := (r->>'seance_id')::bigint;
  perform public.planning_appel(adm, 'seance_supprimer', jsonb_build_object('seance_id', x));
  if exists (select 1 from planning.seance where id = x) then raise exception 'ÉCHEC : ponctuelle non supprimée'; end if;
  -- De série : masquée, et la génération ne la recrée pas.
  r := public.planning_appel(adm, 'serie_creer', jsonb_build_object('tache_id', t, 'jours', jsonb_build_array(1), 'debut', '09:00', 'fin', '12:00', 'date_debut', lundi));
  s := (r->>'serie_id')::bigint;
  select id into x from planning.seance where serie_id = s and date_serie = lundi;
  perform public.planning_appel(adm, 'seance_supprimer', jsonb_build_object('seance_id', x));
  r := public.planning_appel(adm, 'semaine', jsonb_build_object('lundi', lundi));
  if jsonb_array_length(r->'seances') <> 0 then raise exception 'ÉCHEC : séance supprimée encore visible'; end if;
  perform planning.generer_seances(lundi + 56, lundi);
  select count(*) into n from planning.seance where serie_id = s and date_serie = lundi;
  if n <> 1 then raise exception 'ÉCHEC : séance supprimée recréée (%)', n; end if;
  r := public.planning_appel(adm, 'semaine', jsonb_build_object('lundi', lundi + 7));
  if jsonb_array_length(r->'seances') <> 1 then raise exception 'ÉCHEC : la semaine suivante a perdu sa séance'; end if;
  reset role;
  if not exists (select 1 from planning.journal where action = 'supprimer') then raise exception 'ÉCHEC : suppression non journalisée'; end if;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
end $$;
-- Correctif 0011 : modifier la PREMIÈRE séance d'une série, « cette séance et les suivantes ».
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; s bigint; x bigint; lundi date; r jsonb; n int;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select id into t from planning.tache where nom = 'Ensachage';
  lundi := date_trunc('week', current_date)::date + 7;
  set local role service_role;
  r := public.planning_appel(adm, 'serie_creer', jsonb_build_object('tache_id', t, 'jours', jsonb_build_array(2, 4), 'debut', '09:00', 'fin', '12:00', 'date_debut', lundi));
  s := (r->>'serie_id')::bigint;
  select id into x from planning.seance where serie_id = s order by date_serie limit 1;
  -- 9:00 -> 9:15, première séance, et les suivantes (le cas qui échouait)
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'debut', '09:15', 'fin', '12:15', 'portee', 'suivantes'));
  select count(*) into n from planning.seance where supprimee_le is null and heure_debut <> '09:15' and date_seance >= lundi and tache_id = t;
  if n <> 0 then raise exception 'ÉCHEC : % séances pas à 9 h 15', n; end if;
  select count(*) into n from planning.seance where tache_id = t and date_seance between lundi and lundi + 6;
  if n <> 2 then raise exception 'ÉCHEC : % séances la première semaine au lieu de 2', n; end if;
  if (select count(*) from planning.serie where tache_id = t) <> 1 then raise exception 'ÉCHEC : série dédoublée'; end if;
  -- Première séance déplacée d'un jour (mardi -> mercredi), et les suivantes : la série passe mercredi + vendredi.
  select id into x from planning.seance where serie_id = s order by date_serie limit 1;
  perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'date', lundi + 2, 'portee', 'suivantes'));
  if (select jours from planning.serie where id = s) <> '{3,5}' then raise exception 'ÉCHEC : jours de la série %', (select jours from planning.serie where id = s); end if;
  select count(*) into n from planning.seance where tache_id = t and date_seance between lundi and lundi + 6 and extract(isodow from date_seance) in (3, 5);
  if n <> 2 then raise exception 'ÉCHEC : mercredi + vendredi non générés (%)', n; end if;
  -- Une erreur inattendue n'est plus muette.
  select id into x from planning.seance where serie_id = s and supprimee_le is null order by date_serie limit 1;
  begin
    perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'debut', '12:00', 'fin', '11:00', 'portee', 'seance'));
    raise exception 'ÉCHEC : fin avant début acceptée';
  exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
    if sqlerrm not like 'La fin doit être après le début%' then raise exception 'ÉCHEC : message %', sqlerrm; end if;
  end;
  reset role;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérifications : toutes réussies';

-- 13. Changer la tâche d'une séance (SAS -> SCEA) : la société suit, la mise à disposition est recalculée.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t_sas bigint; t_scea bigint; x bigint; anna bigint; r jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t.id into t_sas from planning.tache t join planning.atelier a on a.id = t.atelier_id where a.societe = 'SAS' limit 1;
  select t.id into t_scea from planning.tache t join planning.atelier a on a.id = t.atelier_id where a.societe = 'SCEA' limit 1;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  set local role service_role;
  r := public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t_sas, 'date', current_date + 1, 'debut', '09:00', 'fin', '10:00', 'personnes', jsonb_build_array(anna)));
  x := (r->>'seance_id')::bigint;
  if (select mad from planning.affectation where seance_id = x) then raise exception 'ÉCHEC : Anna en MAD sur SAS'; end if;
  perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'tache_id', t_scea, 'portee', 'seance'));
  if (select tache_id from planning.seance where id = x) <> t_scea then raise exception 'ÉCHEC : tâche non changée'; end if;
  if (select societe from planning.seance where id = x) <> 'SCEA' then raise exception 'ÉCHEC : société non suivie'; end if;
  if not (select mad from planning.affectation where seance_id = x) then raise exception 'ÉCHEC : MAD non recalculée'; end if;
  reset role;
  delete from planning.seance; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 13 : réussie';

-- 14. Modifier les personnes d'une séance : seule, puis pour les suivantes de la série.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; s bigint; x bigint; y bigint; anna bigint; chloe bigint; lundi date := date_trunc('week', current_date)::date + 7; r jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t2.id into t from planning.tache t2 join planning.atelier a on a.id = t2.atelier_id where a.societe = 'SAS' limit 1;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  set local role service_role;
  r := public.planning_appel(adm, 'serie_creer', jsonb_build_object('tache_id', t, 'jours', jsonb_build_array(1, 3), 'debut', '09:00', 'fin', '10:00', 'date_debut', lundi, 'personnes', jsonb_build_array(anna)));
  s := (r->>'serie_id')::bigint;
  select id into x from planning.seance where serie_id = s order by date_serie limit 1;
  select id into y from planning.seance where serie_id = s order by date_serie offset 1 limit 1;
  -- Cette séance seulement : Anna remplacée par Chloé (mise à disposition SCEA -> SAS).
  perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'personnes', jsonb_build_array(chloe), 'portee', 'seance'));
  if (select array_agg(personne_id) from planning.affectation where seance_id = x) <> array[chloe] then raise exception 'ÉCHEC : personnes de la séance'; end if;
  if not (select mad from planning.affectation where seance_id = x) then raise exception 'ÉCHEC : MAD de Chloé'; end if;
  if (select array_agg(personne_id) from planning.affectation where seance_id = y) <> array[anna] then raise exception 'ÉCHEC : la suivante a changé'; end if;
  -- La suivante et les autres : Anna + Chloé.
  perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', y, 'personnes', jsonb_build_array(anna, chloe), 'portee', 'suivantes'));
  if (select count(*) from planning.seance se where se.tache_id = t and se.date_seance > lundi and se.supprimee_le is null
        and (select count(*) from planning.affectation a where a.seance_id = se.id) <> 2) > 0 then raise exception 'ÉCHEC : suivantes sans les deux personnes'; end if;
  if (select array_agg(personne_id) from planning.affectation where seance_id = x) <> array[chloe] then raise exception 'ÉCHEC : la première a changé'; end if;
  reset role;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 14 : réussie';

-- 15. Répétition dans la fenêtre : séance isolée -> série ; jours et fin d'une série modifiés.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; s bigint; x bigint; anna bigint; lundi date := date_trunc('week', current_date)::date + 7; r jsonb; n int;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t2.id into t from planning.tache t2 join planning.atelier a on a.id = t2.atelier_id where a.societe = 'SAS' limit 1;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  set local role service_role;
  -- Séance isolée le lundi, avec Anna, devient une série lundi + jeudi sur 2 semaines.
  r := public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t, 'date', lundi, 'debut', '09:00', 'fin', '10:00', 'personnes', jsonb_build_array(anna)));
  x := (r->>'seance_id')::bigint;
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'jours', jsonb_build_array(1, 4), 'date_fin_serie', lundi + 13, 'portee', 'seance'));
  s := (r->>'serie_id')::bigint;
  if s is null then raise exception 'ÉCHEC : pas de série créée'; end if;
  if exists (select 1 from planning.seance where id = x) then raise exception 'ÉCHEC : la séance isolée reste'; end if;
  select count(*) into n from planning.seance where serie_id = s and supprimee_le is null;
  if n <> 4 then raise exception 'ÉCHEC : % séances au lieu de 4', n; end if;
  if (select count(*) from planning.affectation a join planning.seance se on se.id = a.seance_id where se.serie_id = s) <> 4 then raise exception 'ÉCHEC : Anna pas reprise'; end if;
  -- Depuis le jeudi de la 1re semaine : mardi seulement, sans fin.
  select id into x from planning.seance where serie_id = s and date_serie = lundi + 3;
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'jours', jsonb_build_array(2), 'date_fin_serie', null, 'portee', 'seance'));
  if not exists (select 1 from planning.seance where serie_id = s and date_serie = lundi) then raise exception 'ÉCHEC : le premier lundi a disparu'; end if;
  if exists (select 1 from planning.seance se join planning.serie sr on sr.id = se.serie_id where se.tache_id = t and se.date_seance > lundi + 3 and se.supprimee_le is null and extract(isodow from se.date_seance) <> 2)
    then raise exception 'ÉCHEC : jours non changés'; end if;
  if (select date_fin from planning.serie where id = (r->>'serie_id')::bigint) is not null then raise exception 'ÉCHEC : fin non levée'; end if;
  if (select count(*) from planning.seance where tache_id = t and date_seance > lundi + 14 and supprimee_le is null) = 0 then raise exception 'ÉCHEC : la série ne continue pas'; end if;
  -- Fin avant la séance : refusée.
  begin
    perform public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', (select id from planning.seance where serie_id = s and date_serie = lundi), 'date_fin_serie', lundi - 1));
    raise exception 'ÉCHEC : fin incohérente acceptée';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 15 : réussie';

-- 16. Séries toutes les 2 semaines : création, modification « et les suivantes » qui garde le rythme.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; s bigint; x bigint; lundi date := date_trunc('week', current_date)::date + 7; r jsonb; n int;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t2.id into t from planning.tache t2 join planning.atelier a on a.id = t2.atelier_id where a.societe = 'SAS' limit 1;
  set local role service_role;
  r := public.planning_appel(adm, 'serie_creer', jsonb_build_object('tache_id', t, 'jours', jsonb_build_array(2), 'intervalle', 2, 'debut', '09:00', 'fin', '10:00', 'date_debut', lundi, 'date_fin', lundi + 41));
  s := (r->>'serie_id')::bigint;
  -- 6 semaines, un mardi sur deux : semaines 0, 2, 4.
  if (select array_agg(date_seance - lundi order by date_seance) from planning.seance where serie_id = s) <> array[1, 15, 29] then
    raise exception 'ÉCHEC : dates %', (select array_agg(date_seance - lundi order by date_seance) from planning.seance where serie_id = s); end if;
  -- Depuis la 2e séance : passage à 9 h 30, et les suivantes. Le rythme reste (semaines 2 et 4).
  select id into x from planning.seance where serie_id = s and date_serie = lundi + 15;
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'debut', '09:30', 'fin', '10:30', 'portee', 'suivantes'));
  if (select array_agg(date_seance - lundi order by date_seance) from planning.seance where tache_id = t and supprimee_le is null) <> array[1, 15, 29] then raise exception 'ÉCHEC : rythme perdu'; end if;
  -- Repasser à toutes les semaines depuis la 2e séance.
  select id into x from planning.seance where tache_id = t and date_seance = lundi + 15 and supprimee_le is null;
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', x, 'intervalle', 1, 'portee', 'seance'));
  select count(*) into n from planning.seance where tache_id = t and supprimee_le is null;
  if n <> 5 then raise exception 'ÉCHEC : % séances au lieu de 5 (1 + semaines 2 à 5)', n; end if;
  -- Une séance isolée devient une série toutes les 3 semaines.
  r := public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t, 'date', lundi + 4, 'debut', '14:00', 'fin', '15:00'));
  r := public.planning_appel(adm, 'seance_modifier', jsonb_build_object('seance_id', (r->>'seance_id')::bigint, 'jours', jsonb_build_array(5), 'intervalle', 3, 'date_fin_serie', lundi + 48));
  if (select array_agg(date_seance - lundi order by date_seance) from planning.seance where serie_id = (r->>'serie_id')::bigint) <> array[4, 25, 46] then raise exception 'ÉCHEC : toutes les 3 semaines'; end if;
  reset role;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 16 : réussie';

-- 17. Récapitulatifs : prévu, réalisé (Suivi des temps), contrats ; un collaborateur ne voit que lui.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; t bigint; anna bigint; chloe bigint; lundi date := date_trunc('week', current_date)::date; r jsonb; me jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t2.id into t from planning.tache t2 join planning.atelier a on a.id = t2.atelier_id where a.societe = 'SAS' limit 1;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  insert into public.historique_contrats (collab_id, date_debut, structure, type_contrat, heures_hebdo) values ('T001', lundi - 30, 'SAS', 'CDI', 35), ('T004', lundi - 30, 'SCEA', 'CDI', 35);
  insert into public.jours (jour_id, collab_id, date_jour, type_jour, total_heures) values
    ('T001_a', 'T001', lundi, 'travaillée', 7.5), ('T001_b', 'T001', lundi + 1, 'CP', 0), ('T001_c', 'T001', lundi + 2, 'travaillée', 0),
    ('T004_a', 'T004', lundi, 'travaillée', 6);
  set local role service_role;
  perform public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', t, 'date', lundi, 'debut', '08:00', 'fin', '12:00', 'personnes', jsonb_build_array(anna, chloe)));
  r := public.planning_appel(adm, 'recap', jsonb_build_object('debut', lundi, 'fin', lundi + 6));
  if jsonb_array_length(r->'prevu') <> 2 then raise exception 'ÉCHEC : prévu %', r->'prevu'; end if;
  if jsonb_array_length(r->'realise') <> 3 then raise exception 'ÉCHEC : réalisé % (le jour à 0 h travaillé ne doit pas sortir)', r->'realise'; end if;
  if jsonb_array_length(r->'mo') <> 1 or (r->'mo'->0->>2)::numeric <> 8 then raise exception 'ÉCHEC : main-d''œuvre %', r->'mo'; end if;
  if jsonb_array_length(r->'contrats') < 2 then raise exception 'ÉCHEC : contrats'; end if;
  -- Collaborateur : seulement lui, pas de main-d'œuvre.
  me := jsonb_build_object('type', 'collab', 'personne_id', anna);
  r := public.planning_appel(me, 'recap', jsonb_build_object('debut', lundi, 'fin', lundi + 6));
  if exists (select 1 from jsonb_array_elements(r->'prevu') e where (e->>0)::bigint <> anna)
     or exists (select 1 from jsonb_array_elements(r->'realise') e where (e->>0)::bigint <> anna)
     or exists (select 1 from jsonb_array_elements(r->'contrats') e where (e->>0)::bigint <> anna)
     or jsonb_array_length(r->'personnes') <> 1 or jsonb_array_length(r->'mo') <> 0 then raise exception 'ÉCHEC : un collaborateur voit les autres'; end if;
  begin
    perform public.planning_appel(adm, 'recap', jsonb_build_object('debut', lundi, 'fin', lundi + 500));
    raise exception 'ÉCHEC : période trop longue acceptée';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role;
  delete from public.jours; delete from public.historique_contrats;
  delete from planning.seance; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 17 : réussie';

-- 18-19. Personnes sans fiche : un responsable en crée une, on la planifie, puis on la rattache à la
-- vraie personne quand sa fiche arrive dans Suivi des temps. Le planning ne peut toucher aucune personne avec fiche.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; resp jsonb; t bigint; at bigint; s bigint; x bigint;
        anna bigint; nouveau bigint; vrai bigint; r jsonb; lundi date := date_trunc('week', current_date)::date + 7;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select t2.id, t2.atelier_id into t, at from planning.tache t2 join planning.atelier a on a.id = t2.atelier_id where a.societe = 'SAS' limit 1;
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  insert into planning.atelier_responsable values (at, anna);
  resp := jsonb_build_object('type', 'collab', 'personne_id', anna);
  set local role service_role;
  -- Un responsable crée « Léo Nouveau », à venir, et le planifie sur une série.
  r := public.planning_appel(resp, 'personne_creer', '{"prenom":"Léo","nom":"Nouveau","nature":"a_venir"}');
  nouveau := (r->>'personne_id')::bigint;
  if not exists (select 1 from jsonb_array_elements(public.planning_appel(adm, 'semaine', jsonb_build_object('lundi', lundi))->'personnes') e
                  where (e->>'id')::bigint = nouveau and e->>'nature' = 'a_venir') then raise exception 'ÉCHEC : la personne à venir n''est pas proposée'; end if;
  r := public.planning_appel(resp, 'serie_creer', jsonb_build_object('tache_id', t, 'jours', jsonb_build_array(1, 3), 'debut', '09:00', 'fin', '12:00', 'date_debut', lundi, 'date_fin', lundi + 13, 'personnes', jsonb_build_array(nouveau)));
  s := (r->>'serie_id')::bigint;
  if (select count(*) from planning.affectation where personne_id = nouveau) <> 4 then raise exception 'ÉCHEC : séances de la personne à venir'; end if;
  if exists (select 1 from planning.affectation where personne_id = nouveau and collab_id is not null) then raise exception 'ÉCHEC : fiche imputée à une personne sans fiche'; end if;
  -- Un responsable ne peut ni rattacher ni toucher au référentiel.
  begin perform public.planning_appel(resp, 'ref_enregistrer', '{"type":"activite","nom":"X"}'); raise exception 'ÉCHEC : responsable sur le référentiel';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role;
  -- Suivi des temps crée la fiche (son déclencheur crée la vraie personne).
  insert into public.collaborateurs (collab_id, prenom, nom, structure, type_contrat, heures_hebdo, actif, token) values ('T099', 'Léo', 'NOUVEAU', 'SAS', 'CDD', 35, false, 'jL');
  select personne_id into vrai from public.collaborateurs where collab_id = 'T099';
  set local role service_role;
  r := public.planning_appel(adm, 'admin_lire', '{}');
  if not exists (select 1 from jsonb_array_elements(r->'personnes') e where (e->>'id')::bigint = nouveau and e->'suggestions' @> to_jsonb(vrai)) then
    raise exception 'ÉCHEC : pas de suggestion de rattachement'; end if;
  r := public.planning_appel(adm, 'personne_rattacher', jsonb_build_object('source', nouveau, 'cible', vrai));
  if (r->>'seances')::int <> 4 then raise exception 'ÉCHEC : % séances rattachées', r->>'seances'; end if;
  if exists (select 1 from public.personne where personne_id = nouveau) then raise exception 'ÉCHEC : la personne provisoire reste'; end if;
  if (select count(*) from planning.affectation where personne_id = vrai and collab_id = 'T099' and not mad) <> 4 then raise exception 'ÉCHEC : fiche non imputée après rattachement'; end if;
  if not exists (select 1 from planning.serie_personne where serie_id = s and personne_id = vrai) then raise exception 'ÉCHEC : série non rattachée'; end if;
  -- Une personne avec fiche ne peut être ni renommée ni rattachée depuis le planning.
  begin perform public.planning_appel(adm, 'personne_modifier', jsonb_build_object('personne_id', anna, 'prenom', 'Pirate')); raise exception 'ÉCHEC : personne avec fiche renommée';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.planning_appel(adm, 'personne_rattacher', jsonb_build_object('source', anna, 'cible', vrai)); raise exception 'ÉCHEC : personne avec fiche rattachée';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role;
  -- Même en contournant les fonctions, le rôle du planning ne peut rien sur une personne avec fiche.
  set local role planning_proprietaire;
  update public.personne set prenom = 'Pirate' where personne_id = anna;
  delete from public.personne where personne_id = anna;
  reset role;
  if (select prenom from public.personne where personne_id = anna) <> 'Anna' then raise exception 'ÉCHEC : la base a laissé passer'; end if;
  -- Référentiel : créer, renommer, archiver (refusé tant qu'il y a des enfants actifs), rétablir.
  set local role service_role;
  r := public.planning_appel(adm, 'ref_enregistrer', jsonb_build_object('type', 'tache', 'atelier_id', at, 'nom', 'Tâche essai'));
  x := (r->>'id')::bigint;
  perform public.planning_appel(adm, 'ref_enregistrer', jsonb_build_object('type', 'tache', 'id', x, 'nom', 'Tâche renommée', 'regroupement_id', null));
  if (select nom from planning.tache where id = x) <> 'Tâche renommée' then raise exception 'ÉCHEC : renommage'; end if;
  begin perform public.planning_appel(adm, 'ref_archiver', jsonb_build_object('type', 'atelier', 'id', at)); raise exception 'ÉCHEC : atelier archivé avec des tâches actives';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  perform public.planning_appel(adm, 'ref_archiver', jsonb_build_object('type', 'tache', 'id', x));
  if (select archive_le from planning.tache where id = x) is null then raise exception 'ÉCHEC : archivage'; end if;
  perform public.planning_appel(adm, 'ref_archiver', jsonb_build_object('type', 'tache', 'id', x, 'archiver', false));
  perform public.planning_appel(adm, 'responsable', jsonb_build_object('atelier_id', at, 'personne_id', vrai));
  perform public.planning_appel(adm, 'habituel', jsonb_build_object('atelier_id', at, 'personne_id', vrai));
  reset role;
  delete from planning.seance; delete from planning.serie_personne; delete from planning.serie; delete from planning.journal; delete from planning.acces_admin;
  delete from planning.atelier_responsable; delete from planning.personne_atelier; delete from planning.tache where id = x;
end $$;
select 'Vérification 18-19 : réussie';

-- 20. Créneaux réalisés d'une personne pour une semaine ; un collaborateur ne lit que les siens.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; anna bigint; chloe bigint; lundi date := date_trunc('week', current_date)::date; r jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'consultation');
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  insert into public.jours (jour_id, collab_id, date_jour, type_jour, c1_debut, c1_fin, c2_debut, c2_fin, c3_debut, c3_fin, total_heures) values
    ('R1', 'T001', lundi, 'travaillée', '08:00', '12:00', '13:30', '17:00', '', '', 7.5),
    ('R2', 'T001', lundi + 1, 'CP', null, null, null, null, null, null, 0);
  set local role service_role;
  r := public.planning_appel(adm, 'realise', jsonb_build_object('personne_id', anna, 'lundi', lundi));
  if jsonb_array_length(r->'jours') <> 2 then raise exception 'ÉCHEC : % jours', jsonb_array_length(r->'jours'); end if;
  if r->'jours'->0->'creneaux' <> '[["08:00","12:00"],["13:30","17:00"]]'::jsonb then raise exception 'ÉCHEC : créneaux %', r->'jours'->0->'creneaux'; end if;
  begin
    perform public.planning_appel(jsonb_build_object('type', 'collab', 'personne_id', anna), 'realise', jsonb_build_object('personne_id', chloe, 'lundi', lundi));
    raise exception 'ÉCHEC : un collaborateur lit les heures d''un autre';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  r := public.planning_appel(jsonb_build_object('type', 'collab', 'personne_id', anna), 'realise', jsonb_build_object('personne_id', anna, 'lundi', lundi));
  reset role;
  delete from public.jours; delete from planning.acces_admin;
end $$;
select 'Vérification 20 : réussie';

-- 21. Accès en lecture (option b) : ses séances + ateliers habituels/responsable + ce que l'admin ouvre.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; chloe bigint; anna bigint; me jsonb; tx bigint; ty bigint; atx bigint; aty bigint;
        lundi date := date_trunc('week', current_date)::date + 7; r jsonb; n int;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select personne_id into chloe from public.collaborateurs where collab_id = 'T004';
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  select t.id, t.atelier_id into tx, atx from planning.tache t order by t.id limit 1;
  select t.id, t.atelier_id into ty, aty from planning.tache t where t.atelier_id <> atx order by t.id limit 1;
  insert into planning.personne_atelier values (chloe, atx);
  me := jsonb_build_object('type', 'collab', 'personne_id', chloe);
  set local role service_role;
  perform public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', tx, 'date', lundi, 'debut', '08:00', 'fin', '09:00', 'personnes', jsonb_build_array(anna)));
  perform public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', ty, 'date', lundi, 'debut', '10:00', 'fin', '11:00', 'personnes', jsonb_build_array(anna)));
  perform public.planning_appel(adm, 'seance_creer', jsonb_build_object('tache_id', ty, 'date', lundi + 1, 'debut', '10:00', 'fin', '11:00', 'personnes', jsonb_build_array(chloe)));
  r := public.planning_appel(me, 'semaine', jsonb_build_object('lundi', lundi));
  n := jsonb_array_length(r->'seances');
  if n <> 2 then raise exception 'ÉCHEC : le collaborateur voit % séances au lieu de 2 (atelier habituel + la sienne)', n; end if;
  if exists (select 1 from jsonb_array_elements(r->'personnes') p where (p->>'id')::bigint <> chloe and jsonb_array_length(p->'fiches') > 0) then
    raise exception 'ÉCHEC : contrat d''un autre visible'; end if;
  if jsonb_array_length(public.planning_appel(me, 'session', '{}')->'referentiel'->'taches') <> (select count(*) from planning.tache where atelier_id = atx and archive_le is null) then
    raise exception 'ÉCHEC : référentiel non réduit'; end if;
  -- L'admin ouvre l'autre atelier : 3 séances.
  perform public.planning_appel(adm, 'acces_regler', jsonb_build_object('personne_id', chloe, 'tout', false, 'elements', jsonb_build_array(jsonb_build_array('atelier', aty))));
  if jsonb_array_length(public.planning_appel(me, 'semaine', jsonb_build_object('lundi', lundi))->'seances') <> 3 then raise exception 'ÉCHEC : élément ouvert non pris en compte'; end if;
  perform public.planning_appel(adm, 'acces_regler', jsonb_build_object('personne_id', chloe, 'tout', true));
  if (public.planning_appel(adm, 'admin_lire', '{}')->'acces_tout') <> jsonb_build_array(chloe) then raise exception 'ÉCHEC : lecture des accès'; end if;
  -- Responsable : ne lit le réalisé que des personnes de ses ateliers.
  insert into planning.atelier_responsable values (atx, chloe);
  perform public.planning_appel(me, 'realise', jsonb_build_object('personne_id', anna, 'lundi', lundi));
  begin
    perform public.planning_appel(jsonb_build_object('type', 'collab', 'personne_id', anna), 'realise', jsonb_build_object('personne_id', chloe, 'lundi', lundi));
    raise exception 'ÉCHEC : réalisé d''un autre lisible';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  r := public.planning_appel(me, 'recap', jsonb_build_object('debut', lundi, 'fin', lundi + 6));
  if exists (select 1 from jsonb_array_elements(r->'personnes') p where (p->>0)::bigint not in (chloe, anna)) then raise exception 'ÉCHEC : récap du responsable trop large'; end if;
  reset role;
  delete from planning.seance; delete from planning.journal; delete from planning.acces_admin; delete from planning.personne_atelier;
  delete from planning.atelier_responsable; delete from planning.acces_personne; delete from planning.acces_element;
end $$;
select 'Vérification 21 : réussie';

-- 22. Liens planning : création, usage, révocation ; mort dès que la fiche est désactivée.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; anna bigint; jeton text; r jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  select personne_id into anna from public.collaborateurs where collab_id = 'T001';
  set local role service_role;
  r := public.planning_appel(adm, 'lien_generer', jsonb_build_object('personne_id', anna));
  jeton := r->>'jeton';
  if length(jeton) <> 64 then raise exception 'ÉCHEC : jeton trop court'; end if;
  if exists (select 1 from planning.lien where empreinte = jeton) then raise exception 'ÉCHEC : jeton stocké en clair'; end if;
  r := public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}');
  if (r->'droits'->>'personne_id')::bigint <> anna then raise exception 'ÉCHEC : identité du lien'; end if;
  if (select dernier_usage from planning.lien where personne_id = anna and revoque_le is null) is null then raise exception 'ÉCHEC : dernier usage'; end if;
  -- Un lien ne donne pas plus qu'un collaborateur : pas d'administration.
  begin perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'admin_lire', '{}'); raise exception 'ÉCHEC : lien admin';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  -- Fiche désactivée : lien mort.
  reset role; update public.collaborateurs set actif = false where collab_id = 'T001'; set local role service_role;
  begin perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}'); raise exception 'ÉCHEC : lien d''une fiche désactivée';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; if sqlerrm <> 'lien_invalide' then raise exception 'ÉCHEC : message %', sqlerrm; end if; end;
  reset role; update public.collaborateurs set actif = true where collab_id = 'T001'; set local role service_role;
  perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}');
  -- Régénérer : l'ancien meurt.
  perform public.planning_appel(adm, 'lien_generer', jsonb_build_object('personne_id', anna));
  begin perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}'); raise exception 'ÉCHEC : ancien lien encore valide';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  if jsonb_array_length(public.planning_appel(adm, 'admin_lire', '{}')->'liens') <> 1 then raise exception 'ÉCHEC : liste des liens'; end if;
  perform public.planning_appel(adm, 'lien_revoquer', jsonb_build_object('personne_id', anna));
  if jsonb_array_length(public.planning_appel(adm, 'admin_lire', '{}')->'liens') <> 0 then raise exception 'ÉCHEC : révocation'; end if;
  reset role;
  delete from planning.lien; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 22 : réussie';

-- 23-24. Administrateurs : niveau réglable, liens planning ; mort si l'admin est désactivé.
do $$
declare adm jsonb := '{"type":"admin","admin_id":"admin_test1"}'; jeton text; r jsonb;
begin
  insert into planning.acces_admin values ('admin_test1', 'complet');
  set local role service_role;
  r := public.planning_appel(adm, 'admin_lire', '{}');
  if jsonb_array_length(r->'admins') <> 2 or (r->'admins') @> '[{"token":"jA1"}]' or r::text like '%jA2%' then raise exception 'ÉCHEC : liste des admins (ou jeton exposé)'; end if;
  jeton := public.planning_appel(adm, 'lien_generer', '{"admin_id":"admin_test2"}')->>'jeton';
  r := public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}');
  if r->'droits'->>'niveau' <> 'consultation' then raise exception 'ÉCHEC : niveau par lien %', r->'droits'->>'niveau'; end if;
  begin perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'ref_enregistrer', '{"type":"activite","nom":"X"}'); raise exception 'ÉCHEC : consultation a écrit';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  perform public.planning_appel(adm, 'admin_niveau', '{"admin_id":"admin_test2","niveau":"complet"}');
  if public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}')->'droits'->>'niveau' <> 'complet' then raise exception 'ÉCHEC : passage en complet'; end if;
  perform public.planning_appel(adm, 'admin_niveau', '{"admin_id":"admin_test2","niveau":"consultation"}');
  begin perform public.planning_appel(adm, 'admin_niveau', '{"admin_id":"admin_test1","niveau":"consultation"}'); raise exception 'ÉCHEC : dernier accès complet retiré';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role; update public.admins set actif = false where admin_id = 'admin_test2'; set local role service_role;
  begin perform public.planning_appel(jsonb_build_object('type', 'lien', 'jeton', jeton), 'session', '{}'); raise exception 'ÉCHEC : lien d''un admin désactivé';
  exception when raise_exception then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  reset role; update public.admins set actif = true where admin_id = 'admin_test2';
  delete from planning.lien; delete from planning.journal; delete from planning.acces_admin;
end $$;
select 'Vérification 23-24 : réussie';

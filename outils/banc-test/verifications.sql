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
  if jsonb_array_length(r->'personnes') < 5 then raise exception 'ÉCHEC : panneau des personnes'; end if;

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

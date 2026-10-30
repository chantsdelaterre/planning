// Mode démonstration (?demo=1) : imite planning-api en mémoire avec des personnes FICTIVES.
// Sert à essayer la page sans toucher la base, et aux tests automatiques de l'interface.
// ?demo=1&profil=responsable|consultation|collaborateur pour voir les autres profils.
(function () {
  const p = new URLSearchParams(location.search);
  if (p.get('demo') !== '1') return;
  const profil = p.get('profil') || 'complet';

  const iso = (d) => d.toISOString().slice(0, 10);
  const ajout = (s, n) => { const d = new Date(s + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
  const lundiDe = (s) => { const d = new Date(s + 'T12:00:00Z'); const j = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() - j); return iso(d); };
  const jourIso = (s) => { const j = new Date(s + 'T12:00:00Z').getUTCDay(); return j === 0 ? 7 : j; };
  const h = (t) => (t.length === 5 ? t + ':00' : t);
  const min = (t) => { const [a, b] = t.split(':'); return +a * 60 + +b; };

  const R = {
    activites: [{ id: 1, nom: 'Commerce' }, { id: 2, nom: 'Production agricole' }, { id: 3, nom: 'Les Halles' }],
    ateliers: [
      { id: 1, nom: 'Paniers', activite_id: 1, societe: 'SAS', couleur: '#B04A78', au_demarrage: true },
      { id: 2, nom: 'Appros-marchés', activite_id: 1, societe: 'SAS', couleur: '#3A6EA5', au_demarrage: true },
      { id: 3, nom: 'Lavage', activite_id: 2, societe: 'SCEA', couleur: '#2E8B8B', au_demarrage: false },
      { id: 4, nom: 'Plein-champ', activite_id: 2, societe: 'SCEA', couleur: '#3F8A5A', au_demarrage: false },
      { id: 5, nom: 'Jardin', activite_id: 2, societe: 'SCEA', couleur: '#7A9A2E', au_demarrage: false },
      { id: 6, nom: 'Support', activite_id: 2, societe: 'SCEA', couleur: '#6E5AA8', au_demarrage: false },
      { id: 7, nom: 'Halles', activite_id: 3, societe: 'SARL', couleur: '#B86E25', au_demarrage: false },
    ],
    regroupements: [
      { id: 1, nom: 'Logistique' }, { id: 2, nom: 'Halles' }, { id: 3, nom: 'St Jo' }, { id: 4, nom: 'Vente ferme' },
      { id: 5, nom: 'Préparation des paniers' }, { id: 6, nom: 'Administration commerciale' },
    ],
    taches: [
      [1, 'Réception, préparation', 2, 1], [2, 'Montage Halles', 2, 2], [3, 'Montage St Jo.', 2, 3], [4, 'Retour St Jo.', 2, 3],
      [5, 'Vente St Jo', 2, 3], [6, 'Commandes, prix etc', 2, 6], [7, 'Montage-vente', 2, 4], [8, 'Préparation des paniers', 1, 5],
      [9, 'Livraisons des paniers', 1, 5], [10, 'Ensachage', 1, 5], [11, 'Commandes, prix etc', 1, 6], [12, 'Récolte', 4, null],
      [13, 'MeC, entretien cultures', 4, null], [14, 'Récolte', 5, null], [15, 'MeC, entretien cultures', 5, null],
    ].map(([id, nom, atelier_id, regroupement_id]) => ({ id, nom, atelier_id, regroupement_id })),
  };

  // Personnes fictives : fiches (société, contrat, heures)
  const P = [
    [1, 'Anna', 'Exemple', [['F01', 'SAS', 'CDI', 35]], [2]],
    [2, 'Bruno', 'Fictif', [['F02', 'SAS', 'TESA', 16], ['F03', 'SARL', 'TESA', 15]], [2]],
    [3, 'Chloé', 'Test', [['F04', 'SCEA', 'CDI', 35]], [6]],
    [4, 'David', 'Modèle', [['F05', 'SAS', 'CDI', 24]], [1]],
    [5, 'Emma', 'Essai', [['F06', 'SAS', 'CDD', 20]], [1]],
    [6, 'Farid', 'Démo', [['F07', 'SAS', 'CDI', 35]], [2]],
    [7, 'Gaëlle', 'Exemple', [['F08', 'SAS', 'TESA', 0]], [1, 2]],
    [8, 'Hugo', 'Fictif', [['F09', 'SCEA', 'CDI', 35]], [4]],
    [9, 'Inès', 'Test', [['F10', 'SAS', 'CDI', 28]], [2]],
    [10, 'Intérim', 'Fictif', [], []],
  ].map(([id, prenom, nom, f, hab]) => ({ id, prenom, nom, externe: f.length === 0,
    fiches: f.map(([collab_id, societe, contrat, heures_hebdo]) => ({ collab_id, societe, contrat, heures_hebdo })), ateliers_habituels: hab }));

  const lundi0 = lundiDe(iso(new Date()));
  let seq = 100;
  const S = []; // séances
  const fermes = [];
  const series = [];
  const responsables = [[1, 4]];  // David Modèle responsable de Paniers
  const accesTout = [], accesElements = [], liens = [], alertes = [];
  // Règles de durée (comme dans la base) : 6 h d'affilée sans coupure de 30 min, 10 h par jour.
  function infractions() {
    const aujourd = iso(new Date()), res = [];
    const mn = (t) => +t.slice(0, 2) * 60 + +t.slice(3, 5);
    const parPJ = {};
    S.filter((s) => s.statut === 'prevue' && s.date_seance >= aujourd).forEach((s) => s.personnes.forEach((x) => {
      (parPJ[x.personne_id + '|' + s.date_seance] = parPJ[x.personne_id + '|' + s.date_seance] || []).push([mn(s.heure_debut), mn(s.heure_fin)]); }));
    for (const [k, l] of Object.entries(parPJ)) {
      l.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
      const blocs = []; let finMax = null;
      for (const [d, f] of l) {
        if (finMax === null || d >= finMax + 30) blocs.push({ deb: d, fin: f, gaps: 0 });
        else { const b = blocs[blocs.length - 1]; if (d > finMax) b.gaps += d - finMax; b.fin = Math.max(b.fin, f); }
        finMax = finMax === null ? f : Math.max(finMax, f);
      }
      const [pid, date] = k.split('|'); let tot = 0;
      const hh = (x) => { const m = Math.round(x * 60); return Math.floor(m / 60) + ' h' + (m % 60 ? ' ' + String(m % 60).padStart(2, '0') : ''); };
      const hm = (m) => String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');
      for (const b of blocs) { const h = (b.fin - b.deb - b.gaps) / 60; tot += h;
        if (h > 6) res.push({ personne_id: +pid, date, regle: 'pause', detail: 'Pause obligatoire au bout de 6 h : ' + hh(h) + ' d\'affilée (' + hm(b.deb) + '–' + hm(b.fin) + ')' }); }
      if (tot > 10) res.push({ personne_id: +pid, date, regle: 'max_jour', detail: 'Plus de 10 h dans la journée : ' + hh(tot) });
    }
    return res;
  }
  const admins = [{ admin_id: 'a1', nom: 'Admin Un (fictif)', niveau: 'complet' }, { admin_id: 'a2', nom: 'Admin Deux (fictif)', niveau: 'complet' }, { admin_id: 'a3', nom: 'Admin Trois (fictif)', niveau: 'consultation' }];
  // Tâches visibles (null = toutes), comme dans la base.
  function tachesVisibles() {
    if (['complet', 'consultation'].includes(droits.niveau)) return null;
    const pid = droits.personne_id; if (accesTout.includes(pid)) return null;
    const ats = new Set(pers(pid).ateliers_habituels.concat(responsables.filter((r) => r[1] === pid).map((r) => r[0])));
    const el = accesElements.filter((e) => e[0] === pid);
    return R.taches.filter((t) => ats.has(t.atelier_id) || el.some(([, ty, id]) => (ty === 'tache' && id === t.id) || (ty === 'atelier' && id === t.atelier_id)
      || (ty === 'regroupement' && id === t.regroupement_id) || (ty === 'activite' && id === atelier(t.atelier_id).activite_id))).map((t) => t.id);
  }

  const tache = (id) => R.taches.find((t) => t.id === id);
  const atelier = (id) => R.ateliers.find((a) => a.id === id);
  const pers = (id) => P.find((x) => x.id === id);

  function fiche(pid, societe) {
    const x = pers(pid);
    if (x.externe) return { collab_id: null, mad: false };
    const f = x.fiches.find((y) => y.societe === societe);
    return f ? { collab_id: f.collab_id, mad: false } : { collab_id: x.fiches[0].collab_id, mad: true };
  }
  function ferme(date, soc) { return fermes.some((f) => f.date === date && (!f.societe || f.societe === soc)); }
  function nouvelleSeance(o) {
    const at = atelier(tache(o.tache_id).atelier_id);
    const ids = o.personnes || [];
    const s = Object.assign({ id: ++seq, serie_id: null, date_serie: null, titre: null, lieu: null, statut: 'prevue', motif: null, modifiee: false }, o, { personnes: [] });
    s.societe = at.societe;
    if (ferme(s.date_seance, s.societe)) { s.statut = 'suspendue'; s.motif = 'Jour fermé'; }
    ids.forEach((pid) => affecter(s, pid));
    S.push(s);
    return s;
  }
  function affecter(s, pid) {
    if (s.personnes.some((x) => x.personne_id === pid)) return;
    const f = fiche(pid, s.societe);
    const x = pers(pid);
    s.personnes = s.personnes.concat([{ personne_id: pid, prenom: x.prenom, nom: x.nom, collab_id: f.collab_id, mad: f.mad }]);
  }
  function genererSerie(se, depuis, jusqua) {
    for (let d = depuis; d <= jusqua; d = ajout(d, 1)) {
      if (d < se.date_debut || (se.date_fin && d > se.date_fin)) continue;
      if (!se.jours.includes(jourIso(d))) continue;
      if (Math.round((new Date(lundiDe(d)) - new Date(lundiDe(se.date_debut))) / (7 * 864e5)) % (se.intervalle || 1)) continue;
      if (S.some((s) => s.serie_id === se.id && s.date_serie === d)) continue;
      nouvelleSeance({ tache_id: se.tache_id, serie_id: se.id, date_serie: d, date_seance: d, heure_debut: se.debut, heure_fin: se.fin, titre: se.titre, personnes: se.personnes });
    }
  }
  function creerSerie(o) {
    const se = { id: ++seq, tache_id: o.tache_id, jours: o.jours, intervalle: +o.intervalle || 1, debut: h(o.debut), fin: h(o.fin), date_debut: o.date_debut, date_fin: o.date_fin || null, titre: o.titre || null, personnes: o.personnes || [] };
    series.push(se);
    genererSerie(se, o.date_debut, ajout(lundi0, 7 * 9));
    return se;
  }

  // Une semaine type, fictive
  creerSerie({ tache_id: 1, jours: [1, 3, 5], debut: '06:00', fin: '08:30', date_debut: ajout(lundi0, -14), personnes: [1, 6] });
  creerSerie({ tache_id: 10, jours: [2, 3], debut: '09:00', fin: '12:00', date_debut: ajout(lundi0, -14), personnes: [4, 5, 7] });
  creerSerie({ tache_id: 8, jours: [2, 4], debut: '13:30', fin: '17:00', date_debut: ajout(lundi0, -14), personnes: [4, 5] });
  creerSerie({ tache_id: 9, jours: [4], debut: '17:00', fin: '19:00', date_debut: ajout(lundi0, -14), personnes: [5] });
  creerSerie({ tache_id: 3, jours: [6], debut: '06:00', fin: '07:30', date_debut: ajout(lundi0, -14), personnes: [6, 9, 2] });
  creerSerie({ tache_id: 5, jours: [6], debut: '07:30', fin: '12:30', date_debut: ajout(lundi0, -14), personnes: [6, 9, 2] });
  creerSerie({ tache_id: 4, jours: [6], debut: '12:30', fin: '13:30', date_debut: ajout(lundi0, -14), personnes: [6, 9] });
  creerSerie({ tache_id: 6, jours: [1, 4], debut: '14:00', fin: '16:00', date_debut: ajout(lundi0, -14), personnes: [1] });
  creerSerie({ tache_id: 2, jours: [5], debut: '07:00', fin: '09:00', date_debut: ajout(lundi0, -14), personnes: [3, 7] });
  // Un chevauchement (Anna) et une séance ponctuelle
  nouvelleSeance({ tache_id: 7, date_seance: ajout(lundi0, 0), heure_debut: '08:00:00', heure_fin: '10:00:00', personnes: [1] });

  function vue(s, d0, d6) {
    const t = tache(s.tache_id); const at = atelier(t.atelier_id); const rg = R.regroupements.find((r) => r.id === t.regroupement_id);
    const duree = (min(s.heure_fin) - min(s.heure_debut)) / 60;
    const chev = s.statut === 'prevue' ? s.personnes.filter((x) => S.some((o) => o.id !== s.id && o.statut === 'prevue' && o.date_seance === s.date_seance
      && o.personnes.some((y) => y.personne_id === x.personne_id) && min(o.heure_debut) < min(s.heure_fin) && min(s.heure_debut) < min(o.heure_fin))).map((x) => x.personne_id) : [];
    return {
      id: s.id, date_seance: s.date_seance, heure_debut: s.heure_debut, heure_fin: s.heure_fin, duree_h: duree, statut: s.statut, motif: s.motif,
      modifiee: s.modifiee, serie_id: s.serie_id, date_serie: s.date_serie, deplacee: !!(s.serie_id && s.date_serie !== s.date_seance),
      titre: s.titre || t.nom, complement: s.titre || null, lieu: s.lieu, societe: s.societe, tache_id: t.id, tache: t.nom, regroupement_id: t.regroupement_id, regroupement: rg ? rg.nom : null,
      atelier_id: at.id, atelier: at.nom, couleur: at.couleur, activite_id: at.activite_id, activite: R.activites.find((a) => a.id === at.activite_id).nom,
      nb_personnes: s.personnes.length, main_oeuvre_h: s.statut === 'prevue' ? duree * s.personnes.length : 0,
      trace: !(s.date_seance >= d0 && s.date_seance <= d6), personnes: s.personnes, chevauchements: chev,
      serie_jours: s.serie_id ? series.find((x) => x.id === s.serie_id).jours : null, serie_fin: s.serie_id ? series.find((x) => x.id === s.serie_id).date_fin : null, serie_intervalle: s.serie_id ? series.find((x) => x.id === s.serie_id).intervalle : null,
    };
  }

  const droits = {
    complet: { niveau: 'complet', personne_id: null, ateliers: R.ateliers.map((a) => a.id), referentiel: true },
    consultation: { niveau: 'consultation', personne_id: null, ateliers: [], referentiel: false },
    responsable: { niveau: 'responsable', personne_id: 4, ateliers: [1], referentiel: false },
    collaborateur: { niveau: 'collaborateur', personne_id: 5, ateliers: [], referentiel: false },
  }[profil];

  function exiger(atelierId) {
    if (droits.niveau === 'consultation' || droits.niveau === 'collaborateur') throw new Error('Accès en consultation : modification impossible');
    if (!droits.ateliers.includes(atelierId)) throw new Error('Vous ne pouvez pas modifier cet atelier');
  }
  const atelierDe = (s) => tache(s.tache_id).atelier_id;
  const seance = (id) => { const s = S.find((x) => x.id === +id); if (!s) throw new Error('Séance introuvable'); return s; };

  const actions = {
    alertes_lire: () => ({ alertes: alertes.slice() }),
    alertes_vues: () => { alertes.forEach((a) => { a.vue = true; }); return {}; },
    session: () => {
      const v = tachesVisibles();
      const taches = R.taches.filter((a) => !a.archive && (!v || v.includes(a.id)));
      const ateliers = R.ateliers.filter((a) => !a.archive && taches.some((t) => t.atelier_id === a.id));
      return { alertes_non_vues: alertes.filter((a) => !a.vue).length, droits, referentiel: { taches, ateliers, activites: R.activites.filter((a) => !a.archive && ateliers.some((x) => x.activite_id === a.id)),
        regroupements: R.regroupements.filter((a) => !a.archive && taches.some((t) => t.regroupement_id === a.id)) } };
    },
    semaine: (q) => {
      const d0 = q.lundi || lundi0; const d6 = ajout(d0, 6);
      const v = tachesVisibles(), moi = droits.personne_id;
      const liste = S.filter((s) => (s.date_seance >= d0 && s.date_seance <= d6) || (s.serie_id && s.date_serie !== s.date_seance && s.date_serie >= d0 && s.date_serie <= d6))
        .filter((s) => !v || v.includes(s.tache_id) || s.personnes.some((x) => x.personne_id === moi))
        .map((s) => vue(s, d0, d6)).sort((a, b) => (a.date_seance + a.heure_debut).localeCompare(b.date_seance + b.heure_debut));
      const prevu = {};
      liste.filter((v) => !v.trace && v.statut === 'prevue').forEach((v) => v.personnes.forEach((x) => { prevu[x.personne_id] = (prevu[x.personne_id] || 0) + v.duree_h; }));
      return {
        lundi: d0, seances: liste,
        jours_fermes: fermes.filter((f) => f.date >= d0 && f.date <= d6),
        indisponibilites: [], chevauchements: [],
        personnes: P.filter((x) => !x.archive).map((x) => Object.assign({}, x, { prevu_h: prevu[x.id] || 0, nature: x.externe ? x.nature || 'externe' : null }))
          .filter((x) => droits.niveau !== 'collaborateur' || x.id === moi || liste.some((s) => s.personnes.some((y) => y.personne_id === x.id)))
          .map((x) => droits.niveau !== 'collaborateur' || x.id === moi ? x : Object.assign({}, x, { fiches: [], prevu_h: 0, ateliers_habituels: [] })),
      };
    },
    seance_creer: (q) => { exiger(tache(+q.tache_id).atelier_id); const s = nouvelleSeance({ tache_id: +q.tache_id, date_seance: q.date, heure_debut: h(q.debut), heure_fin: h(q.fin), titre: q.titre || null, lieu: q.lieu || null, personnes: (q.personnes || []).map(Number) }); return { seance_id: s.id }; },
    serie_creer: (q) => { exiger(tache(+q.tache_id).atelier_id); const se = creerSerie({ tache_id: +q.tache_id, jours: q.jours.map(Number), debut: q.debut, fin: q.fin, date_debut: q.date_debut, date_fin: q.date_fin, intervalle: q.intervalle, titre: q.titre, personnes: (q.personnes || []).map(Number) }); return { serie_id: se.id }; },
    seance_modifier: (q) => {
      const s = seance(q.seance_id); exiger(atelierDe(s));
      if (q.tache_id && +q.tache_id !== s.tache_id) exiger(tache(+q.tache_id).atelier_id);
      if (!s.serie_id && q.jours) {
        const n = creerSerie({ tache_id: +q.tache_id || s.tache_id, jours: q.jours.map(Number), debut: (q.debut || s.heure_debut).slice(0, 5), fin: (q.fin || s.heure_fin).slice(0, 5), date_debut: q.date || s.date_seance, date_fin: q.date_fin_serie || null, intervalle: q.intervalle,
          titre: 'titre' in q ? q.titre || null : s.titre, personnes: q.personnes ? q.personnes.map(Number) : s.personnes.map((x) => x.personne_id) });
        S.splice(S.indexOf(s), 1); return { serie_id: n.id };
      }
      if (s.serie_id && (q.jours || 'date_fin_serie' in q || q.intervalle)) q.portee = 'suivantes';
      if (q.portee === 'suivantes' && s.serie_id) {
        const se = series.find((x) => x.id === s.serie_id); const dec = Math.round((new Date(q.date || s.date_seance) - new Date(s.date_serie)) / 864e5);
        const finAvant = se.date_fin;
        se.date_fin = ajout(s.date_serie, -1);
        for (let i = S.length - 1; i >= 0; i--) if (S[i].serie_id === se.id && S[i].date_serie >= s.date_serie && (!S[i].modifiee || S[i].id === s.id)) S.splice(i, 1);
        const n = creerSerie({ tache_id: +q.tache_id || se.tache_id, date_fin: 'date_fin_serie' in q ? q.date_fin_serie || null : finAvant, intervalle: q.intervalle || se.intervalle, jours: q.jours ? q.jours.map(Number) : se.jours.map((j) => ((j - 1 + dec) % 7 + 7) % 7 + 1), debut: (q.debut || s.heure_debut).slice(0, 5), fin: (q.fin || s.heure_fin).slice(0, 5), date_debut: ajout(s.date_serie, dec), titre: 'titre' in q ? q.titre || null : se.titre, personnes: q.personnes ? q.personnes.map(Number) : se.personnes });
        return { serie_id: n.id };
      }
      if (q.date) s.date_seance = q.date; if (q.debut) s.heure_debut = h(q.debut); if (q.fin) s.heure_fin = h(q.fin);
      if (q.tache_id) { s.tache_id = +q.tache_id; s.societe = atelier(tache(s.tache_id).atelier_id).societe;
        s.personnes = s.personnes.map((x) => { const f = fiche(x.personne_id, s.societe); return Object.assign({}, x, { collab_id: f.collab_id, mad: f.mad }); }); }
      if (q.personnes) { const garde = q.personnes.map(Number); s.personnes = s.personnes.filter((x) => garde.includes(x.personne_id)); garde.forEach((pid) => affecter(s, pid)); }
      if ('titre' in q) s.titre = q.titre || null; if ('lieu' in q) s.lieu = q.lieu || null;
      s.modifiee = true; return { seance_id: s.id };
    },
    // Récapitulatifs : le réalisé fictif reprend le prévu avec de petits écarts, et quelques CP.
    recap: (q) => {
      const moi = droits.niveau === 'collaborateur' ? droits.personne_id : null;
      const ok = (pid) => moi === null || pid === moi;
      const dans = (d) => d >= q.debut && d <= q.fin;
      const prevu = {}, mo = {};
      S.filter((x) => x.statut === 'prevue' && dans(x.date_seance)).forEach((x) => {
        const v = vue(x, x.date_seance, x.date_seance);
        x.personnes.filter((y) => ok(y.personne_id)).forEach((y) => { const k = y.personne_id + '|' + x.date_seance + '|' + v.atelier_id; prevu[k] = prevu[k] || [y.personne_id, x.date_seance, v.atelier_id, 0, y.mad]; prevu[k][3] += v.duree_h; });
        const k = x.date_seance + '|' + x.tache_id; mo[k] = mo[k] || [x.date_seance, x.tache_id, 0, 0]; mo[k][2] += v.main_oeuvre_h; mo[k][3]++;
      });
      const parJour = {};
      Object.values(prevu).forEach(([pid, d, , hh]) => { parJour[pid + '|' + d] = (parJour[pid + '|' + d] || 0) + hh; });
      const aujourdhui = iso(new Date());
      const realise = [];
      Object.entries(parJour).forEach(([k, hh]) => {
        const [pid, d] = k.split('|'); if (d >= aujourdhui || pers(+pid).externe) return;
        const graine = (+pid * 7 + +d.slice(8)) % 11;
        if (graine === 0) realise.push([+pid, d, 'CP', 0]);
        else realise.push([+pid, d, 'T', Math.max(0, hh + [0, 0.25, -0.5, 0.5, 0, 1, -0.25, 0, 0.75, 0][graine - 1])]);
      });
      const gens = P.filter((x) => ok(x.id) && (!x.externe || Object.values(prevu).some((v) => v[0] === x.id)));
      return {
        debut: q.debut, fin: q.fin, prevu: Object.values(prevu), realise, mo: moi === null ? Object.values(mo) : [],
        contrats: gens.flatMap((x) => x.fiches.map((f) => [x.id, f.collab_id, f.societe, f.contrat, f.heures_hebdo || null, '2025-01-01', null])),
        personnes: gens.map((x) => [x.id, x.prenom, x.nom, x.externe]),
      };
    },
    // Administration
    admin_lire: () => {
      if (!['complet', 'consultation'].includes(droits.niveau)) throw new Error('Réservé aux administrateurs');
      const sa = (t) => (t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
      return {
        activites: R.activites.map((a) => Object.assign({ ordre: 0, archive: !!a.archive }, a)),
        ateliers: R.ateliers.map((a) => Object.assign({ ordre: 0, archive: !!a.archive }, a)),
        regroupements: R.regroupements.map((a) => Object.assign({ ordre: 0, archive: !!a.archive }, a)),
        taches: R.taches.map((t) => Object.assign({ ordre: 0, archive: !!t.archive, seances: S.filter((x) => x.tache_id === t.id).length }, t)),
        societes: [{ code: 'SAS', nom: 'SAS (fictive)' }, { code: 'SARL', nom: 'SARL (fictive)' }, { code: 'SCEA', nom: 'SCEA (fictive)' }],
        admins: admins.map((a) => Object.assign({}, a)), liens: liens.slice(), acces_tout: accesTout.slice(), acces_elements: accesElements.slice(), responsables: responsables.slice(), habituels: P.flatMap((x) => x.ateliers_habituels.map((a) => [x.id, a])),
        personnes: P.map((x) => ({ id: x.id, prenom: x.prenom, nom: x.nom, sans_fiche: x.externe, active: !x.externe, societes: x.fiches.map((f) => f.societe),
          nature: x.externe ? x.nature || 'externe' : null, archive: !!x.archive, seances: S.filter((s) => s.personnes.some((y) => y.personne_id === x.id)).length,
          suggestions: x.externe ? P.filter((y) => !y.externe && y.id !== x.id && ((sa(x.nom) && sa(y.nom) === sa(x.nom)) || sa(y.prenom) === sa(x.prenom))).map((y) => y.id) : null })),
      };
    },
    personne_creer: (q) => {
      if (!['complet', 'responsable'].includes(droits.niveau)) throw new Error('Réservé aux responsables et aux accès complets');
      if (!(q.prenom || '').trim()) throw new Error('Le prénom est obligatoire');
      const x = { id: ++seq, prenom: q.prenom.trim(), nom: (q.nom || '').trim(), externe: true, nature: q.nature || 'a_venir', fiches: [], ateliers_habituels: [] };
      P.push(x); return { personne_id: x.id };
    },
    personne_modifier: (q) => { const x = pers(+q.personne_id); if (!x.externe) throw new Error('Seule une personne sans fiche se modifie ici');
      if ('prenom' in q) x.prenom = q.prenom.trim(); if ('nom' in q) x.nom = (q.nom || '').trim(); if (q.nature) x.nature = q.nature; return {}; },
    personne_archiver: (q) => { const x = pers(+q.personne_id); x.archive = q.archiver !== false; return {}; },
    personne_rattacher: (q) => {
      const src = pers(+q.source), dst = pers(+q.cible);
      if (!src.externe) throw new Error('La personne à rattacher doit être sans fiche');
      if (!dst || dst.externe) throw new Error('Choisis une personne qui a une fiche dans Suivi des temps');
      let n = 0;
      S.forEach((s) => { const i = s.personnes.findIndex((y) => y.personne_id === src.id); if (i < 0) return; n++;
        s.personnes.splice(i, 1); affecter(s, dst.id); });
      series.forEach((se) => { if (se.personnes.includes(src.id)) se.personnes = [...new Set(se.personnes.map((p) => p === src.id ? dst.id : p))]; });
      P.splice(P.indexOf(src), 1); return { personne_id: dst.id, seances: n };
    },
    ref_enregistrer: (q) => {
      if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      const liste = { activite: R.activites, atelier: R.ateliers, regroupement: R.regroupements, tache: R.taches }[q.type];
      if ('nom' in q && !(q.nom || '').trim()) throw new Error('Le nom est obligatoire');
      let x = q.id ? liste.find((y) => y.id === +q.id) : null;
      if (!x) { x = { id: ++seq, couleur: '#6B7280', societe: 'SAS', au_demarrage: false, regroupement_id: null }; liste.push(x); }
      for (const k of ['nom', 'activite_id', 'societe', 'couleur', 'au_demarrage', 'atelier_id', 'regroupement_id', 'ordre']) if (k in q) x[k] = q[k] === '' ? null : q[k];
      if (x.nom) x.nom = x.nom.trim(); return { id: x.id };
    },
    ref_archiver: (q) => {
      if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      const liste = { activite: R.activites, atelier: R.ateliers, regroupement: R.regroupements, tache: R.taches }[q.type];
      const x = liste.find((y) => y.id === +q.id); const arch = q.archiver !== false;
      if (arch && q.type === 'atelier' && R.taches.some((t) => t.atelier_id === x.id && !t.archive)) throw new Error('Archive d\'abord les tâches de cet atelier');
      if (arch && q.type === 'activite' && R.ateliers.some((a) => a.activite_id === x.id && !a.archive)) throw new Error('Archive d\'abord les ateliers de cette activité');
      x.archive = arch; return { id: x.id };
    },
    responsable: (q) => { if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      const k = responsables.findIndex((r) => r[0] === +q.atelier_id && r[1] === +q.personne_id);
      if (q.ajouter === false) { if (k >= 0) responsables.splice(k, 1); } else if (k < 0) responsables.push([+q.atelier_id, +q.personne_id]); return {}; },
    lien_generer: (q) => { if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      const pid = q.admin_id ? null : +q.personne_id, aid = q.admin_id || null;
      for (let k = liens.length - 1; k >= 0; k--) if (aid ? liens[k].admin_id === aid : liens[k].personne_id === pid) liens.splice(k, 1);
      liens.push({ personne_id: pid, admin_id: aid, cree_le: new Date().toISOString(), dernier_usage: null, valide: true });
      return { personne_id: pid, jeton: Array.from({ length: 64 }, () => '0123456789abcdef'[Math.floor(Math.random() * 16)]).join('') }; },
    lien_revoquer: (q) => { for (let k = liens.length - 1; k >= 0; k--) if (q.admin_id ? liens[k].admin_id === q.admin_id : liens[k].personne_id === +q.personne_id) liens.splice(k, 1); return {}; },
    admin_niveau: (q) => { if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      if (q.niveau === 'consultation' && !admins.some((a) => a.niveau === 'complet' && a.admin_id !== q.admin_id)) throw new Error('Il faut garder au moins un accès complet');
      admins.find((a) => a.admin_id === q.admin_id).niveau = q.niveau; return {}; },
    acces_regler: (q) => { if (droits.niveau !== 'complet') throw new Error('Réservé aux accès complets');
      const pid = +q.personne_id; const i = accesTout.indexOf(pid); if (q.tout && i < 0) accesTout.push(pid); if (!q.tout && i >= 0) accesTout.splice(i, 1);
      if (q.elements) { for (let k = accesElements.length - 1; k >= 0; k--) if (accesElements[k][0] === pid) accesElements.splice(k, 1); q.elements.forEach(([t, id]) => accesElements.push([pid, t, +id])); }
      return {}; },
    habituel: (q) => { exiger(+q.atelier_id); const x = pers(+q.personne_id);
      x.ateliers_habituels = q.ajouter === false ? x.ateliers_habituels.filter((a) => a !== +q.atelier_id) : [...new Set(x.ateliers_habituels.concat(+q.atelier_id))]; return {}; },
    // Créneaux réalisés fictifs : les séances passées, avec quelques minutes d'écart, et des CP.
    realise: (q) => {
      const pid = +q.personne_id;
      if (droits.niveau === 'collaborateur' && pid !== droits.personne_id) throw new Error('Tu ne peux voir que tes propres heures');
      const x = pers(pid); if (!x || x.externe) return { personne_id: pid, lundi: q.lundi, jours: [] };
      const auj = iso(new Date()), jours = [];
      const mn = (t) => +t.slice(0, 2) * 60 + +t.slice(3, 5), hm = (m) => String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');
      for (let i = 0; i < 7; i++) {
        const d = ajout(q.lundi, i); if (d >= auj) break;
        const se = S.filter((y) => y.date_seance === d && y.statut === 'prevue' && y.personnes.some((z) => z.personne_id === pid)).sort((a, b) => a.heure_debut.localeCompare(b.heure_debut));
        if (!se.length) continue;
        const graine = (pid * 7 + +d.slice(8)) % 11;
        if (graine === 0) { jours.push({ date: d, collab_id: x.fiches[0].collab_id, type: 'CP', heures: 0, creneaux: [] }); continue; }
        const cr = [];
        se.forEach((y, k) => { const a = mn(y.heure_debut) + [0, 5, -10, 15, 0][(graine + k) % 5], b = mn(y.heure_fin) + [10, 0, -15, 20, -5][(graine + k) % 5];
          if (cr.length && a <= cr[cr.length - 1][1] + 5) cr[cr.length - 1][1] = Math.max(cr[cr.length - 1][1], b); else cr.push([a, b]); });
        const garde = cr.slice(0, 3);
        jours.push({ date: d, collab_id: x.fiches[0].collab_id, type: 'travaillée', heures: garde.reduce((t, c) => t + (c[1] - c[0]) / 60, 0), creneaux: garde.map((c) => [hm(c[0]), hm(c[1])]) });
      }
      return { personne_id: pid, lundi: q.lundi, jours };
    },
    seance_supprimer: (q) => { const s = seance(q.seance_id); exiger(atelierDe(s)); S.splice(S.indexOf(s), 1); return { seance_id: s.id }; },
    serie_arreter: (q) => { const se = series.find((x) => x.id === +q.serie_id); exiger(tache(se.tache_id).atelier_id); se.date_fin = q.date_fin;
      for (let i = S.length - 1; i >= 0; i--) if (S[i].serie_id === se.id && S[i].date_seance > q.date_fin) S.splice(i, 1); return {}; },
    affecter: (q) => { const s = seance(q.seance_id); exiger(atelierDe(s)); affecter(s, +q.personne_id); s.modifiee = !!s.serie_id || s.modifiee; return { chevauchements: [] }; },
    retirer: (q) => { const s = seance(q.seance_id); exiger(atelierDe(s)); s.personnes = s.personnes.filter((x) => x.personne_id !== +q.personne_id); return { chevauchements: [] }; },
    suspendre: (q) => { const s = seance(q.seance_id); exiger(atelierDe(s)); s.statut = 'suspendue'; s.motif = q.motif || null; s.modifiee = true; return {}; },
    reprendre: (q) => { const s = seance(q.seance_id); exiger(atelierDe(s)); s.statut = 'prevue'; s.motif = null; s.modifiee = true; return {}; },
    jour_fermer: (q) => {
      if (droits.niveau !== 'complet') throw new Error('Seuls les accès complets peuvent fermer une journée');
      fermes.push({ date: q.date, societe: q.societe || null, motif: q.motif || null });
      let n = 0; S.forEach((s) => { if (s.date_seance === q.date && s.statut === 'prevue' && (!q.societe || s.societe === q.societe)) { s.statut = 'suspendue'; s.motif = q.motif || 'Jour fermé'; n++; } });
      return { seances_suspendues: n };
    },
  };

  window.PlanningAPI = {
    aUnJeton: () => true,
    demo: true,
    appeler: async (action, params) => {
      await new Promise((r) => setTimeout(r, 60));
      if (!actions[action]) throw new Error('Action inconnue');
      const q = params || {};
      const ecrit = !['session', 'semaine', 'recap', 'realise', 'admin_lire', 'alertes_lire'].includes(action);
      const cle = (x) => x.personne_id + '|' + x.date + '|' + x.regle;
      const avant = ecrit ? new Set(infractions().map(cle)) : null;
      const sauveS = ecrit ? JSON.parse(JSON.stringify(S)) : null, sauveSeries = ecrit ? JSON.parse(JSON.stringify(series)) : null;
      const r = actions[action](q);
      if (ecrit) {
        const nouv = infractions().filter((x) => !avant.has(cle(x))).map((x) => Object.assign({ nom: pers(x.personne_id).prenom + ' ' + pers(x.personne_id).nom }, x));
        if (nouv.length && !q.forcer) { S.splice(0, S.length, ...sauveS); series.splice(0, series.length, ...sauveSeries); throw new Error('REGLES|' + JSON.stringify(nouv)); }
        nouv.forEach((x) => alertes.unshift({ id: ++seq, quand: new Date().toISOString(), qui_nom: 'Démo', action, motif: q.motif || null, personne: x.nom, date: x.date, regle: x.regle, detail: x.detail, vue: false }));
      }
      return Object.assign({ ok: true }, JSON.parse(JSON.stringify(r)));
    },
  };
})();

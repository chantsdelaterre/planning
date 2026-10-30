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
      if (S.some((s) => s.serie_id === se.id && s.date_serie === d)) continue;
      nouvelleSeance({ tache_id: se.tache_id, serie_id: se.id, date_serie: d, date_seance: d, heure_debut: se.debut, heure_fin: se.fin, titre: se.titre, personnes: se.personnes });
    }
  }
  function creerSerie(o) {
    const se = { id: ++seq, tache_id: o.tache_id, jours: o.jours, debut: h(o.debut), fin: h(o.fin), date_debut: o.date_debut, date_fin: o.date_fin || null, titre: o.titre || null, personnes: o.personnes || [] };
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
    session: () => ({ droits, referentiel: R }),
    semaine: (q) => {
      const d0 = q.lundi || lundi0; const d6 = ajout(d0, 6);
      const liste = S.filter((s) => (s.date_seance >= d0 && s.date_seance <= d6) || (s.serie_id && s.date_serie !== s.date_seance && s.date_serie >= d0 && s.date_serie <= d6))
        .map((s) => vue(s, d0, d6)).sort((a, b) => (a.date_seance + a.heure_debut).localeCompare(b.date_seance + b.heure_debut));
      const prevu = {};
      liste.filter((v) => !v.trace && v.statut === 'prevue').forEach((v) => v.personnes.forEach((x) => { prevu[x.personne_id] = (prevu[x.personne_id] || 0) + v.duree_h; }));
      return {
        lundi: d0, seances: liste,
        jours_fermes: fermes.filter((f) => f.date >= d0 && f.date <= d6),
        indisponibilites: [], chevauchements: [],
        personnes: P.map((x) => Object.assign({}, x, { prevu_h: prevu[x.id] || 0 })),
      };
    },
    seance_creer: (q) => { exiger(tache(+q.tache_id).atelier_id); const s = nouvelleSeance({ tache_id: +q.tache_id, date_seance: q.date, heure_debut: h(q.debut), heure_fin: h(q.fin), titre: q.titre || null, lieu: q.lieu || null, personnes: (q.personnes || []).map(Number) }); return { seance_id: s.id }; },
    serie_creer: (q) => { exiger(tache(+q.tache_id).atelier_id); const se = creerSerie({ tache_id: +q.tache_id, jours: q.jours.map(Number), debut: q.debut, fin: q.fin, date_debut: q.date_debut, date_fin: q.date_fin, titre: q.titre, personnes: (q.personnes || []).map(Number) }); return { serie_id: se.id }; },
    seance_modifier: (q) => {
      const s = seance(q.seance_id); exiger(atelierDe(s));
      if (q.tache_id && +q.tache_id !== s.tache_id) exiger(tache(+q.tache_id).atelier_id);
      if (q.portee === 'suivantes' && s.serie_id) {
        const se = series.find((x) => x.id === s.serie_id); const dec = Math.round((new Date(q.date || s.date_seance) - new Date(s.date_serie)) / 864e5);
        se.date_fin = ajout(s.date_serie, -1);
        for (let i = S.length - 1; i >= 0; i--) if (S[i].serie_id === se.id && S[i].date_serie >= s.date_serie && (!S[i].modifiee || S[i].id === s.id)) S.splice(i, 1);
        const n = creerSerie({ tache_id: +q.tache_id || se.tache_id, jours: se.jours.map((j) => ((j - 1 + dec) % 7 + 7) % 7 + 1), debut: (q.debut || s.heure_debut).slice(0, 5), fin: (q.fin || s.heure_fin).slice(0, 5), date_debut: ajout(s.date_serie, dec), titre: se.titre, personnes: se.personnes });
        return { serie_id: n.id };
      }
      if (q.date) s.date_seance = q.date; if (q.debut) s.heure_debut = h(q.debut); if (q.fin) s.heure_fin = h(q.fin);
      if (q.tache_id) { s.tache_id = +q.tache_id; s.societe = atelier(tache(s.tache_id).atelier_id).societe;
        s.personnes = s.personnes.map((x) => { const f = fiche(x.personne_id, s.societe); return Object.assign({}, x, { collab_id: f.collab_id, mad: f.mad }); }); }
      if ('titre' in q) s.titre = q.titre || null; if ('lieu' in q) s.lieu = q.lieu || null;
      s.modifiee = true; return { seance_id: s.id };
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
      return Object.assign({ ok: true }, JSON.parse(JSON.stringify(actions[action](params || {}))));
    },
  };
})();

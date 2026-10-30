// Planning général — Chants de la Terre.
// Une seule source : l'API (planning-api, ou le mode démonstration). Rien n'est calculé ici
// qui ne soit d'abord vérifié côté serveur : la page affiche, l'API décide.
(function () {
  'use strict';
  const API = window.PlanningAPI;
  const $ = (s, r) => (r || document).querySelector(s);
  const el = (tag, attrs, ...enfants) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') n.className = v;
      else if (k === 'style') n.style.cssText = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else if (k === 'text') n.textContent = v;
      else n.setAttribute(k, v === true ? '' : v);
    }
    for (const e of enfants.flat()) if (e != null && e !== false) n.append(e.nodeType ? e : document.createTextNode(e));
    return n;
  };

  // Dates en chaînes AAAA-MM-JJ, calculées à midi UTC : aucun piège de fuseau ni d'heure d'été.
  const D = {
    iso: (d) => d.toISOString().slice(0, 10),
    ajout: (s, n) => { const d = new Date(s + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return D.iso(d); },
    lundiDe: (s) => { const d = new Date(s + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - (d.getUTCDay() + 6) % 7); return D.iso(d); },
    jourIso: (s) => { const j = new Date(s + 'T12:00:00Z').getUTCDay(); return j === 0 ? 7 : j; },
    numSemaine: (s) => { const d = new Date(s + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7)); const a = new Date(Date.UTC(d.getUTCFullYear(), 0, 1)); return Math.ceil(((d - a) / 864e5 + 1) / 7); },
    court: (s) => new Date(s + 'T12:00:00Z').toLocaleDateString('fr-FR', { day: 'numeric', month: 'short', timeZone: 'UTC' }),
    long: (s) => new Date(s + 'T12:00:00Z').toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }),
    aujourdhui: () => { const n = new Date(); return D.iso(new Date(Date.UTC(n.getFullYear(), n.getMonth(), n.getDate(), 12))); },
  };
  const JOURS = ['Lun.', 'Mar.', 'Mer.', 'Jeu.', 'Ven.', 'Sam.', 'Dim.'];
  const min = (t) => { const [a, b] = t.split(':'); return +a * 60 + +b; };
  const hhmm = (m) => String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');
  const court5 = (t) => (t || '').slice(0, 5);
  const heures = (x) => { const q = Math.round(x * 4) * 15; const hh = Math.floor(q / 60), mm = q % 60; return hh + ' h' + (mm ? ' ' + String(mm).padStart(2, '0') : ''); };
  const nomP = (p) => p.prenom + (p.nom ? ' ' + p.nom.charAt(0) + '.' : '');
  const nomSeance = (s) => s.tache + (s.complement ? ' · ' + s.complement : '');
  const teinte = (hex, a) => hex + Math.round(a * 255).toString(16).padStart(2, '0');

  const etat = {
    droits: null, ref: null, lundi: D.lundiDe(D.aujourdhui()), sem: null,
    selection: null, dimanche: false, choisie: null, recherche: '', toutLeMonde: false,
    vue: 'general', personne: null, cible: null, realise: null,  // cible (vue par activité) : 'a:3', 'at:2', 't:10', 'r:4'
  };
  const peutEcrire = () => ['complet', 'responsable'].includes(etat.droits.niveau);
  const peutAtelier = (id) => peutEcrire() && etat.droits.ateliers.includes(id);

  // Amplitude possible des séances : 4 h – 21 h. La grille montre 6 h – 19 h, élargie aux séances.
  const HEURE_MIN = 4, HEURE_MAX = 21;

  // Heure au quart d'heure : deux listes (heure, minutes). Le sélecteur natif de Chrome ignore le pas.
  function remplirHeure(cible, valeur) {
    const q = Math.round(min(valeur || '09:00') / 15) * 15;
    const sh = el('select', { 'aria-label': 'Heure' }), sm = el('select', { 'aria-label': 'Minutes' });
    for (let h = HEURE_MIN; h <= HEURE_MAX; h++) sh.append(el('option', { value: String(h).padStart(2, '0') }, String(h).padStart(2, '0') + ' h'));
    for (const m of ['00', '15', '30', '45']) sm.append(el('option', { value: m }, m));
    sh.value = String(Math.min(HEURE_MAX, Math.max(HEURE_MIN, Math.floor(q / 60)))).padStart(2, '0'); sm.value = String(q % 60).padStart(2, '0');
    cible.replaceChildren(sh, sm);
    cible.classList.add('champ-heure');
    Object.defineProperty(cible, 'valeur', { configurable: true, get: () => sh.value + ':' + sm.value });
    return cible;
  }

  // Messages ---------------------------------------------------------------------------
  let minuteur;
  function dire(texte, erreur) {
    const m = $('#message');
    m.textContent = texte; m.hidden = false; m.classList.toggle('erreur', !!erreur);
    clearTimeout(minuteur);
    if (!erreur) minuteur = setTimeout(() => { m.hidden = true; }, 4000);
  }
  async function agir(action, params, succes) {
    try {
      const r = await API.appeler(action, params);
      await chargerSemaine();
      if (r.chevauchements && r.chevauchements.length) dire('Attention : chevauchement pour cette personne ce jour-là.', true);
      else if (succes) dire(succes);
      return r;
    } catch (e) { dire(e.message, true); return null; }
  }

  // Sélection (gardée dans ce navigateur) ------------------------------------------------
  function selectionParDefaut() {
    const ateliers = etat.ref.ateliers.filter((a) => a.au_demarrage).map((a) => a.id);
    return new Set(etat.ref.taches.filter((t) => ateliers.includes(t.atelier_id)).map((t) => t.id));
  }
  function chargerSelection() {
    try {
      const v = JSON.parse(localStorage.getItem('planning_selection') || 'null');
      if (Array.isArray(v)) return new Set(v.filter((id) => etat.ref.taches.some((t) => t.id === id)));
    } catch (e) { /* stockage indisponible */ }
    return selectionParDefaut();
  }
  function garderSelection() {
    try { localStorage.setItem('planning_selection', JSON.stringify([...etat.selection])); } catch (e) { /* rien */ }
  }
  const tachesAtelier = (id) => etat.ref.taches.filter((t) => t.atelier_id === id).map((t) => t.id);
  const ateliersActivite = (id) => etat.ref.ateliers.filter((a) => a.activite_id === id).map((a) => a.id);
  const tachesActivite = (id) => ateliersActivite(id).flatMap(tachesAtelier);
  const tachesRegroupement = (id) => etat.ref.taches.filter((t) => t.regroupement_id === id).map((t) => t.id);
  const ateliersSelectionnes = () => new Set(etat.ref.taches.filter((t) => etat.selection.has(t.id)).map((t) => t.atelier_id));

  function caseGroupe(ids, libelle, pastille) {
    const n = ids.filter((id) => etat.selection.has(id)).length;
    const c = el('input', { type: 'checkbox' });
    c.checked = ids.length > 0 && n === ids.length;
    c.indeterminate = n > 0 && n < ids.length;
    c.disabled = ids.length === 0;
    c.addEventListener('change', () => {
      ids.forEach((id) => (c.checked ? etat.selection.add(id) : etat.selection.delete(id)));
      garderSelection(); dessinerSelection(); dessiner();
    });
    return el('label', {}, c, pastille ? el('span', { class: 'pastille', style: 'background:' + pastille }) : null, libelle);
  }
  function dessinerSelection() {
    const acts = $('#sel-activites'); acts.replaceChildren();
    for (const ac of etat.ref.activites) acts.append(caseGroupe(tachesActivite(ac.id), ac.nom));
    const rg = $('#regroupements'); rg.replaceChildren();
    for (const r of etat.ref.regroupements) if (tachesRegroupement(r.id).length) rg.append(caseGroupe(tachesRegroupement(r.id), r.nom));
    const arbre = $('#arbre'); arbre.replaceChildren();
    for (const ac of etat.ref.activites) for (const at of etat.ref.ateliers.filter((a) => a.activite_id === ac.id)) {
      const ts = etat.ref.taches.filter((x) => x.atelier_id === at.id);
      const tete = caseGroupe(tachesAtelier(at.id), at.nom, at.couleur);
      tete.append(el('span', { class: 'sel-soc' }, at.societe));
      arbre.append(el('div', { class: 'sel-carte' + (ts.length ? '' : ' vide'), style: '--c:' + at.couleur }, tete,
        el('div', { class: 'sel-taches' }, ...(ts.length ? ts.map((t) => caseGroupe([t.id], t.nom)) : ['aucune tâche : à créer dans Administration']))));
    }
  }

  // Chargement -----------------------------------------------------------------------------
  async function demarrer() {
    if (!API || !API.aUnJeton()) {
      dire('Ouvre le planning depuis ton lien personnel (bouton « Mon planning » de Suivi des temps) ou depuis l\'administration.', true);
      return;
    }
    if (API.demo) $('#bandeau-demo').hidden = false;
    try {
      const s = await API.appeler('session');
      etat.droits = s.droits; etat.ref = s.referentiel;
    } catch (e) {
      dire(e.message === 'lien_invalide' ? 'Ce lien n\'est pas valide ou n\'est plus actif.' : e.message, true);
      return;
    }
    etat.selection = chargerSelection();
    initRecap();
    try { const v = JSON.parse(localStorage.getItem('planning_vue') || 'null'); if (v) Object.assign(etat, { vue: v.vue || 'general', personne: v.personne || null, cible: v.cible || null }); } catch (e) { /* rien */ }
    // Un collaborateur arrive sur son propre planning.
    if (etat.droits.niveau === 'collaborateur' && etat.droits.personne_id) { etat.vue = 'personne'; etat.personne = etat.droits.personne_id; }
    try { etat.dimanche = localStorage.getItem('planning_dimanche') === '1'; } catch (e) { /* rien */ }
    $('#dimanche').checked = etat.dimanche;
    const libelles = { complet: 'Accès complet', consultation: 'Consultation', responsable: 'Responsable d\'atelier', collaborateur: 'Lecture' };
    $('#qui').textContent = libelles[etat.droits.niveau] || '';
    $('#btn-nouvelle').hidden = !peutEcrire();
    $('#btn-fermer').hidden = etat.droits.niveau !== 'complet';
    $('#onglet-admin').hidden = !['complet', 'consultation'].includes(etat.droits.niveau);
    $('#btn-personne').hidden = !peutEcrire();
    if (etat.vue === 'admin' && $('#onglet-admin').hidden) etat.vue = 'general';
    $('#app').hidden = false;
    dessinerSelection();
    await chargerSemaine();
  }

  async function chargerSemaine() {
    try {
      etat.sem = await API.appeler('semaine', { lundi: etat.lundi });
    } catch (e) { dire(e.message, true); return; }
    if (etat.choisie && !etat.sem.seances.some((s) => s.id === etat.choisie)) etat.choisie = null;
    dessiner();
  }

  // Réalisé (Suivi des temps) de la personne affichée, pour la semaine affichée.
  let realiseEnCours = null;
  function realiseAJour() { return etat.realise && etat.realise.cle === etat.personne + '|' + etat.lundi; }
  async function chargerRealise() {
    const cle = etat.personne + '|' + etat.lundi;
    if (realiseEnCours === cle) return;
    realiseEnCours = cle;
    try { const r = await API.appeler('realise', { personne_id: etat.personne, lundi: etat.lundi }); etat.realise = Object.assign(r, { cle }); }
    catch (e) { etat.realise = { cle, jours: [], erreur: e.message }; }
    realiseEnCours = null;
    if (etat.vue === 'personne') dessiner();
  }
  // Par date : créneaux en minutes, type de jour, heures saisies (toutes fiches réunies).
  function realiseParDate() {
    const m = new Map();
    for (const j of (realiseAJour() ? etat.realise.jours : [])) {
      const x = m.get(j.date) || { creneaux: [], heures: 0, types: new Set() };
      x.creneaux.push(...j.creneaux.map(([a, b]) => [min(a), min(b)]).filter(([a, b]) => b > a));
      x.heures += +j.heures || 0; x.types.add(j.type); m.set(j.date, x);
    }
    for (const x of m.values()) x.saisi = x.heures > 0 || x.types.has('CP') || x.types.has('AT');
    return m;
  }
  // Minutes d'une séance couvertes par les créneaux réels du jour.
  const couvert = (s, cr) => cr.reduce((a, [d, f]) => a + Math.max(0, Math.min(f, min(s.heure_fin)) - Math.max(d, min(s.heure_debut))), 0);
  const dernierSaisi = (rp) => [...rp].filter(([d, x]) => x.saisi && d <= D.aujourdhui()).map(([d]) => d).sort().pop() || null;

  // Grille ---------------------------------------------------------------------------------
  const tachesCible = () => {
    const [k, v] = (etat.cible || '').split(':'); const id = +v;
    if (k === 'a') return tachesActivite(id);
    if (k === 'at') return tachesAtelier(id);
    if (k === 't') return [id];
    if (k === 'r') return tachesRegroupement(id);
    return [];
  };
  const libelleCible = () => {
    const [k, v] = (etat.cible || '').split(':'); const id = +v;
    const liste = { a: etat.ref.activites, at: etat.ref.ateliers, t: etat.ref.taches, r: etat.ref.regroupements }[k] || [];
    const x = liste.find((o) => o.id === id); return x ? x.nom : '';
  };
  const ecartJour = (x) => Math.abs(x) < 0.125 ? el('span', { class: 'ecart-nul' }, '= ') : el('span', { class: x > 0 ? 'ecart-plus' : 'ecart-moins' }, (x > 0 ? '+' : '−') + heures(Math.abs(x)));
  // Une séance à moi sur une tâche que je ne vois pas autrement : toujours affichée.
  const estAMoiHorsReferentiel = (s) => !!(etat.droits && etat.droits.personne_id) && !etat.ref.taches.some((t) => t.id === s.tache_id) && avecPersonne(s, etat.droits.personne_id);
  const avecPersonne = (s, pid) => s.personnes.some((p) => p.personne_id === pid);
  const visible = (s) => etat.vue === 'personne' ? avecPersonne(s, etat.personne)
    : etat.vue === 'activite' ? tachesCible().includes(s.tache_id)
    : etat.selection.has(s.tache_id) || estAMoiHorsReferentiel(s);
  // Heures comptées pour une séance dans la vue : celles de la personne, ou la main-d'œuvre.
  const heuresVue = (s) => etat.vue === 'personne' ? (s.statut === 'prevue' ? s.duree_h : 0) : s.main_oeuvre_h;
  const personneCourante = () => etat.sem && etat.sem.personnes.find((p) => p.id === etat.personne);
  const joursAffiches = () => (etat.dimanche ? 7 : 6);

  function bornes(seances) {
    let a = 6 * 60, b = 19 * 60;
    for (const s of seances) { a = Math.min(a, Math.floor(min(s.heure_debut) / 60) * 60); b = Math.max(b, Math.ceil(min(s.heure_fin) / 60) * 60); }
    return [a, b];
  }

  // Couloirs : les séances qui se recouvrent dans une même journée se partagent la largeur.
  function couloirs(liste) {
    const tri = liste.slice().sort((x, y) => min(x.heure_debut) - min(y.heure_debut) || min(y.heure_fin) - min(x.heure_fin));
    const res = []; let groupe = []; let finGroupe = -1;
    const fermer = () => { const n = Math.max(1, ...groupe.map((g) => g.couloir + 1)); groupe.forEach((g) => { g.nb = n; res.push(g); }); groupe = []; };
    for (const s of tri) {
      if (groupe.length && min(s.heure_debut) >= finGroupe) fermer(), (finGroupe = -1);
      const pris = new Set(groupe.filter((g) => min(g.s.heure_fin) > min(s.heure_debut)).map((g) => g.couloir));
      let c = 0; while (pris.has(c)) c++;
      groupe.push({ s, couloir: c }); finGroupe = Math.max(finGroupe, min(s.heure_fin));
    }
    if (groupe.length) fermer();
    return res;
  }

  function dessiner() {
    const sem = etat.sem; if (!sem) return;
    const pleine = etat.vue === 'recap' || etat.vue === 'admin';
    $('#recap').hidden = etat.vue !== 'recap'; $('#admin').hidden = etat.vue !== 'admin';
    for (const x of ['.outils', '#legende', '.corps']) document.querySelector(x).hidden = pleine;
    if (pleine) { $('#panneau-selection').hidden = true; dessinerChoix(); if (etat.vue === 'recap') dessinerRecap(); else dessinerAdmin(); return; }
    const nbJ = joursAffiches();
    const dates = Array.from({ length: nbJ }, (_, i) => D.ajout(etat.lundi, i));
    $('#titre-semaine').textContent = 'Semaine ' + D.numSemaine(etat.lundi);
    $('#dates-semaine').textContent = 'du ' + D.long(etat.lundi) + ' au ' + D.long(D.ajout(etat.lundi, 6));
    const pc = personneCourante();
    if (etat.vue === 'personne' && pc) $('#titre-semaine').textContent += ' · ' + pc.prenom + ' ' + pc.nom;
    if (etat.vue === 'activite' && etat.cible) $('#titre-semaine').textContent += ' · ' + libelleCible();
    dessinerChoix();
    $('#grille').hidden = etat.vue === 'activite'; $('#tableau').hidden = etat.vue !== 'activite';
    if (etat.vue === 'activite') {
      const liste = sem.seances.filter((x) => visible(x) && !x.trace && x.date_seance <= D.ajout(etat.lundi, nbJ - 1));
      dessinerTableau(liste, dates); dessinerLegende(liste); dessinerPersonnes(); dessinerDetail();
      return;
    }

    const seances = sem.seances.filter(visible);
    // Une séance déplacée laisse une trace à sa date d'origine si celle-ci est dans la semaine.
    const blocs = [];
    for (const s of seances) {
      if (!s.trace) blocs.push({ s, date: s.date_seance, trace: false });
      if (s.deplacee && s.date_serie >= etat.lundi && s.date_serie <= D.ajout(etat.lundi, 6)) blocs.push({ s, date: s.date_serie, trace: true });
    }
    const enPersonne = etat.vue === 'personne' && etat.personne;
    if (enPersonne && !realiseAJour()) chargerRealise();
    const rp = enPersonne ? realiseParDate() : new Map();
    const fin = enPersonne ? dernierSaisi(rp) : null;
    const [hMin, hMax] = bornes(seances.concat([...rp.values()].flatMap((x) => x.creneaux.map(([a, b]) => ({ heure_debut: hhmm(a), heure_fin: hhmm(b) })))));
    const pxMin = pixelsParMinute(hMax - hMin);
    const hauteur = (hMax - hMin) * pxMin;

    const g = $('#grille'); g.replaceChildren();
    g.style.gridTemplateColumns = '56px repeat(' + nbJ + ', minmax(0, 1fr))';
    g.append(el('div', { class: 'entete-jour', style: 'border-left:0' }));
    const fermes = sem.jours_fermes || [];
    for (const [i, d] of dates.entries()) {
      const f = fermes.find((x) => x.date === d);
      const mo = seances.filter((s) => !s.trace && s.date_seance === d).reduce((a, s) => a + heuresVue(s), 0);
      const r = rp.get(d);
      let ligneR = null;
      if (enPersonne) {
        if (r && r.saisi) {
          const t = [...r.types].find((x) => x === 'CP' || x === 'AT');
          ligneR = el('div', { class: 'mo mono' }, 'R ' + heures(r.heures) + (t ? ' · ' + t : ''), ' ', ecartJour(r.heures - mo));
        } else if (d <= D.aujourdhui() && realiseAJour() && mo > 0) ligneR = el('div', { class: 'mo non-saisi' }, d === D.aujourdhui() ? 'pas encore saisi' : 'non saisi');
      }
      g.append(el('div', { class: 'entete-jour' + (f ? ' ferme' : '') },
        el('div', {}, el('span', { class: 'nom' }, JOURS[i]), ' ', el('span', { class: 'sous' }, D.court(d))),
        el('div', { class: 'mo mono' }, f ? '0 h · fermé' : (enPersonne ? 'P ' : '') + heures(mo) + (etat.vue === 'personne' ? '' : ' de MO')),
        ligneR,
        f ? el('div', { class: 'badge-ferme' }, (f.societe ? f.societe + ' · ' : '') + (f.motif || 'Fermé')) : null));
    }
    const colH = el('div', { class: 'col-heures', style: 'height:' + hauteur + 'px' });
    for (let m = hMin; m < hMax; m += 60) colH.append(el('div', { class: 'libelle-heure mono', style: 'top:' + ((m - hMin) * pxMin + (m === hMin ? 7 : 0)) + 'px' }, hhmm(m)));
    g.append(colH);

    for (const d of dates) {
      const f = fermes.find((x) => x.date === d && !x.societe);
      const col = el('div', { class: 'col-jour' + (f ? ' ferme' : ''), style: 'height:' + hauteur + 'px', 'data-date': d });
      for (let m = hMin + 15; m < hMax; m += 15) col.append(el('div', { class: 'ligne-heure' + (m % 60 === 0 ? '' : m % 30 === 0 ? ' demi' : ' quart'), style: 'top:' + (m - hMin) * pxMin + 'px' }));
      const r = rp.get(d);
      for (const c of couloirs(blocs.filter((b) => b.date === d).map((b) => Object.assign({}, b.s, { _trace: b.trace })))) {
        const bloc = blocSeance(c.s, c.couloir, c.nb, hMin, pxMin, enPersonne ? 0 : 0, enPersonne ? 56 : 100);
        if (enPersonne && r && r.saisi && !c.s._trace && c.s.statut === 'prevue') {
          const cv = couvert(c.s, r.creneaux) / 60, ec = cv - c.s.duree_h;
          const ligne = el('span', { class: 'reel' + (Math.abs(ec) >= 0.25 ? ' ecart' : ''), title: 'Réalisé pendant la séance : ' + heures(cv) }, 'réel ' + heures(cv) + (Math.abs(ec) >= 0.25 ? ' · ' + (ec > 0 ? '+' : '−') + heures(Math.abs(ec)) : ' ✓'));
          const hEl = bloc.querySelector('.h'); hEl ? hEl.after(ligne) : bloc.append(ligne);
        }
        col.append(bloc);
      }
      if (enPersonne) {
        col.append(el('div', { class: 'separation-pr' }));
        if (r) for (const [a, b] of r.creneaux) {
          const h = (b - a) * pxMin;
          col.append(el('div', { class: 'realise', style: `top:${(a - hMin) * pxMin + 1}px;height:${Math.max(h - 2, 16)}px`, title: 'Réalisé ' + hhmm(a) + '–' + hhmm(b) },
            el('span', { class: 'h' }, hhmm(a) + '–' + hhmm(b)), h >= 40 ? el('span', { class: 'p' }, heures((b - a) / 60)) : null));
        }
        if (r && !r.creneaux.length && (r.types.has('CP') || r.types.has('AT'))) col.append(el('div', { class: 'realise absence', style: 'top:4px;bottom:4px' }, [...r.types].filter((t) => t !== 'travaillée').join(' ')));
      }
      if (peutEcrire()) brancherDepot(col, hMin, pxMin);
      g.append(col);
    }
    dessinerLegende(seances);
    dessinerPersonnes();
    dessinerDetail();
  }

  function blocSeance(s, couloir, nb, hMin, pxMin, x0 = 0, w = 100) {
    const trace = s._trace;
    const conflit = !trace && s.chevauchements && s.chevauchements.length > 0;
    const haut = (min(s.heure_debut) - hMin) * pxMin;
    const h = (min(s.heure_fin) - min(s.heure_debut)) * pxMin;
    const modifiable = !trace && peutAtelier(s.atelier_id);
    const classes = ['seance', modifiable && 'modifiable', s.statut === 'suspendue' && 'suspendue', trace && 'trace', conflit && 'conflit', etat.choisie === s.id && !trace && 'choisie'].filter(Boolean).join(' ');
    let etiq = null;
    if (conflit) etiq = el('span', { class: 'etiquette rouge' }, 'Chevauchement');
    else if (trace) etiq = el('span', { class: 'etiquette' }, 'Déplacée au ' + D.court(s.date_seance));
    else if (s.statut === 'suspendue') etiq = el('span', { class: 'etiquette' }, s.motif || 'Suspendue');
    else if (s.deplacee) etiq = el('span', { class: 'etiquette' }, 'Déplacée du ' + D.court(s.date_serie));
    const b = el('button', {
      class: classes, type: 'button',
      style: `top:${haut + 1}px;height:${Math.max(h - 2, 18)}px;left:calc(${x0 + (couloir * w) / nb}% + 3px);width:calc(${w / nb}% - 6px);background:${teinte(s.couleur, 0.16)};border-color:${s.couleur};color:#1B211E`,
      'aria-label': `${nomSeance(s)}, ${D.long(trace ? s.date_serie : s.date_seance)}, ${court5(s.heure_debut)} à ${court5(s.heure_fin)}, ${s.personnes.map(nomP).join(', ') || 'personne'}`,
      draggable: modifiable ? 'true' : null,
      'data-seance': s.id,
      onclick: () => { etat.choisie = s.id; dessiner(); if (modifiable) ouvrirSeance(s); },
    },
      el('span', { class: 't' }, nomSeance(s)),
      el('span', { class: 'h' }, court5(s.heure_debut) + '–' + court5(s.heure_fin)),
      h >= 64 ? el('span', { class: 'p' }, s.personnes.map(nomP).join(', ')) : null,
      h >= 50 ? etiq : null);
    if (modifiable) {
      b.addEventListener('dragstart', (ev) => {
        ev.dataTransfer.setData('application/x-seance', JSON.stringify({ id: s.id, decalage: ev.offsetY }));
        ev.dataTransfer.effectAllowed = 'move';
      });
      // Dépôt d'une personne sur la séance
      b.addEventListener('dragover', (ev) => { if (ev.dataTransfer.types.includes('application/x-personne')) { ev.preventDefault(); ev.stopPropagation(); b.classList.add('cible'); } });
      b.addEventListener('dragleave', () => b.classList.remove('cible'));
      b.addEventListener('drop', (ev) => {
        if (!ev.dataTransfer.types.includes('application/x-personne')) return;
        ev.preventDefault(); ev.stopPropagation(); b.classList.remove('cible');
        const pid = +ev.dataTransfer.getData('application/x-personne');
        etat.choisie = s.id;
        agir('affecter', { seance_id: s.id, personne_id: pid }, 'Personne ajoutée.');
      });
    }
    return b;
  }

  // Glisser une séance vers un autre jour ou une autre heure (pas d'un quart d'heure).
  function brancherDepot(col, hMin, pxMin) {
    let fantome = null;
    const ou = (ev, decalage, duree) => {
      const r = col.getBoundingClientRect();
      const m = Math.round(((ev.clientY - r.top - decalage) / pxMin + hMin) / 15) * 15;
      return Math.max(HEURE_MIN * 60, Math.min(HEURE_MAX * 60 - duree, m));
    };
    col.addEventListener('dragover', (ev) => {
      if (!ev.dataTransfer.types.includes('application/x-seance')) return;
      ev.preventDefault(); col.classList.add('survol');
    });
    col.addEventListener('dragleave', (ev) => { if (!col.contains(ev.relatedTarget)) { col.classList.remove('survol'); if (fantome) fantome.remove(), (fantome = null); } });
    col.addEventListener('drop', async (ev) => {
      const brut = ev.dataTransfer.getData('application/x-seance'); if (!brut) return;
      ev.preventDefault(); col.classList.remove('survol'); if (fantome) fantome.remove(), (fantome = null);
      const { id, decalage } = JSON.parse(brut);
      const s = etat.sem.seances.find((x) => x.id === id); if (!s) return;
      const duree = min(s.heure_fin) - min(s.heure_debut);
      const debut = ou(ev, decalage, duree);
      const date = col.dataset.date;
      if (date === s.date_seance && debut === min(s.heure_debut)) return;
      const params = { seance_id: id, date, debut: hhmm(debut), fin: hhmm(debut + duree) };
      const portee = s.serie_id ? await demanderPortee(`${nomSeance(s)} : ${D.long(date)}, ${hhmm(debut)}–${hhmm(debut + duree)}`) : 'seance';
      if (!portee) return;
      etat.choisie = id;
      agir('seance_modifier', Object.assign(params, { portee }), 'Séance déplacée.');
    });
  }

  function demanderPortee(resume) {
    const d = $('#dlg-portee');
    $('#portee-resume').textContent = resume;
    return new Promise((ok) => {
      d.addEventListener('close', () => ok(['seance', 'suivantes'].includes(d.returnValue) ? d.returnValue : null), { once: true });
      d.returnValue = ''; d.showModal();
    });
  }

  function dessinerLegende(seances) {
    const lg = $('#legende'); lg.replaceChildren();
    const reelles = seances.filter((x) => !x.trace);
    // Vue par activité : une puce par tâche ; sinon une par atelier.
    const parTache = etat.vue === 'activite';
    const groupes = new Map();
    for (const s of reelles) {
      const k = parTache ? s.tache_id : s.atelier_id;
      if (!groupes.has(k)) groupes.set(k, { nom: parTache ? s.tache : s.atelier, couleur: s.couleur, h: 0 });
      groupes.get(k).h += heuresVue(s);
    }
    for (const g of groupes.values()) {
      lg.append(el('span', { class: 'puce', style: `background:${teinte(g.couleur, 0.16)};border-color:${g.couleur}` },
        el('span', { class: 'pastille', style: 'background:' + g.couleur }), g.nom + ' · ' + heures(g.h)));
    }
    const total = [...groupes.values()].reduce((a, g) => a + g.h, 0);
    if (etat.vue === 'personne') {
      const p = personneCourante();
      const ref = p ? p.fiches.reduce((a, f) => a + (+f.heures_hebdo || 0), 0) : 0;
      const mad = reelles.filter((s) => s.statut === 'prevue' && s.personnes.some((x) => x.personne_id === etat.personne && x.mad)).reduce((a, s) => a + s.duree_h, 0);
      const rp = realiseParDate(), fin = dernierSaisi(rp);
      let reel = null;
      if (realiseAJour() && fin) {
        const prevuAuFin = reelles.filter((s) => s.statut === 'prevue' && s.date_seance <= fin).reduce((a, s) => a + s.duree_h, 0);
        const realiseAuFin = [...rp].filter(([d]) => d <= fin).reduce((a, [, x]) => a + x.heures, 0);
        reel = el('span', { class: 'total-reel' }, 'Jusqu\'au ' + D.long(fin) + ' : prévu ', el('strong', {}, heures(prevuAuFin)), ' · réalisé ', el('strong', {}, heures(realiseAuFin)), ' ', ecartJour(realiseAuFin - prevuAuFin));
      } else if (realiseAJour()) reel = el('span', { class: 'total-reel' }, 'Aucune saisie cette semaine');
      lg.append(el('span', { class: 'total' }, el('strong', {}, heures(total)), ' prévues' + (ref ? ' · contrat ' + heures(ref) : '') + (mad ? ' · dont ' + heures(mad) + ' en mise à disposition' : '')), reel);
    } else {
      const pers = new Set(seances.filter((s) => !s.trace && s.statut === 'prevue').flatMap((s) => s.personnes.map((p) => p.personne_id)));
    lg.append(el('span', { class: 'total' }, el('strong', {}, heures(total)), ' de main-d\'œuvre · ' + pers.size + ' personne' + (pers.size > 1 ? 's' : '')));
    }
    const nbConflits = new Set(seances.filter((s) => !s.trace).flatMap((s) => (s.chevauchements || []).map((p) => s.date_seance + ':' + p))).size;
    if (nbConflits) lg.append(el('span', { class: 'alerte' }, nbConflits + ' chevauchement' + (nbConflits > 1 ? 's' : '')));
  }

  // Vue par activité : séances jour par jour, puis bilans par tâche et par personne -------
  function dessinerTableau(liste, dates) {
    const z = $('#tableau'); z.replaceChildren();
    if (!etat.cible) { z.append(el('p', { class: 'vide' }, 'Choisis une activité, un atelier, une tâche ou un regroupement.')); return; }
    if (!liste.length) { z.append(el('p', { class: 'vide' }, 'Aucune séance cette semaine pour « ' + libelleCible() + ' ».')); return; }
    const nb = (x) => el('td', { class: 'nb' }, x);
    const tb = el('tbody');
    let tDuree = 0, tMo = 0;
    for (const d of dates) {
      const jour = liste.filter((s) => s.date_seance === d).sort((a, b) => min(a.heure_debut) - min(b.heure_debut));
      if (!jour.length) continue;
      const mo = jour.reduce((a, s) => a + s.main_oeuvre_h, 0);
      tb.append(el('tr', { class: 'jour' }, el('td', { colspan: 5 }, D.long(d).replace(/^./, (c) => c.toUpperCase())), nb(heures(mo))));
      for (const s of jour) {
        const compte = s.statut === 'prevue';
        if (compte) tDuree += s.duree_h; tMo += s.main_oeuvre_h;
        tb.append(el('tr', { class: 'ligne' + (compte ? '' : ' suspendue') + (etat.choisie === s.id ? ' choisie' : ''), onclick: () => { etat.choisie = s.id; dessiner(); if (peutAtelier(s.atelier_id)) ouvrirSeance(s); } },
          el('td', { class: 'mono' }, court5(s.heure_debut) + '–' + court5(s.heure_fin)),
          el('td', {}, el('span', { class: 'tache-nom' }, el('span', { class: 'pastille', style: 'background:' + s.couleur }), nomSeance(s)),
            compte ? null : el('div', { class: 'sous' }, s.motif || 'Suspendue', ' · non comptée'),
            s.lieu ? el('div', { class: 'sous' }, s.lieu) : null),
          el('td', {}, s.personnes.map((p) => p.prenom + ' ' + p.nom + (p.mad ? ' (MàD)' : '')).join(', ') || el('span', { class: 'sous' }, 'personne')),
          nb(heures(s.duree_h)), nb(String(s.nb_personnes)), nb(compte ? heures(s.main_oeuvre_h) : '—')));
      }
    }
    tb.append(el('tr', { class: 'total' }, el('td', { colspan: 3 }, 'Total de la semaine'), nb(heures(tDuree)), nb(''), nb(heures(tMo))));
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Horaires'), el('th', {}, 'Séance'), el('th', {}, 'Personnes'),
      el('th', { class: 'nb' }, 'Durée'), el('th', { class: 'nb' }, 'Pers.'), el('th', { class: 'nb' }, 'Main-d\'œuvre'))), tb));

    // Bilans (séances prévues seulement)
    const prevues = liste.filter((s) => s.statut === 'prevue');
    const parTache = new Map(), parPers = new Map();
    for (const s of prevues) {
      const t = parTache.get(s.tache_id) || { nom: s.tache, couleur: s.couleur, n: 0, h: 0 }; t.n++; t.h += s.main_oeuvre_h; parTache.set(s.tache_id, t);
      for (const p of s.personnes) { const x = parPers.get(p.personne_id) || { nom: p.prenom + ' ' + p.nom, n: 0, h: 0 }; x.n++; x.h += s.duree_h; parPers.set(p.personne_id, x); }
    }
    const bilan = (titre, entetes, lignes) => el('div', {}, el('h3', {}, titre), el('table', {},
      el('thead', {}, el('tr', {}, ...entetes.map((e, i) => el('th', { class: i ? 'nb' : '' }, e)))), el('tbody', {}, ...lignes)));
    z.append(el('div', { class: 'bilans' },
      bilan('Par tâche', ['Tâche', 'Séances', 'Main-d\'œuvre'], [...parTache.values()].sort((a, b) => b.h - a.h).map((t) =>
        el('tr', {}, el('td', {}, el('span', { class: 'tache-nom' }, el('span', { class: 'pastille', style: 'background:' + t.couleur }), t.nom)), nb(String(t.n)), nb(heures(t.h))))),
      bilan('Par personne', ['Personne', 'Séances', 'Heures'], [...parPers.values()].sort((a, b) => b.h - a.h || a.nom.localeCompare(b.nom)).map((x) =>
        el('tr', {}, el('td', {}, x.nom), nb(String(x.n)), nb(heures(x.h)))))));
  }

  // Choix de la personne ou de l'activité, selon la vue --------------------------------------
  function dessinerChoix() {
    for (const b of document.querySelectorAll('[data-vue]')) {
      const a = b.dataset.vue === etat.vue; b.classList.toggle('actif', a);
      if (a) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
    }
    const general = etat.vue === 'general';
    const avecChoix = etat.vue === 'personne' || etat.vue === 'activite';
    $('#choix-vue').hidden = !avecChoix;
    $('#btn-selection').hidden = !general;
    if (!general) { $('#panneau-selection').hidden = true; $('#btn-selection').setAttribute('aria-expanded', 'false'); }
    if (!avecChoix) return;
    const sel = $('#choix'); sel.replaceChildren();
    if (etat.vue === 'personne') {
      $('#choix-libelle').textContent = 'Personne';
      if (!etat.sem.personnes.some((p) => p.id === etat.personne)) sel.append(el('option', { value: '' }, '— choisir —'));
      for (const p of etat.sem.personnes) sel.append(el('option', { value: p.id, selected: p.id === etat.personne }, p.prenom + ' ' + p.nom));
      sel.value = etat.sem.personnes.some((p) => p.id === etat.personne) ? String(etat.personne) : '';
    } else {
      $('#choix-libelle').textContent = 'Activité';
      const groupe = (label, liste, k, prefixe) => {
        const og = el('optgroup', { label });
        liste.forEach((x) => og.append(el('option', { value: k + ':' + x.id }, (prefixe ? prefixe(x) : '') + x.nom)));
        if (og.children.length) sel.append(og);
      };
      if (!etat.cible) sel.append(el('option', { value: '' }, '— choisir —'));
      groupe('Activités', etat.ref.activites, 'a');
      groupe('Ateliers', etat.ref.ateliers.filter((a) => tachesAtelier(a.id).length), 'at');
      groupe('Tâches', etat.ref.taches, 't', (t) => (etat.ref.ateliers.find((a) => a.id === t.atelier_id) || {}).nom + ' › ');
      groupe('Regroupements', etat.ref.regroupements.filter((r) => tachesRegroupement(r.id).length), 'r');
      sel.value = etat.cible || '';
    }
  }
  function changerVue(vue, valeur) {
    etat.vue = vue;
    if (vue === 'personne' && valeur != null) { etat.personne = +valeur; etat.realise = null; }
    if (vue === 'activite' && valeur != null) etat.cible = valeur;
    if (vue === 'activite' && !etat.cible) {
      const at = etat.ref.ateliers.find((a) => etat.selection.has(tachesAtelier(a.id)[0])) || etat.ref.ateliers.find((a) => tachesAtelier(a.id).length);
      if (at) etat.cible = 'at:' + at.id;
    }
    try { localStorage.setItem('planning_vue', JSON.stringify({ vue: etat.vue, personne: etat.personne, cible: etat.cible })); } catch (e) { /* rien */ }
    dessiner();
  }

  // Récapitulatifs (lot 5) ---------------------------------------------------------------------
  // Les données arrivent brutes (jour par jour) ; tout le regroupement se fait ici.
  const R = {
    onglet: 'personne', periode: 'mois', debut: null, fin: null, pas: 'semaine', niveau: 'atelier',
    selection: false, q: '', donnees: null, cle: '', ouverts: new Set(), table: null,
  };
  function bornesPeriode(code) {
    const auj = D.aujourdhui(), l = D.lundiDe(auj), m1 = auj.slice(0, 8) + '01';
    const finMois = (d) => { const x = new Date(d + 'T12:00:00Z'); x.setUTCMonth(x.getUTCMonth() + 1, 0); return D.iso(x); };
    const moisPrec = (() => { const x = new Date(m1 + 'T12:00:00Z'); x.setUTCMonth(x.getUTCMonth() - 1); return D.iso(x); })();
    return {
      semaine: [l, D.ajout(l, 6)], semaine_prec: [D.ajout(l, -7), D.ajout(l, -1)],
      mois: [m1, finMois(m1)], mois_prec: [moisPrec, finMois(moisPrec)],
      '4sem': [D.ajout(l, -21), D.ajout(l, 6)], annee: [auj.slice(0, 4) + '-01-01', auj],
    }[code];
  }
  const cleDe = (d) => R.pas === 'jour' ? d : R.pas === 'semaine' ? D.lundiDe(d) : d.slice(0, 7);
  const MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  function libelleCle(k) {
    if (R.pas === 'mois') return MOIS[+k.slice(5, 7) - 1] + ' ' + k.slice(0, 4);
    if (R.pas === 'semaine') return 'S' + D.numSemaine(k) + ' · ' + D.court(k);
    return JOURS[D.jourIso(k) - 1] + ' ' + D.court(k);
  }
  function cles() {
    const res = []; for (let d = R.debut; d <= R.fin; d = D.ajout(d, 1)) { const k = cleDe(d); if (res[res.length - 1] !== k) res.push(k); }
    return res;
  }
  const h2 = (x) => x ? heures(x) : '—';
  const ecart = (x) => { if (Math.abs(x) < 0.125) return el('span', {}, '0 h'); return el('span', { class: x > 0 ? 'ecart-plus' : 'ecart-moins' }, (x > 0 ? '+' : '−') + heures(Math.abs(x))); };

  async function chargerRecap() {
    const cle = R.debut + '|' + R.fin;
    if (R.donnees && R.cle === cle) { dessinerRecap(); return; }
    $('#r-contenu').replaceChildren(el('p', { class: 'vide' }, 'Chargement…'));
    try { R.donnees = await API.appeler('recap', { debut: R.debut, fin: R.fin }); R.cle = cle; }
    catch (e) { R.donnees = null; $('#r-contenu').replaceChildren(el('p', { class: 'vide' }, e.message)); return; }
    dessinerRecap();
  }

  // Heures de contrat d'un jour : heures hebdo / 5 du lundi au vendredi, pour chaque fiche en vigueur.
  function contratJour(contrats, d) {
    if (D.jourIso(d) > 5) return 0;
    return contrats.reduce((a, c) => a + (c[5] <= d && (!c[6] || c[6] >= d) ? (+c[4] || 0) / 5 : 0), 0);
  }

  function calculPersonnes() {
    const x = R.donnees, auj = D.aujourdhui();
    const gens = new Map();
    for (const [id, prenom, nom, externe] of x.personnes) gens.set(id, { id, prenom, nom, externe, contrats: [], t: {}, ateliers: new Map(), mad: 0 });
    for (const c of x.contrats) if (gens.has(c[0])) gens.get(c[0]).contrats.push(c);
    const bloc = (p, k) => p.t[k] || (p.t[k] = { contrat: 0, prevu: 0, realise: 0, prevuPasse: 0, realisePasse: 0, cp: 0, at: 0 });
    for (const p of gens.values()) for (let d = R.debut; d <= R.fin; d = D.ajout(d, 1)) { const c = contratJour(p.contrats, d); if (c) bloc(p, cleDe(d)).contrat += c; }
    for (const [pid, d, at, hh, mad] of x.prevu) {
      const p = gens.get(pid); if (!p) continue;
      const b = bloc(p, cleDe(d)); b.prevu += +hh; if (d < auj) b.prevuPasse += +hh;
      p.ateliers.set(at, (p.ateliers.get(at) || 0) + +hh); if (mad) p.mad += +hh;
    }
    for (const [pid, d, type, hh] of x.realise) {
      const p = gens.get(pid); if (!p) continue;
      const b = bloc(p, cleDe(d)); b.realise += +hh; if (d < auj) b.realisePasse += +hh;
      if (type === 'CP') b.cp++; if (type === 'AT') b.at++;
    }
    for (const p of gens.values()) {
      p.tot = Object.values(p.t).reduce((a, b) => { for (const k in b) a[k] = (a[k] || 0) + b[k]; return a; }, { contrat: 0, prevu: 0, realise: 0, prevuPasse: 0, realisePasse: 0, cp: 0, at: 0 });
    }
    let liste = [...gens.values()];
    const q = R.q.trim().toLowerCase();
    if (q) liste = liste.filter((p) => (p.prenom + ' ' + p.nom).toLowerCase().includes(q));
    if (R.selection) {
      const ateliers = ateliersSelectionnes();
      const societes = new Set(etat.ref.ateliers.filter((a) => ateliers.has(a.id)).map((a) => a.societe));
      liste = liste.filter((p) => [...p.ateliers.keys()].some((a) => ateliers.has(a)) || p.contrats.some((c) => societes.has(c[2])));
    }
    return liste.filter((p) => p.tot.contrat || p.tot.prevu || p.tot.realise || p.tot.cp || p.tot.at);
  }

  function dessinerRecapPersonnes() {
    const liste = calculPersonnes();
    const z = $('#r-contenu'); z.replaceChildren();
    const lignesCsv = [['Personne', 'Contrat(s)', 'Période', 'Contrat (h)', 'Prévu (h)', 'Réalisé (h)', 'Écart réalisé - prévu, jours écoulés (h)', 'CP (j)', 'AT (j)']];
    if (!liste.length) { z.append(el('p', { class: 'vide' }, 'Rien sur cette période.')); R.table = lignesCsv; resumeRecap(0, 0, 0); return; }
    const couleur = (id) => (etat.ref.ateliers.find((a) => a.id === id) || {}).couleur || '#999';
    const nomAt = (id) => (etat.ref.ateliers.find((a) => a.id === id) || {}).nom || '?';
    const tb = el('tbody'); const T = { contrat: 0, prevu: 0, realise: 0, prevuPasse: 0, realisePasse: 0, cp: 0, at: 0 };
    const seul = liste.length === 1;
    for (const p of liste) {
      for (const k in T) T[k] += p.tot[k];
      const texteContrat = p.externe ? 'Externe' : [...new Set(p.contrats.map((c) => c[3] + (c[4] ? ' ' + (+c[4]) + ' h' : '') + ' · ' + c[2]))].join(' + ') || '—';
      const ouvert = seul || R.ouverts.has(p.id);
      const total = [...p.ateliers.values()].reduce((a, b) => a + b, 0);
      const barre = el('div', { class: 'repartition', title: [...p.ateliers].map(([a, hh]) => nomAt(a) + ' ' + heures(hh)).join(' · ') + (p.mad ? ' · dont ' + heures(p.mad) + ' en mise à disposition' : '') },
        ...[...p.ateliers].sort((a, b) => b[1] - a[1]).map(([a, hh]) => el('span', { style: `width:${(hh / total) * 100}%;background:${couleur(a)}` })));
      tb.append(el('tr', { class: 'ligne-p' + (ouvert ? ' ouverte' : ''), onclick: () => { R.ouverts.has(p.id) ? R.ouverts.delete(p.id) : R.ouverts.add(p.id); dessinerRecap(); } },
        el('td', {}, el('span', { class: 'chevron' }, ouvert ? '▾' : '▸'), el('strong', {}, p.prenom + ' ' + p.nom)),
        el('td', { class: 'sous' }, texteContrat),
        el('td', { class: 'nb' }, h2(p.tot.contrat)), el('td', { class: 'nb' }, h2(p.tot.prevu)), el('td', { class: 'nb' }, h2(p.tot.realise)),
        el('td', { class: 'nb' }, ecart(p.tot.realisePasse - p.tot.prevuPasse)),
        el('td', { class: 'nb' }, p.tot.cp ? String(p.tot.cp) : '—'), el('td', { class: 'nb' }, p.tot.at ? String(p.tot.at) : '—'),
        el('td', {}, total ? barre : el('span', { class: 'sous' }, '—'))));
      for (const k of cles()) {
        const b = p.t[k] || { contrat: 0, prevu: 0, realise: 0, prevuPasse: 0, realisePasse: 0, cp: 0, at: 0 };
        lignesCsv.push([p.prenom + ' ' + p.nom, texteContrat, libelleCle(k), b.contrat, b.prevu, b.realise, b.realisePasse - b.prevuPasse, b.cp, b.at]);
        if (!ouvert) continue;
        tb.append(el('tr', { class: 'sous-ligne' }, el('td', {}, libelleCle(k)), el('td', {}),
          el('td', { class: 'nb' }, h2(b.contrat)), el('td', { class: 'nb' }, h2(b.prevu)), el('td', { class: 'nb' }, h2(b.realise)),
          el('td', { class: 'nb' }, b.prevuPasse || b.realisePasse ? ecart(b.realisePasse - b.prevuPasse) : '—'),
          el('td', { class: 'nb' }, b.cp ? String(b.cp) : '—'), el('td', { class: 'nb' }, b.at ? String(b.at) : '—'), el('td', {})));
      }
    }
    if (liste.length > 1) tb.append(el('tr', { class: 'total' }, el('td', {}, 'Total · ' + liste.length + ' personnes'), el('td', {}),
      el('td', { class: 'nb' }, h2(T.contrat)), el('td', { class: 'nb' }, h2(T.prevu)), el('td', { class: 'nb' }, h2(T.realise)),
      el('td', { class: 'nb' }, ecart(T.realisePasse - T.prevuPasse)), el('td', { class: 'nb' }, String(T.cp || '—')), el('td', { class: 'nb' }, String(T.at || '—')), el('td', {})));
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Personne'), el('th', {}, 'Contrat'),
      el('th', { class: 'nb' }, 'Contrat'), el('th', { class: 'nb' }, 'Prévu'), el('th', { class: 'nb' }, 'Réalisé'),
      el('th', { class: 'nb', title: 'Réalisé moins prévu, sur les jours écoulés (jusqu\'à hier)' }, 'Écart *'),
      el('th', { class: 'nb' }, 'CP (j)'), el('th', { class: 'nb' }, 'AT (j)'), el('th', {}, 'Répartition du prévu'))), tb),
      el('p', { class: 'note-recap', style: 'padding:8px 10px' }, '* Écart = réalisé − prévu, sur les jours écoulés seulement. Contrat : heures hebdomadaires réparties du lundi au vendredi, selon l\'historique des contrats. Réalisé : heures saisies dans Suivi des temps.'));
    R.table = lignesCsv;
    resumeRecap(T.contrat, T.prevu, T.realise);
  }

  function groupeDe(tacheId) {
    const t = etat.ref.taches.find((x) => x.id === tacheId); if (!t) return null;
    const at = etat.ref.ateliers.find((a) => a.id === t.atelier_id);
    if (R.niveau === 'tache') return { id: 't' + t.id, nom: at.nom + ' › ' + t.nom, couleur: at.couleur };
    if (R.niveau === 'atelier') return { id: 'at' + at.id, nom: at.nom, couleur: at.couleur };
    if (R.niveau === 'activite') { const ac = etat.ref.activites.find((a) => a.id === at.activite_id); return { id: 'a' + ac.id, nom: ac.nom, couleur: null }; }
    const rg = etat.ref.regroupements.find((r) => r.id === t.regroupement_id);
    return rg ? { id: 'r' + rg.id, nom: rg.nom, couleur: null } : { id: 'r0', nom: 'Sans regroupement', couleur: null };
  }

  function dessinerRecapActivite() {
    const z = $('#r-contenu'); z.replaceChildren();
    const colonnes = cles();
    const groupes = new Map(); const totCol = {}; let total = 0, nbSeances = 0;
    for (const [d, tid, mo, n] of R.donnees.mo) {
      if (R.selection && !etat.selection.has(tid)) continue;
      const g = groupeDe(tid); if (!g) continue;
      if (!groupes.has(g.id)) groupes.set(g.id, Object.assign(g, { v: {}, tot: 0, n: 0 }));
      const x = groupes.get(g.id), k = cleDe(d);
      x.v[k] = (x.v[k] || 0) + +mo; x.tot += +mo; x.n += n; totCol[k] = (totCol[k] || 0) + +mo; total += +mo; nbSeances += n;
    }
    const lignesCsv = [['Groupe', ...colonnes.map(libelleCle), 'Total (h)', 'Séances']];
    if (!groupes.size) { z.append(el('p', { class: 'vide' }, 'Aucune séance prévue sur cette période' + (R.selection ? ' dans la sélection.' : '.'))); R.table = lignesCsv; resumeRecap(null, total, null, nbSeances); return; }
    const tb = el('tbody');
    for (const g of [...groupes.values()].sort((a, b) => b.tot - a.tot)) {
      tb.append(el('tr', {}, el('td', {}, el('span', { class: 'tache-nom' }, g.couleur ? el('span', { class: 'pastille', style: 'background:' + g.couleur }) : null, g.nom)),
        ...colonnes.map((k) => el('td', { class: 'nb' }, h2(g.v[k]))), el('td', { class: 'nb' }, el('strong', {}, heures(g.tot))), el('td', { class: 'nb' }, String(g.n))));
      lignesCsv.push([g.nom, ...colonnes.map((k) => g.v[k] || 0), g.tot, g.n]);
    }
    tb.append(el('tr', { class: 'total' }, el('td', {}, 'Total'), ...colonnes.map((k) => el('td', { class: 'nb' }, h2(totCol[k]))), el('td', { class: 'nb' }, heures(total)), el('td', { class: 'nb' }, String(nbSeances))));
    lignesCsv.push(['Total', ...colonnes.map((k) => totCol[k] || 0), total, nbSeances]);
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, { activite: 'Activité', atelier: 'Atelier', tache: 'Tâche', regroupement: 'Regroupement' }[R.niveau]),
      ...colonnes.map((k) => el('th', { class: 'nb' }, libelleCle(k))), el('th', { class: 'nb' }, 'Total'), el('th', { class: 'nb' }, 'Séances'))), tb),
      el('p', { class: 'note-recap', style: 'padding:8px 10px' }, 'Main-d\'œuvre prévue = durée × nombre de personnes, séances suspendues exclues.'));
    R.table = lignesCsv;
    resumeRecap(null, total, null, nbSeances);
  }

  function resumeRecap(contrat, prevu, realise, nbSeances) {
    const r = $('#r-resume'); r.replaceChildren(el('h2', {}, 'Du ' + D.long(R.debut) + ' au ' + D.long(R.fin)));
    const c = (lib, v) => r.append(el('span', { class: 'chiffre-r' }, lib + ' ', el('strong', {}, v)));
    if (R.onglet === 'personne') { c('Contrat', heures(contrat)); c('Prévu', heures(prevu)); c('Réalisé', heures(realise)); }
    else { c('Main-d\'œuvre prévue', heures(prevu)); c('Séances', String(nbSeances || 0)); }
  }

  function dessinerRecap() {
    const collab = etat.droits.niveau === 'collaborateur';
    if (collab) R.onglet = 'personne';
    $('#r-onglet-activite').hidden = collab;
    for (const b of document.querySelectorAll('[data-recap]')) b.classList.toggle('actif', b.dataset.recap === R.onglet);
    $('#r-periode').value = R.periode; $('#r-debut').value = R.debut; $('#r-fin').value = R.fin;
    $('#r-pas').value = R.pas; $('#r-niveau').value = R.niveau; $('#r-selection').checked = R.selection;
    $('#r-niveau-l').hidden = R.onglet !== 'activite';
    $('#r-recherche').hidden = R.onglet !== 'personne' || collab;
    $('#r-selection').parentElement.hidden = collab;
    if (!R.donnees || R.cle !== R.debut + '|' + R.fin) { chargerRecap(); return; }
    if (R.onglet === 'activite') dessinerRecapActivite(); else dessinerRecapPersonnes();
  }

  function garderRecap() {
    try { localStorage.setItem('planning_recap', JSON.stringify({ onglet: R.onglet, periode: R.periode, debut: R.debut, fin: R.fin, pas: R.pas, niveau: R.niveau, selection: R.selection })); } catch (e) { /* rien */ }
  }
  function initRecap() {
    try { Object.assign(R, JSON.parse(localStorage.getItem('planning_recap') || '{}')); } catch (e) { /* rien */ }
    if (R.periode !== 'perso' || !R.debut || !R.fin) { const b = bornesPeriode(R.periode === 'perso' ? 'mois' : R.periode); R.debut = b[0]; R.fin = b[1]; }
  }
  function exporterCsv() {
    if (!R.table) return;
    const cell = (v) => typeof v === 'number' ? String(Math.round(v * 100) / 100).replace('.', ',') : '"' + String(v).replace(/"/g, '""') + '"';
    const texte = '﻿' + R.table.map((l) => l.map(cell).join(';')).join('\r\n');
    const a = el('a', { href: URL.createObjectURL(new Blob([texte], { type: 'text/csv;charset=utf-8' })),
      download: 'recap-' + (R.onglet === 'activite' ? 'activite' : 'personnes') + '-' + R.debut + '-' + R.fin + '.csv' });
    document.body.append(a); a.click(); a.remove();
  }
  function brancherRecap() {
    for (const b of document.querySelectorAll('[data-recap]')) b.onclick = () => { R.onglet = b.dataset.recap; garderRecap(); dessinerRecap(); };
    $('#r-periode').onchange = (e) => { R.periode = e.target.value; if (R.periode !== 'perso') { [R.debut, R.fin] = bornesPeriode(R.periode); } garderRecap(); dessinerRecap(); };
    const dates = () => {
      const d = $('#r-debut').value, f = $('#r-fin').value; if (!d || !f) return;
      if (f < d) { dire('La fin de la période doit être après son début.', true); return; }
      R.debut = d; R.fin = f; R.periode = 'perso'; garderRecap(); dessinerRecap();
    };
    $('#r-debut').onchange = dates; $('#r-fin').onchange = dates;
    $('#r-pas').onchange = (e) => { R.pas = e.target.value; garderRecap(); dessinerRecap(); };
    $('#r-niveau').onchange = (e) => { R.niveau = e.target.value; garderRecap(); dessinerRecap(); };
    $('#r-selection').onchange = (e) => { R.selection = e.target.checked; garderRecap(); dessinerRecap(); };
    $('#r-recherche').oninput = (e) => { R.q = e.target.value; dessinerRecap(); };
    $('#r-csv').onclick = exporterCsv;
    $('#r-imprimer').onclick = () => window.print();
  }

  // Administration ----------------------------------------------------------------------------
  const A = { rubrique: 'referentiel', donnees: null, archives: false, q: '' };
  const lectureSeule = () => etat.droits.niveau !== 'complet';
  async function rechargerAdmin() {
    try {
      const [d, s] = await Promise.all([API.appeler('admin_lire'), API.appeler('session')]);
      A.donnees = d; etat.ref = s.referentiel; etat.droits = s.droits;
      etat.selection = new Set([...etat.selection].filter((id) => etat.ref.taches.some((t) => t.id === id)));
      dessinerSelection();
    } catch (e) { dire(e.message, true); }
    dessinerAdmin();
  }
  async function adminAgir(action, params, succes) {
    try { await API.appeler(action, params); if (succes) dire(succes); }
    catch (e) { dire(e.message, true); }
    await rechargerAdmin();
    chargerSemaine();
  }
  const nomPers = (id) => { const p = A.donnees.personnes.find((x) => x.id === id); return p ? p.prenom + ' ' + p.nom : '?'; };
  // Un champ texte qui enregistre quand on le quitte (ou sur Entrée), s'il a changé.
  function champNom(valeur, enregistrer, attrs) {
    const i = el('input', Object.assign({ type: 'text', value: valeur, disabled: lectureSeule() }, attrs || {}));
    const ok = () => { const v = i.value.trim(); if (v && v !== valeur) enregistrer(v); else i.value = valeur; };
    i.addEventListener('change', ok);
    i.addEventListener('keydown', (e) => { if (e.key === 'Enter') i.blur(); if (e.key === 'Escape') { i.value = valeur; i.blur(); } });
    return i;
  }
  function boutonArchive(type, x) {
    if (lectureSeule()) return null;
    return el('button', { type: 'button', class: 'bouton mini', onclick: () => adminAgir('ref_archiver', { type, id: x.id, archiver: !x.archive }, x.archive ? 'Rétabli.' : 'Archivé.') }, x.archive ? 'Rétablir' : 'Archiver');
  }
  function ajout(placeholder, creer) {
    if (lectureSeule()) return null;
    const i = el('input', { type: 'text', placeholder });
    const go = () => { const v = i.value.trim(); if (v) creer(v); };
    i.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    return el('div', { class: 'ref-ajout' }, i, el('button', { type: 'button', class: 'bouton mini', onclick: go }, 'Ajouter'));
  }

  function adminReferentiel(z) {
    const d = A.donnees; const vis = (x) => A.archives || !x.archive;
    const gauche = el('div', {}), droite = el('div', {});
    gauche.append(el('h3', {}, 'Activités, ateliers et tâches'));
    for (const ac of d.activites.filter(vis)) {
      const bloc = el('div', { class: 'ref-activite' + (ac.archive ? ' ref-archive' : '') },
        el('div', { class: 'ref-ligne' }, champNom(ac.nom, (v) => adminAgir('ref_enregistrer', { type: 'activite', id: ac.id, nom: v }, 'Activité renommée.'), { 'aria-label': 'Nom de l\'activité' }), boutonArchive('activite', ac)));
      for (const at of d.ateliers.filter((a) => a.activite_id === ac.id && vis(a))) {
        const soc = el('select', { 'aria-label': 'Société', disabled: lectureSeule(), onchange: (e) => adminAgir('ref_enregistrer', { type: 'atelier', id: at.id, societe: e.target.value }, 'Société changée (pour les séances créées désormais).') },
          ...d.societes.map((x) => el('option', { value: x.code, selected: x.code === at.societe }, x.code)));
        const coul = el('input', { type: 'color', value: at.couleur, disabled: lectureSeule(), 'aria-label': 'Couleur', onchange: (e) => adminAgir('ref_enregistrer', { type: 'atelier', id: at.id, couleur: e.target.value.toUpperCase() }) });
        const dem = el('label', { class: 'case petite', title: 'Coché d\'office dans la sélection d\'un nouvel utilisateur' },
          el('input', { type: 'checkbox', checked: at.au_demarrage, disabled: lectureSeule(), onchange: (e) => adminAgir('ref_enregistrer', { type: 'atelier', id: at.id, au_demarrage: e.target.checked }) }), 'sélection par défaut');
        const blocAt = el('div', { class: 'ref-atelier' + (at.archive ? ' ref-archive' : ''), style: 'border-left-color:' + at.couleur },
          el('div', { class: 'ref-ligne' }, coul, champNom(at.nom, (v) => adminAgir('ref_enregistrer', { type: 'atelier', id: at.id, nom: v }, 'Atelier renommé.'), { 'aria-label': 'Nom de l\'atelier' }), soc, dem, boutonArchive('atelier', at)));
        const lt = el('div', { class: 'ref-taches' });
        for (const t of d.taches.filter((x) => x.atelier_id === at.id && vis(x))) {
          const rg = el('select', { 'aria-label': 'Regroupement', disabled: lectureSeule(), onchange: (e) => adminAgir('ref_enregistrer', { type: 'tache', id: t.id, regroupement_id: e.target.value || null }) },
            el('option', { value: '' }, '— sans regroupement —'), ...d.regroupements.filter((r) => !r.archive || r.id === t.regroupement_id).map((r) => el('option', { value: r.id, selected: r.id === t.regroupement_id }, r.nom)));
          const dep = el('select', { 'aria-label': 'Atelier', disabled: lectureSeule(), title: 'Déplacer la tâche vers un autre atelier', onchange: (e) => { if (confirm('Déplacer « ' + t.nom + ' » vers l\'atelier « ' + e.target.selectedOptions[0].textContent + ' » ? Ses séances passées gardent leur société.')) adminAgir('ref_enregistrer', { type: 'tache', id: t.id, atelier_id: +e.target.value }, 'Tâche déplacée.'); else e.target.value = String(at.id); } },
            ...d.ateliers.filter((a) => !a.archive || a.id === at.id).map((a) => el('option', { value: a.id, selected: a.id === at.id }, a.nom)));
          lt.append(el('div', { class: 'ref-ligne' + (t.archive ? ' ref-archive' : '') },
            champNom(t.nom, (v) => adminAgir('ref_enregistrer', { type: 'tache', id: t.id, nom: v }, 'Tâche renommée.'), { 'aria-label': 'Nom de la tâche' }),
            rg, dep, el('span', { class: 'mini-info' }, t.seances + ' séance' + (t.seances > 1 ? 's' : '')), boutonArchive('tache', t)));
        }
        lt.append(ajout('Nouvelle tâche de « ' + at.nom + ' »', (v) => adminAgir('ref_enregistrer', { type: 'tache', atelier_id: at.id, nom: v }, 'Tâche créée.')));
        blocAt.append(lt); bloc.append(blocAt);
      }
      bloc.append(ajout('Nouvel atelier dans « ' + ac.nom + ' » (société SAS par défaut, modifiable ensuite)', (v) => adminAgir('ref_enregistrer', { type: 'atelier', activite_id: ac.id, nom: v, societe: 'SAS' }, 'Atelier créé.')));
      gauche.append(bloc);
    }
    gauche.append(ajout('Nouvelle activité', (v) => adminAgir('ref_enregistrer', { type: 'activite', nom: v }, 'Activité créée.')));
    droite.append(el('h3', {}, 'Regroupements'), el('p', { class: 'sous' }, 'Partagés entre ateliers : une tâche de n\'importe quel atelier peut y être rangée.'));
    for (const r of d.regroupements.filter(vis)) {
      droite.append(el('div', { class: 'ref-ligne' + (r.archive ? ' ref-archive' : '') },
        champNom(r.nom, (v) => adminAgir('ref_enregistrer', { type: 'regroupement', id: r.id, nom: v }, 'Regroupement renommé.')),
        el('span', { class: 'mini-info' }, ((n) => n + ' tâche' + (n > 1 ? 's' : ''))(d.taches.filter((t) => t.regroupement_id === r.id && !t.archive).length)), boutonArchive('regroupement', r)));
    }
    droite.append(ajout('Nouveau regroupement', (v) => adminAgir('ref_enregistrer', { type: 'regroupement', nom: v }, 'Regroupement créé.')));
    z.append(el('div', { class: 'ref-grille' }, gauche, droite));
  }

  function adminResponsables(z) {
    const d = A.donnees;
    const avecFiche = d.personnes.filter((p) => !p.sans_fiche).sort((a, b) => b.active - a.active || (a.prenom + a.nom).localeCompare(b.prenom + b.nom));
    const tb = el('tbody');
    for (const at of d.ateliers.filter((a) => !a.archive)) {
      const resp = d.responsables.filter((r) => r[0] === at.id).map((r) => r[1]);
      const ajouter = lectureSeule() ? null : el('select', { class: 'champ', 'aria-label': 'Ajouter un responsable à ' + at.nom, onchange: (e) => { if (e.target.value) adminAgir('responsable', { atelier_id: at.id, personne_id: +e.target.value }, 'Responsable ajouté.'); } },
        el('option', { value: '' }, '+ Ajouter…'), ...avecFiche.filter((p) => !resp.includes(p.id)).map((p) => el('option', { value: p.id }, p.prenom + ' ' + p.nom + (p.active ? '' : ' (inactif)'))));
      tb.append(el('tr', {},
        el('td', {}, el('span', { class: 'tache-nom' }, el('span', { class: 'pastille', style: 'background:' + at.couleur }), at.nom), el('div', { class: 'sous' }, at.societe)),
        el('td', {}, el('div', { class: 'ref-ligne' }, ...resp.map((pid) => el('span', { class: 'puce-p' }, nomPers(pid),
          lectureSeule() ? null : el('button', { type: 'button', 'aria-label': 'Retirer ' + nomPers(pid), onclick: () => adminAgir('responsable', { atelier_id: at.id, personne_id: pid, ajouter: false }, 'Responsable retiré.') }, '×'))),
          resp.length ? null : el('span', { class: 'sous' }, 'Aucun'), ajouter))));
    }
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Atelier'), el('th', {}, 'Responsables'))), tb));
  }

  function adminPersonnes(z) {
    const d = A.donnees;
    const q = A.q.trim().toLowerCase();
    const sans = d.personnes.filter((p) => p.sans_fiche && (A.archives || !p.archive) && (!q || (p.prenom + ' ' + p.nom).toLowerCase().includes(q)));
    const avecFiche = d.personnes.filter((p) => !p.sans_fiche).sort((a, b) => (a.prenom + a.nom).localeCompare(b.prenom + b.nom));
    if (!lectureSeule()) z.append(el('div', { class: 'boutons', style: 'margin:0 0 12px' }, el('button', { type: 'button', class: 'bouton principal', onclick: () => ouvrirPersonne() }, '+ Personne sans fiche')));
    if (!sans.length) { z.append(el('p', { class: 'vide' }, 'Aucune personne sans fiche.')); return; }
    const tb = el('tbody');
    for (const p of sans) {
      const sugg = (p.suggestions || []).map((id) => avecFiche.find((x) => x.id === id)).filter(Boolean);
      const cible = el('select', { class: 'champ', 'aria-label': 'Rattacher ' + p.prenom + ' à', disabled: lectureSeule() },
        el('option', { value: '' }, sugg.length ? '— choisir (suggestion ci-dessous) —' : '— choisir la personne qui a une fiche —'),
        sugg.length ? el('optgroup', { label: 'Même nom' }, ...sugg.map((x) => el('option', { value: x.id }, x.prenom + ' ' + x.nom + (x.active ? '' : ' (pas encore active)')))) : null,
        el('optgroup', { label: 'Toutes les personnes avec fiche' }, ...avecFiche.map((x) => el('option', { value: x.id }, x.prenom + ' ' + x.nom + (x.active ? '' : ' (inactive)')))));
      if (sugg.length === 1) cible.value = String(sugg[0].id);
      const nature = el('select', { class: 'champ', 'aria-label': 'Situation', disabled: lectureSeule(), onchange: (e) => adminAgir('personne_modifier', { personne_id: p.id, nature: e.target.value }) },
        el('option', { value: 'a_venir', selected: p.nature !== 'externe' }, 'À venir'), el('option', { value: 'externe', selected: p.nature === 'externe' }, 'Externe'));
      tb.append(el('tr', { class: p.archive ? 'ref-archive' : '' },
        el('td', {}, el('strong', {}, p.prenom + ' ' + p.nom), el('div', { class: 'sous' }, 'créée le ' + D.court((p.cree_le || '').slice(0, 10)))),
        el('td', {}, nature),
        el('td', { class: 'nb' }, String(p.seances)),
        el('td', {}, lectureSeule() ? null : el('div', { class: 'ref-ligne' }, cible, el('button', { type: 'button', class: 'bouton mini principal', onclick: () => {
          if (!cible.value) { dire('Choisis la personne qui a maintenant une fiche.', true); return; }
          const nomC = cible.selectedOptions[0].textContent;
          if (confirm('Rattacher « ' + p.prenom + ' ' + p.nom + ' » à « ' + nomC + ' » ?\n\nSes ' + p.seances + ' séance(s) passent sur cette personne et la personne provisoire disparaît. Ce n\'est pas réversible.')) adminAgir('personne_rattacher', { source: p.id, cible: +cible.value }, 'Rattachement fait.');
        } }, 'Rattacher'))),
        el('td', {}, lectureSeule() ? null : el('div', { class: 'ref-ligne' },
          el('button', { type: 'button', class: 'bouton mini', onclick: () => ouvrirPersonne(p) }, 'Renommer'),
          el('button', { type: 'button', class: 'bouton mini', onclick: () => adminAgir('personne_archiver', { personne_id: p.id, archiver: !p.archive }, p.archive ? 'Rétablie.' : 'Archivée : elle n\'est plus proposée.') }, p.archive ? 'Rétablir' : 'Archiver')))));
    }
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Personne'), el('th', {}, 'Situation'), el('th', { class: 'nb' }, 'Séances'), el('th', {}, 'Rattacher à sa fiche'), el('th', {}, ''))), tb));
  }

  function adminHabituels(z) {
    const d = A.donnees;
    const ateliers = d.ateliers.filter((a) => !a.archive);
    const q = A.q.trim().toLowerCase();
    const gens = d.personnes.filter((p) => (p.active || (p.sans_fiche && !p.archive)) && (!q || (p.prenom + ' ' + p.nom).toLowerCase().includes(q)));
    const peut = (at) => !lectureSeule() || etat.droits.ateliers.includes(at.id);
    const tb = el('tbody');
    for (const p of gens) {
      tb.append(el('tr', {}, el('td', {}, el('strong', {}, p.prenom + ' ' + p.nom), el('div', { class: 'sous' }, p.sans_fiche ? 'sans fiche' : (p.societes || []).join(' + '))),
        ...ateliers.map((at) => {
          const coche = d.habituels.some((h) => h[0] === p.id && h[1] === at.id);
          return el('td', { class: 'c' }, el('input', { type: 'checkbox', checked: coche, disabled: !peut(at), 'aria-label': p.prenom + ' ' + p.nom + ' · ' + at.nom,
            onchange: (e) => adminAgir('habituel', { personne_id: p.id, atelier_id: at.id, ajouter: e.target.checked }) }));
        })));
    }
    z.append(el('table', { class: 'matrice' }, el('thead', {}, el('tr', {}, el('th', {}, 'Personne'),
      ...ateliers.map((at) => el('th', { class: 'at' }, el('span', { class: 'pastille', style: 'background:' + at.couleur }), ' ', at.nom)))), tb));
  }

  function adminAcces(z) {
    const d = A.donnees;
    const q = A.q.trim().toLowerCase();
    const gens = d.personnes.filter((p) => p.active && (!q || (p.prenom + ' ' + p.nom).toLowerCase().includes(q)));
    const nomEl = (type, id) => { const l = { activite: d.activites, atelier: d.ateliers, regroupement: d.regroupements, tache: d.taches }[type]; const x = l.find((y) => y.id === id); return x ? x.nom : '?'; };
    const tb = el('tbody');
    for (const p of gens) {
      const hab = d.habituels.filter((h) => h[0] === p.id).map((h) => h[1]);
      const resp = d.responsables.filter((r) => r[1] === p.id).map((r) => r[0]);
      const defaut = [...new Set(hab.concat(resp))].map((id) => nomEl('atelier', id) + (resp.includes(id) ? ' (resp.)' : ''));
      const tout = (d.acces_tout || []).includes(p.id);
      const plus = (d.acces_elements || []).filter((e) => e[0] === p.id).map((e) => nomEl(e[1], e[2]));
      tb.append(el('tr', {},
        el('td', {}, el('strong', {}, p.prenom + ' ' + p.nom), el('div', { class: 'sous' }, (p.societes || []).join(' + '))),
        el('td', { class: 'acces-defaut' }, defaut.length ? defaut.join(', ') : el('span', { class: 'sous' }, 'ses séances seulement')),
        el('td', { class: 'acces-defaut' }, tout ? el('strong', {}, 'Tout le planning') : plus.length ? plus.join(', ') : '—'),
        el('td', {}, lectureSeule() ? null : el('button', { type: 'button', class: 'bouton mini', onclick: () => ouvrirAcces(p) }, 'Modifier'))));
    }
    z.append(el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Personne'), el('th', {}, 'Voit d\'office (ateliers habituels, responsable)'), el('th', {}, 'Ouvert en plus'), el('th', {}, ''))), tb));
  }
  let accesEdite = null;
  function ouvrirAcces(p) {
    accesEdite = p;
    const d = A.donnees;
    $('#dlg-acces-titre').textContent = 'Accès de ' + p.prenom + ' ' + p.nom;
    const elts = new Set((d.acces_elements || []).filter((e) => e[0] === p.id).map((e) => e[1] + ':' + e[2]));
    const tout = $('#fa-tout'); tout.checked = (d.acces_tout || []).includes(p.id);
    const arbre = $('#fa-arbre'); arbre.replaceChildren();
    const caseA = (type, id, nom) => el('label', {}, el('input', { type: 'checkbox', value: type + ':' + id, checked: elts.has(type + ':' + id) }), nom);
    const ateliers = d.ateliers.filter((a) => !a.archive);
    arbre.append(el('div', { class: 'sel-carte' }, el('label', {}, 'Activités entières'), el('div', { class: 'sel-taches' }, ...d.activites.filter((a) => !a.archive).map((a) => caseA('activite', a.id, a.nom)))));
    arbre.append(el('div', { class: 'sel-carte' }, el('label', {}, 'Regroupements'), el('div', { class: 'sel-taches' }, ...d.regroupements.filter((a) => !a.archive).map((a) => caseA('regroupement', a.id, a.nom)))));
    for (const at of ateliers) {
      arbre.append(el('div', { class: 'sel-carte', style: '--c:' + at.couleur }, caseA('atelier', at.id, at.nom),
        el('div', { class: 'sel-taches' }, ...d.taches.filter((t) => t.atelier_id === at.id && !t.archive).map((t) => caseA('tache', t.id, t.nom)))));
    }
    const griser = () => arbre.classList.toggle('grise', tout.checked);
    tout.onchange = griser; griser();
    $('#dlg-acces').showModal();
  }
  function validerAcces() {
    const elements = [...$('#fa-arbre').querySelectorAll('input:checked')].map((c) => { const [t, i] = c.value.split(':'); return [t, +i]; });
    adminAgir('acces_regler', { personne_id: accesEdite.id, tout: $('#fa-tout').checked, elements }, 'Accès de ' + accesEdite.prenom + ' enregistrés.');
  }

  const AIDES = {
    referentiel: 'Un nom se modifie en cliquant dessus (Entrée pour valider). Ce qui a servi s\'archive au lieu de se supprimer : l\'historique reste intact. Changer la société d\'un atelier ne touche que les séances créées ensuite.',
    responsables: 'Un responsable crée et modifie les séances de ses ateliers, avec son propre lien de Suivi des temps.',
    personnes: 'Quand la fiche d\'une personne à venir est créée dans Suivi des temps, rattache-la ici : toutes ses séances passent sur sa fiche.',
    acces: 'Chaque collaborateur ou responsable voit toujours ses propres séances, plus les ateliers dont il est habituel ou responsable. Ouvre-lui ici d\'autres activités, ateliers, tâches ou regroupements, ou tout le planning. Accès complets et consultation voient tout.',
    habituels: 'Les ateliers habituels d\'une personne la font apparaître dans le volet « Personnes » quand ces ateliers sont sélectionnés. Ce n\'est pas une restriction.',
  };
  function dessinerAdmin() {
    for (const b of document.querySelectorAll('[data-admin]')) b.classList.toggle('actif', b.dataset.admin === A.rubrique);
    $('#a-aide').textContent = AIDES[A.rubrique];
    $('#a-archives-l').hidden = !['referentiel', 'personnes'].includes(A.rubrique);
    $('#a-recherche').hidden = !['personnes', 'habituels', 'acces'].includes(A.rubrique);
    const z = $('#a-contenu'); z.replaceChildren();
    if (!A.donnees) { z.append(el('p', { class: 'vide' }, 'Chargement…')); rechargerAdmin(); return; }
    ({ referentiel: adminReferentiel, responsables: adminResponsables, personnes: adminPersonnes, habituels: adminHabituels, acces: adminAcces })[A.rubrique](z);
  }

  // Personne sans fiche : création (volet ou administration) et renommage.
  let personneEditee = null;
  function ouvrirPersonne(p) {
    personneEditee = p || null;
    $('#dlg-personne-titre').textContent = p ? 'Renommer' : 'Nouvelle personne sans fiche';
    $('#fp-valider').textContent = p ? 'Enregistrer' : 'Créer';
    $('#fp-prenom').value = p ? p.prenom : ''; $('#fp-nom').value = p ? p.nom : '';
    for (const r of document.querySelectorAll('[name=fp-nature]')) r.checked = r.value === ((p && p.nature) || 'a_venir');
    $('#dlg-personne').showModal();
  }
  async function validerPersonne() {
    const q = { prenom: $('#fp-prenom').value.trim(), nom: $('#fp-nom').value.trim(), nature: document.querySelector('[name=fp-nature]:checked').value };
    if (!q.prenom) { dire('Le prénom est obligatoire.', true); return; }
    if (personneEditee) { await adminAgir('personne_modifier', Object.assign({ personne_id: personneEditee.id }, q), 'Personne modifiée.'); return; }
    const r = await agir('personne_creer', q, q.prenom + ' est créé·e : glisse son nom sur une séance.');
    if (r && etat.vue === 'admin') rechargerAdmin();
  }
  function brancherAdmin() {
    for (const b of document.querySelectorAll('[data-admin]')) b.onclick = () => { A.rubrique = b.dataset.admin; dessinerAdmin(); };
    $('#a-archives').onchange = (e) => { A.archives = e.target.checked; dessinerAdmin(); };
    $('#a-recherche').oninput = (e) => { A.q = e.target.value; dessinerAdmin(); };
    $('#btn-personne').onclick = () => ouvrirPersonne();
    $('#dlg-acces').addEventListener('close', () => { if ($('#dlg-acces').returnValue === 'ok') validerAcces(); });
    $('#dlg-personne').addEventListener('close', () => { if ($('#dlg-personne').returnValue === 'ok') validerPersonne(); });
  }

  // Personnes ------------------------------------------------------------------------------
  // Personnes « de la sélection » : une fiche dans la société d'un atelier coché, un atelier
  // habituel coché, déjà prévue cette semaine sur la sélection, ou externe.
  function dansSelection(p, ateliers) {
    const societes = new Set(etat.ref.ateliers.filter((a) => ateliers.has(a.id)).map((a) => a.societe));
    if (p.externe) return true;
    if (p.fiches.some((f) => societes.has(f.societe))) return true;
    if (p.ateliers_habituels.some((a) => ateliers.has(a))) return true;
    return etat.sem.seances.some((s) => visible(s) && s.personnes.some((x) => x.personne_id === p.id));
  }

  // La grille remplit la hauteur de l'écran : une heure fait au moins 40 px.
  function pixelsParMinute(minutes) {
    const cadre = $('#grille-cadre');
    if (window.innerWidth <= 720 || !cadre) return 52 / 60;
    const dispo = cadre.clientHeight - 64;  // moins l'en-tête des jours
    return Math.max(40 / 60, dispo / minutes);
  }

  function dessinerPersonnes() {
    const zone = $('#personnes'); zone.replaceChildren();
    const q = etat.recherche.trim().toLowerCase();
    const ateliers = ateliersSelectionnes();
    const liste = etat.sem.personnes.filter((p) => (!q || (p.prenom + ' ' + p.nom).toLowerCase().includes(q))
      && (etat.toutLeMonde || etat.vue === 'personne' || dansSelection(p, etat.vue === 'activite' ? new Set(etat.ref.taches.filter((t) => tachesCible().includes(t.id)).map((t) => t.atelier_id)) : ateliers)));
    for (const p of liste) {
      const contrat = p.externe ? (p.nature === 'a_venir' ? 'À venir · sans fiche' : 'Externe · sans fiche') : p.fiches.map((f) => `${f.contrat}${f.heures_hebdo ? ' ' + f.heures_hebdo + ' h' : ''} · ${f.societe}`).join(' + ');
      const ref = p.fiches.reduce((a, f) => a + (+f.heures_hebdo || 0), 0);
      const pct = ref ? Math.min(100, (p.prevu_h / ref) * 100) : 0;
      const courante = etat.vue === 'personne' && p.id === etat.personne;
      const ligne = el('div', { class: 'personne' + (courante ? ' courante' : ''), draggable: peutEcrire() ? 'true' : null, title: peutEcrire() ? 'Glisser sur une séance' : null },
        peutEcrire() ? el('span', { class: 'poignee', 'aria-hidden': 'true' }, '⋮⋮') : null,
        el('div', { style: 'flex:1;min-width:0' }, el('button', { type: 'button', class: 'nom', title: 'Voir son planning', onclick: () => changerVue('personne', p.id) }, p.prenom + ' ' + p.nom), el('div', { class: 'contrat' }, contrat)),
        el('div', { class: 'jauge' }, el('div', { class: 'mono' }, ref ? heures(p.prevu_h) + ' / ' + ref : heures(p.prevu_h)),
          el('div', { class: 'barre-j' }, el('div', { class: p.prevu_h > ref && ref ? 'depasse' : '', style: 'width:' + pct + '%' }))));
      if (peutEcrire()) ligne.addEventListener('dragstart', (ev) => { ev.dataTransfer.setData('application/x-personne', String(p.id)); ev.dataTransfer.effectAllowed = 'copy'; });
      zone.append(ligne);
    }
    if (!liste.length) zone.append(el('p', { class: 'aide' }, 'Personne ne correspond.'));
  }

  // Détail d'une séance ----------------------------------------------------------------------
  function dessinerDetail() {
    const z = $('#detail');
    const s = etat.sem && etat.sem.seances.find((x) => x.id === etat.choisie);
    if (!s) { z.hidden = true; return; }
    z.hidden = false; z.replaceChildren();
    const edit = peutAtelier(s.atelier_id);
    const duree = s.duree_h;
    z.append(
      el('div', { class: 'carte-entete' }, el('span', { class: 'sous' }, 'Séance'), el('button', { class: 'lien', onclick: () => { etat.choisie = null; dessiner(); } }, 'Fermer')),
      el('span', { class: 'puce', style: `background:${teinte(s.couleur, 0.16)};border-color:${s.couleur}` }, s.atelier + (s.regroupement ? ' › ' + s.regroupement : '')),
      el('h3', { class: 'detail-titre' }, nomSeance(s)),
      el('div', { class: 'sous' }, D.long(s.date_seance) + ' · ', el('span', { class: 'mono' }, court5(s.heure_debut) + ' – ' + court5(s.heure_fin)), s.lieu ? ' · ' + s.lieu : ''),
      el('div', { class: 'chiffres' },
        el('div', { class: 'chiffre' }, el('div', { class: 'sous' }, 'Durée'), el('div', { class: 'v' }, heures(duree))),
        el('div', { class: 'chiffre' }, el('div', { class: 'sous' }, 'Main-d\'œuvre'), el('div', { class: 'v' }, s.statut === 'prevue' ? heures(s.main_oeuvre_h) : 'Non comptée'),
          el('div', { class: 'sous' }, s.statut === 'prevue' ? heures(duree) + ' × ' + s.nb_personnes : s.motif || 'Suspendue'))),
    );
    if (s.deplacee) z.append(el('div', { class: 'note-bloc gris' }, 'Déplacée depuis le ' + D.long(s.date_serie) + '. Les autres séances de la série ne changent pas.'));
    if (s.statut === 'suspendue') z.append(el('div', { class: 'note-bloc gris' }, 'Suspendue' + (s.motif ? ' : ' + s.motif : '') + '. Ces heures ne sont pas comptées.'));
    const conflits = new Set(s.chevauchements || []);
    if (conflits.size) z.append(el('div', { class: 'note-bloc rouge' }, el('strong', {}, 'Chevauchement. '), 'Une personne est prévue ailleurs au même moment. C\'est un signalement, pas un blocage.'));

    // Personnes
    z.append(el('div', { style: 'font-weight:600;font-size:14px;margin-top:10px' }, s.nb_personnes + (s.nb_personnes > 1 ? ' personnes' : ' personne')));
    const lp = el('div', { class: 'liste-pers' });
    for (const p of s.personnes) {
      lp.append(el('div', { class: 'ligne-pers' },
        el('span', {}, p.prenom + ' ' + p.nom),
        p.mad ? el('span', { class: 'etiquette' }, 'mise à disposition') : null,
        !p.collab_id ? el('span', { class: 'etiquette sans-fiche' }, 'sans fiche') : null,
        conflits.has(p.personne_id) ? el('span', { class: 'note' }, 'prévue ailleurs') : null,
        edit ? el('button', { class: 'bouton mini retirer', 'aria-label': 'Retirer ' + p.prenom, onclick: () => agir('retirer', { seance_id: s.id, personne_id: p.personne_id }, 'Personne retirée.') }, 'Retirer') : null));
    }
    z.append(lp);
    if (edit) z.append(el('div', { class: 'boutons' }, el('button', { class: 'bouton principal', onclick: () => ouvrirSeance(s) }, 'Modifier')));
  }

  // Nouvelle séance ------------------------------------------------------------------------
  // Fenêtre séance. modele : séance à dupliquer ; edition : séance à modifier.
  let enEdition = null;
  function ouvrirSeance(s) { ouvrirNouvelle(s, true); }
  function ouvrirNouvelle(modele, edition) {
    enEdition = edition ? modele : null;
    const sel = $('#f-tache'); sel.replaceChildren();
    for (const at of etat.ref.ateliers.filter((a) => peutAtelier(a.id) || (modele && a.id === modele.atelier_id))) {
      const og = el('optgroup', { label: at.nom });
      etat.ref.taches.filter((t) => t.atelier_id === at.id).forEach((t) => og.append(el('option', { value: t.id }, t.nom)));
      if (og.children.length) sel.append(og);
    }
    const jour = D.aujourdhui() >= etat.lundi && D.aujourdhui() <= D.ajout(etat.lundi, 6) ? D.aujourdhui() : etat.lundi;
    $('#dlg-seance-titre').textContent = edition ? 'Modifier la séance' : modele ? 'Dupliquer la séance' : 'Nouvelle séance';
    $('#f-valider').textContent = edition ? 'Enregistrer' : 'Créer';
    const info = $('#f-serie-info');
    info.hidden = true;
    if (edition && modele.serie_id) info.textContent = 'Séance d\'une série hebdomadaire : à l\'enregistrement, tu choisiras « cette séance » ou « et les suivantes ».';
    const enSerie = !!(edition && modele.serie_id);
    if (modele) sel.value = String(modele.tache_id);
    const date = modele ? modele.date_seance : jour;
    $('#f-date').value = date;
    remplirHeure($('#f-debut'), modele ? court5(modele.heure_debut) : '09:00'); remplirHeure($('#f-fin'), modele ? court5(modele.heure_fin) : '12:00');
    $('#f-titre').value = modele ? modele.complement || '' : ''; $('#f-lieu').value = modele ? modele.lieu || '' : ''; $('#f-recurrente').checked = enSerie; $('#f-recurrente').disabled = enSerie; $('#f-recurrence').hidden = !enSerie;
    $('#f-date-fin').value = enSerie ? modele.serie_fin || '' : '';
    $('#f-intervalle').value = String(enSerie ? modele.serie_intervalle || 1 : 1);
    const ri = $('#f-rep-info'); ri.hidden = !enSerie;
    ri.textContent = 'Changer le rythme, les jours ou la fin s\'applique à cette séance et aux suivantes. Pour arrêter la série : « Arrêter la série ici ».';
    const j = $('#f-jours'); j.replaceChildren();
    JOURS.forEach((n, i) => j.append(el('label', {}, el('input', { type: 'checkbox', value: i + 1, checked: enSerie ? modele.serie_jours.includes(i + 1) : false }), n)));
    const fp = $('#f-personnes'); fp.replaceChildren();
    const reprises = new Set(modele ? modele.personnes.map((p) => p.personne_id) : []);
    const compter = () => { const n = personnesCochees().length; $('#f-nb-pers').textContent = n ? '(' + n + ')' : ''; };
    const caseP = (id, nom) => el('label', {}, el('input', { type: 'checkbox', value: id, checked: reprises.has(id), onchange: compter }), nom);
    etat.sem.personnes.forEach((p) => fp.append(caseP(p.id, p.prenom + ' ' + p.nom)));
    // Une personne affectée mais absente de la liste (fiche inactive…) n'est pas perdue.
    if (modele) modele.personnes.filter((p) => !etat.sem.personnes.some((x) => x.id === p.personne_id))
      .forEach((p) => fp.append(caseP(p.personne_id, p.prenom + ' ' + p.nom)));
    compter();
    dessinerActionsSeance(edition ? modele : null);
    $('#dlg-seance').showModal();
  }
  const personnesCochees = () => [...$('#f-personnes').querySelectorAll('input:checked')].map((c) => +c.value);
  // Actions d'une séance existante, en bas de la fenêtre.
  function dessinerActionsSeance(s) {
    const z = $('#f-actions'); z.replaceChildren(); z.hidden = !s;
    if (!s) return;
    const fermerPuis = (f) => () => { $('#dlg-seance').close('annuler'); f(); };
    z.append(
      el('button', { type: 'button', class: 'bouton', onclick: fermerPuis(() => ouvrirNouvelle(s)) }, 'Dupliquer'),
      s.statut === 'prevue'
        ? el('button', { type: 'button', class: 'bouton', onclick: fermerPuis(() => { const motif = prompt('Motif de la suspension (facultatif) :', ''); if (motif !== null) agir('suspendre', { seance_id: s.id, motif }, 'Séance suspendue.'); }) }, 'Suspendre')
        : el('button', { type: 'button', class: 'bouton', onclick: fermerPuis(() => agir('reprendre', { seance_id: s.id }, 'Séance rétablie.')) }, 'Rétablir'),
      el('button', { type: 'button', class: 'bouton danger', onclick: fermerPuis(() => {
        const msg = 'Supprimer la séance du ' + D.long(s.date_seance) + ' ?' + (s.serie_id ? ' Les autres séances de la série ne changent pas.' : '');
        if (confirm(msg)) { etat.choisie = null; agir('seance_supprimer', { seance_id: s.id }, 'Séance supprimée.'); }
      }) }, 'Supprimer'),
      s.serie_id ? el('button', { type: 'button', class: 'bouton danger', onclick: fermerPuis(() => {
        if (confirm('Arrêter la série : plus aucune séance à partir du ' + D.long(s.date_serie) + ' ? Les séances passées restent.')) agir('serie_arreter', { serie_id: s.serie_id, date_fin: D.ajout(s.date_serie, -1) }, 'Série arrêtée.');
      }) }, 'Arrêter la série ici') : '');
  }
  async function validerModification(s) {
    const debut = $('#f-debut').valeur, fin = $('#f-fin').valeur;
    if (fin <= debut) { dire('La fin doit être après le début.', true); return; }
    const q = { seance_id: s.id, tache_id: +$('#f-tache').value, date: $('#f-date').value, debut, fin,
      titre: $('#f-titre').value.trim(), lieu: $('#f-lieu').value.trim(),
      personnes: personnesCochees() };
    const nomT = $('#f-tache').selectedOptions[0].textContent + (q.titre ? ' · ' + q.titre : '');
    let portee = null;
    const jours = [...$('#f-jours').querySelectorAll('input:checked')].map((c) => +c.value);
    const finSerie = $('#f-date-fin').value || null;
    if ($('#f-recurrente').checked) {
      if (!jours.length) { dire('Choisis au moins un jour.', true); return; }
      if (finSerie && finSerie < q.date) { dire('La fin de la série doit être après la date de la séance.', true); return; }
      const intervalle = +$('#f-intervalle').value;
      const avant = s.serie_id ? s.serie_jours.join(',') + '|' + (s.serie_fin || '') + '|' + (s.serie_intervalle || 1) : '';
      if (!s.serie_id || jours.join(',') + '|' + (finSerie || '') + '|' + intervalle !== avant) {
        // Nouvelle série, ou rythme / jours / fin changés : vaut pour cette séance et les suivantes.
        Object.assign(q, { jours, date_fin_serie: finSerie, intervalle }); portee = 'suivantes';
      }
    }
    if (!portee) portee = s.serie_id ? await demanderPortee(`${nomT} : ${D.long(q.date)}, ${debut}–${fin}`) : 'seance';
    if (!portee) return;
    etat.choisie = s.id;
    await agir('seance_modifier', Object.assign(q, { portee }), q.jours && !s.serie_id ? 'Série créée à partir de la séance.' : 'Séance modifiée.');
  }
  async function validerNouvelle() {
    const debut = $('#f-debut').valeur, fin = $('#f-fin').valeur;
    if (!debut || !fin || fin <= debut) { dire('La fin doit être après le début.', true); return; }
    const commun = { tache_id: +$('#f-tache').value, debut, fin, titre: $('#f-titre').value, lieu: $('#f-lieu').value,
      personnes: personnesCochees() };
    if ($('#f-recurrente').checked) {
      const jours = [...$('#f-jours').querySelectorAll('input:checked')].map((c) => +c.value);
      if (!jours.length) { dire('Choisis au moins un jour.', true); return; }
      await agir('serie_creer', Object.assign(commun, { jours, intervalle: +$('#f-intervalle').value, date_debut: $('#f-date').value, date_fin: $('#f-date-fin').value || null }), 'Série créée.');
    } else {
      await agir('seance_creer', Object.assign(commun, { date: $('#f-date').value }), 'Séance créée.');
    }
  }

  // Événements -----------------------------------------------------------------------------
  function brancher() {
    $('#prec').onclick = () => { etat.lundi = D.ajout(etat.lundi, -7); chargerSemaine(); };
    $('#suiv').onclick = () => { etat.lundi = D.ajout(etat.lundi, 7); chargerSemaine(); };
    $('#auj').onclick = () => { etat.lundi = D.lundiDe(D.aujourdhui()); chargerSemaine(); };
    $('#dimanche').onchange = (e) => { etat.dimanche = e.target.checked; try { localStorage.setItem('planning_dimanche', etat.dimanche ? '1' : '0'); } catch (x) { /* rien */ } dessiner(); };
    $('#btn-selection').onclick = () => { const p = $('#panneau-selection'); p.hidden = !p.hidden; $('#btn-selection').setAttribute('aria-expanded', String(!p.hidden)); };
    $('#sel-tout').onclick = () => { etat.selection = new Set(etat.ref.taches.map((t) => t.id)); garderSelection(); dessinerSelection(); dessiner(); };
    $('#sel-rien').onclick = () => { etat.selection = new Set(); garderSelection(); dessinerSelection(); dessiner(); };
    $('#btn-imprimer').onclick = () => window.print();
    for (const b of document.querySelectorAll('[data-vue]')) b.onclick = () => changerVue(b.dataset.vue);
    $('#choix').onchange = (e) => { if (e.target.value) changerVue(etat.vue, e.target.value); };
    brancherVolet();
    brancherRecap();
    brancherAdmin();
    $('#btn-nouvelle').onclick = () => ouvrirNouvelle();
    $('#f-recurrente').onchange = (e) => { $('#f-recurrence').hidden = !e.target.checked; };
    $('#dlg-seance').addEventListener('close', () => { if ($('#dlg-seance').returnValue !== 'ok') return; if (enEdition) validerModification(enEdition); else validerNouvelle(); });
    $('#recherche').oninput = (e) => { etat.recherche = e.target.value; dessinerPersonnes(); };
    $('#filtre-habituels').onchange = (e) => { etat.toutLeMonde = e.target.checked; dessinerPersonnes(); };
    // La grille occupe toute la place restante (CSS) ; quand sa hauteur change (fenêtre, panneau
    // Sélection, message), on redessine pour que les heures la remplissent.
    let hauteurVue = 0, attente;
    new ResizeObserver(() => {
      const h = $('#grille-cadre').clientHeight;
      if (Math.abs(h - hauteurVue) < 4) return;
      hauteurVue = h; clearTimeout(attente); attente = setTimeout(dessiner, 80);
    }).observe($('#grille-cadre'));
    $('#btn-fermer').onclick = () => {
      const sel = $('#fj-societe');
      if (sel.options.length === 1) [...new Set(etat.ref.ateliers.map((a) => a.societe))].forEach((s) => sel.append(el('option', { value: s }, s)));
      $('#fj-date').value = etat.lundi; $('#fj-motif').value = '';
      $('#dlg-fermer').showModal();
    };
    $('#dlg-fermer').addEventListener('close', () => {
      if ($('#dlg-fermer').returnValue !== 'ok') return;
      agir('jour_fermer', { date: $('#fj-date').value, societe: $('#fj-societe').value || null, motif: $('#fj-motif').value }, 'Journée fermée.');
    });
  }

  // Volet droit : largeur réglable au glisser, masquable ; réglages gardés dans ce navigateur.
  function brancherVolet() {
    const racine = document.documentElement, volet = $('#volet'), sep = $('#separateur'), btn = $('#btn-volet');
    const lire = (k, d) => { try { return localStorage.getItem(k) ?? d; } catch (e) { return d; } };
    const ecrire = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* rien */ } };
    const appliquer = (masque) => {
      volet.hidden = masque; sep.hidden = masque;
      btn.textContent = masque ? 'Afficher le volet' : 'Masquer le volet';
      btn.setAttribute('aria-expanded', String(!masque));
    };
    const largeur = (px) => {
      const max = Math.max(260, Math.round(window.innerWidth * 0.5));
      const l = Math.max(240, Math.min(max, px));
      racine.style.setProperty('--largeur-volet', l + 'px');
      return l;
    };
    largeur(+lire('planning_volet_largeur', 320));
    appliquer(lire('planning_volet_masque', '0') === '1');
    btn.onclick = () => { const m = !volet.hidden; appliquer(m); ecrire('planning_volet_masque', m ? '1' : '0'); };
    sep.addEventListener('pointerdown', (ev) => {
      ev.preventDefault(); sep.setPointerCapture(ev.pointerId); sep.classList.add('actif');
      const bougerVers = (e) => largeur(window.innerWidth - e.clientX - 24);
      const fin = (e) => { sep.classList.remove('actif'); sep.removeEventListener('pointermove', bougerVers); sep.removeEventListener('pointerup', fin);
        ecrire('planning_volet_largeur', String(largeur(window.innerWidth - e.clientX - 24))); };
      sep.addEventListener('pointermove', bougerVers); sep.addEventListener('pointerup', fin);
    });
    sep.addEventListener('keydown', (ev) => {
      const cur = parseInt(getComputedStyle(racine).getPropertyValue('--largeur-volet'), 10) || 320;
      if (ev.key === 'ArrowLeft') ecrire('planning_volet_largeur', String(largeur(cur + 20)));
      if (ev.key === 'ArrowRight') ecrire('planning_volet_largeur', String(largeur(cur - 20)));
    });
  }

  brancher();
  demarrer();
})();

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
  const teinte = (hex, a) => hex + Math.round(a * 255).toString(16).padStart(2, '0');

  const etat = {
    droits: null, ref: null, lundi: D.lundiDe(D.aujourdhui()), sem: null,
    selection: null, dimanche: false, choisie: null, recherche: '', toutLeMonde: false,
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
    return el('label', {}, c, pastille ? el('span', { class: 'pastille', style: 'background:' + pastille }) : null, libelle + (ids.length === 0 ? ' (aucune tâche)' : ''));
  }
  function dessinerSelection() {
    const arbre = $('#arbre'); arbre.replaceChildren();
    for (const ac of etat.ref.activites) {
      const bloc = el('div', { class: 'racine' }, caseGroupe(tachesActivite(ac.id), ac.nom));
      for (const at of etat.ref.ateliers.filter((a) => a.activite_id === ac.id)) {
        const n = el('div', { class: 'noeud' }, caseGroupe(tachesAtelier(at.id), at.nom + ' · ' + at.societe, at.couleur));
        for (const t of etat.ref.taches.filter((x) => x.atelier_id === at.id)) n.append(el('div', { class: 'noeud' }, caseGroupe([t.id], t.nom)));
        bloc.append(n);
      }
      arbre.append(bloc);
    }
    const rg = $('#regroupements'); rg.replaceChildren();
    for (const r of etat.ref.regroupements) rg.append(el('div', { class: 'racine' }, caseGroupe(tachesRegroupement(r.id), r.nom)));
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
    try { etat.dimanche = localStorage.getItem('planning_dimanche') === '1'; } catch (e) { /* rien */ }
    $('#dimanche').checked = etat.dimanche;
    const libelles = { complet: 'Accès complet', consultation: 'Consultation', responsable: 'Responsable d\'atelier', collaborateur: 'Lecture' };
    $('#qui').textContent = libelles[etat.droits.niveau] || '';
    $('#btn-nouvelle').hidden = !peutEcrire();
    $('#btn-fermer').hidden = etat.droits.niveau !== 'complet';
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

  // Grille ---------------------------------------------------------------------------------
  const visible = (s) => etat.selection.has(s.tache_id);
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
    const nbJ = joursAffiches();
    const dates = Array.from({ length: nbJ }, (_, i) => D.ajout(etat.lundi, i));
    $('#titre-semaine').textContent = 'Semaine ' + D.numSemaine(etat.lundi);
    $('#dates-semaine').textContent = 'du ' + D.long(etat.lundi) + ' au ' + D.long(D.ajout(etat.lundi, 6));

    const seances = sem.seances.filter(visible);
    // Une séance déplacée laisse une trace à sa date d'origine si celle-ci est dans la semaine.
    const blocs = [];
    for (const s of seances) {
      if (!s.trace) blocs.push({ s, date: s.date_seance, trace: false });
      if (s.deplacee && s.date_serie >= etat.lundi && s.date_serie <= D.ajout(etat.lundi, 6)) blocs.push({ s, date: s.date_serie, trace: true });
    }
    const [hMin, hMax] = bornes(seances);
    const pxMin = pixelsParMinute(hMax - hMin);
    const hauteur = (hMax - hMin) * pxMin;

    const g = $('#grille'); g.replaceChildren();
    g.style.gridTemplateColumns = '56px repeat(' + nbJ + ', minmax(0, 1fr))';
    g.append(el('div', { class: 'entete-jour', style: 'border-left:0' }));
    const fermes = sem.jours_fermes || [];
    for (const [i, d] of dates.entries()) {
      const f = fermes.find((x) => x.date === d);
      const mo = seances.filter((s) => !s.trace && s.date_seance === d).reduce((a, s) => a + s.main_oeuvre_h, 0);
      g.append(el('div', { class: 'entete-jour' + (f ? ' ferme' : '') },
        el('div', {}, el('span', { class: 'nom' }, JOURS[i]), ' ', el('span', { class: 'sous' }, D.court(d))),
        el('div', { class: 'mo mono' }, f ? '0 h · fermé' : heures(mo) + ' de MO'),
        f ? el('div', { class: 'badge-ferme' }, (f.societe ? f.societe + ' · ' : '') + (f.motif || 'Fermé')) : null));
    }
    const colH = el('div', { class: 'col-heures', style: 'height:' + hauteur + 'px' });
    for (let m = hMin; m < hMax; m += 60) colH.append(el('div', { class: 'libelle-heure mono', style: 'top:' + ((m - hMin) * pxMin + (m === hMin ? 7 : 0)) + 'px' }, hhmm(m)));
    g.append(colH);

    for (const d of dates) {
      const f = fermes.find((x) => x.date === d && !x.societe);
      const col = el('div', { class: 'col-jour' + (f ? ' ferme' : ''), style: 'height:' + hauteur + 'px', 'data-date': d });
      for (let m = hMin + 15; m < hMax; m += 15) col.append(el('div', { class: 'ligne-heure' + (m % 60 === 0 ? '' : m % 30 === 0 ? ' demi' : ' quart'), style: 'top:' + (m - hMin) * pxMin + 'px' }));
      for (const c of couloirs(blocs.filter((b) => b.date === d).map((b) => Object.assign({}, b.s, { _trace: b.trace })))) {
        col.append(blocSeance(c.s, c.couloir, c.nb, hMin, pxMin));
      }
      if (peutEcrire()) brancherDepot(col, hMin, pxMin);
      g.append(col);
    }
    dessinerLegende(seances);
    dessinerPersonnes();
    dessinerDetail();
  }

  function blocSeance(s, couloir, nb, hMin, pxMin) {
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
      style: `top:${haut + 1}px;height:${Math.max(h - 2, 18)}px;left:calc(${(couloir * 100) / nb}% + 3px);width:calc(${100 / nb}% - 6px);background:${teinte(s.couleur, 0.16)};border-color:${s.couleur};color:#1B211E`,
      'aria-label': `${s.titre}, ${D.long(trace ? s.date_serie : s.date_seance)}, ${court5(s.heure_debut)} à ${court5(s.heure_fin)}, ${s.personnes.map(nomP).join(', ') || 'personne'}`,
      draggable: modifiable ? 'true' : null,
      'data-seance': s.id,
      onclick: () => { etat.choisie = s.id; dessiner(); },
    },
      el('span', { class: 't' }, s.titre),
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
      const portee = s.serie_id ? await demanderPortee(`${s.titre} : ${D.long(date)}, ${hhmm(debut)}–${hhmm(debut + duree)}`) : 'seance';
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
    const parAtelier = new Map();
    for (const s of seances.filter((x) => !x.trace)) parAtelier.set(s.atelier_id, (parAtelier.get(s.atelier_id) || 0) + s.main_oeuvre_h);
    for (const at of etat.ref.ateliers.filter((a) => parAtelier.has(a.id))) {
      lg.append(el('span', { class: 'puce', style: `background:${teinte(at.couleur, 0.16)};border-color:${at.couleur}` },
        el('span', { class: 'pastille', style: 'background:' + at.couleur }), at.nom + ' · ' + heures(parAtelier.get(at.id))));
    }
    const total = [...parAtelier.values()].reduce((a, b) => a + b, 0);
    const pers = new Set(seances.filter((s) => !s.trace && s.statut === 'prevue').flatMap((s) => s.personnes.map((p) => p.personne_id)));
    lg.append(el('span', { class: 'total' }, el('strong', {}, heures(total)), ' de main-d\'œuvre · ' + pers.size + ' personne' + (pers.size > 1 ? 's' : '')));
    const nbConflits = new Set(seances.filter((s) => !s.trace).flatMap((s) => (s.chevauchements || []).map((p) => s.date_seance + ':' + p))).size;
    if (nbConflits) lg.append(el('span', { class: 'alerte' }, nbConflits + ' chevauchement' + (nbConflits > 1 ? 's' : '')));
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
      && (etat.toutLeMonde || dansSelection(p, ateliers)));
    for (const p of liste) {
      const contrat = p.externe ? 'Externe' : p.fiches.map((f) => `${f.contrat}${f.heures_hebdo ? ' ' + f.heures_hebdo + ' h' : ''} · ${f.societe}`).join(' + ');
      const ref = p.fiches.reduce((a, f) => a + (+f.heures_hebdo || 0), 0);
      const pct = ref ? Math.min(100, (p.prevu_h / ref) * 100) : 0;
      const ligne = el('div', { class: 'personne', draggable: peutEcrire() ? 'true' : null, title: peutEcrire() ? 'Glisser sur une séance' : null },
        peutEcrire() ? el('span', { class: 'poignee', 'aria-hidden': 'true' }, '⋮⋮') : null,
        el('div', { style: 'flex:1;min-width:0' }, el('div', { class: 'nom' }, p.prenom + ' ' + p.nom), el('div', { class: 'contrat' }, contrat)),
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
      el('h3', { class: 'detail-titre' }, s.titre),
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
        !p.collab_id ? el('span', { class: 'etiquette' }, 'externe') : null,
        conflits.has(p.personne_id) ? el('span', { class: 'note' }, 'prévue ailleurs') : null,
        edit ? el('button', { class: 'bouton mini retirer', 'aria-label': 'Retirer ' + p.prenom, onclick: () => agir('retirer', { seance_id: s.id, personne_id: p.personne_id }, 'Personne retirée.') }, 'Retirer') : null));
    }
    z.append(lp);
    if (edit) {

      // Horaires
      const fDate = el('input', { type: 'date', value: s.date_seance });
      const fDeb = remplirHeure(el('span'), court5(s.heure_debut));
      const fFin = remplirHeure(el('span'), court5(s.heure_fin));
      z.append(el('div', { class: 'edition' }, el('label', {}, 'Date', fDate), el('label', {}, 'Début', fDeb), el('label', {}, 'Fin', fFin)));
      z.append(el('div', { class: 'boutons' },
        el('button', { class: 'bouton principal', onclick: async () => {
          if (fFin.valeur <= fDeb.valeur) { dire('La fin doit être après le début.', true); return; }
          const portee = s.serie_id ? await demanderPortee(`${s.titre} : ${D.long(fDate.value)}, ${fDeb.valeur}–${fFin.valeur}`) : 'seance';
          if (portee) agir('seance_modifier', { seance_id: s.id, date: fDate.value, debut: fDeb.valeur, fin: fFin.valeur, portee }, 'Séance modifiée.');
        } }, 'Enregistrer'),
        s.statut === 'prevue'
          ? el('button', { class: 'bouton', onclick: () => { const motif = prompt('Motif de la suspension (facultatif) :', ''); if (motif !== null) agir('suspendre', { seance_id: s.id, motif }, 'Séance suspendue.'); } }, 'Suspendre')
          : el('button', { class: 'bouton', onclick: () => agir('reprendre', { seance_id: s.id }, 'Séance rétablie.') }, 'Rétablir'),
        el('button', { class: 'bouton danger', onclick: () => {
          const msg = s.serie_id
            ? 'Supprimer la séance du ' + D.long(s.date_seance) + ' ? Les autres séances de la série ne changent pas.'
            : 'Supprimer la séance du ' + D.long(s.date_seance) + ' ?';
          if (confirm(msg)) { etat.choisie = null; agir('seance_supprimer', { seance_id: s.id }, 'Séance supprimée.'); }
        } }, 'Supprimer la séance'),
        s.serie_id ? el('button', { class: 'bouton danger', onclick: () => {
          const fin = D.ajout(s.date_serie, -1);
          if (confirm('Arrêter la série : plus aucune séance à partir du ' + D.long(s.date_serie) + ' ? Les séances passées restent.')) agir('serie_arreter', { serie_id: s.serie_id, date_fin: fin }, 'Série arrêtée.');
        } }, 'Arrêter la série ici') : null));
    }
  }

  // Nouvelle séance ------------------------------------------------------------------------
  function ouvrirNouvelle() {
    const sel = $('#f-tache'); sel.replaceChildren();
    for (const at of etat.ref.ateliers.filter((a) => peutAtelier(a.id))) {
      const og = el('optgroup', { label: at.nom });
      etat.ref.taches.filter((t) => t.atelier_id === at.id).forEach((t) => og.append(el('option', { value: t.id }, t.nom)));
      if (og.children.length) sel.append(og);
    }
    const jour = D.aujourdhui() >= etat.lundi && D.aujourdhui() <= D.ajout(etat.lundi, 6) ? D.aujourdhui() : etat.lundi;
    $('#f-date').value = jour; remplirHeure($('#f-debut'), '09:00'); remplirHeure($('#f-fin'), '12:00');
    $('#f-titre').value = ''; $('#f-lieu').value = ''; $('#f-recurrente').checked = false; $('#f-recurrence').hidden = true; $('#f-date-fin').value = '';
    const j = $('#f-jours'); j.replaceChildren();
    JOURS.forEach((n, i) => j.append(el('label', {}, el('input', { type: 'checkbox', value: i + 1, checked: i + 1 === D.jourIso(jour) }), n)));
    const fp = $('#f-personnes'); fp.replaceChildren();
    etat.sem.personnes.forEach((p) => fp.append(el('option', { value: p.id }, p.prenom + ' ' + p.nom)));
    $('#dlg-seance').showModal();
  }
  async function validerNouvelle() {
    const debut = $('#f-debut').valeur, fin = $('#f-fin').valeur;
    if (!debut || !fin || fin <= debut) { dire('La fin doit être après le début.', true); return; }
    const commun = { tache_id: +$('#f-tache').value, debut, fin, titre: $('#f-titre').value, lieu: $('#f-lieu').value,
      personnes: [...$('#f-personnes').selectedOptions].map((o) => +o.value) };
    if ($('#f-recurrente').checked) {
      const jours = [...$('#f-jours').querySelectorAll('input:checked')].map((c) => +c.value);
      if (!jours.length) { dire('Choisis au moins un jour.', true); return; }
      await agir('serie_creer', Object.assign(commun, { jours, date_debut: $('#f-date').value, date_fin: $('#f-date-fin').value || null }), 'Série créée.');
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
    brancherVolet();
    $('#btn-nouvelle').onclick = ouvrirNouvelle;
    $('#f-recurrente').onchange = (e) => { $('#f-recurrence').hidden = !e.target.checked; };
    $('#dlg-seance').addEventListener('close', () => { if ($('#dlg-seance').returnValue === 'ok') validerNouvelle(); });
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

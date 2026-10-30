// Accès à l'Edge Function planning-api.
// Le jeton arrive dans l'adresse comme dans Suivi des temps : ?id=… pour un collaborateur,
// ?token=… (ou ?admin=…) pour un administrateur. Il est retiré de l'adresse aussitôt et gardé pour l'onglet seulement :
// il n'apparaît donc ni dans l'historique partagé, ni dans le pied de page d'une impression.
// ?lien=… : lien personnel du planning (responsables sur ordinateur, externes). Celui-là est gardé sur
// l'ordinateur : ensuite, l'adresse simple du planning suffit. Révoqué ou fiche désactivée : il ne marche plus.
(function () {
  const URL_API = 'https://oldkmapumqnibdcniecd.supabase.co/functions/v1/planning-api';

  function lireJeton() {
    const p = new URLSearchParams(location.search);
    let ident = null;
    if (p.get('token') || p.get('admin')) ident = { jeton_admin: p.get('token') || p.get('admin') };
    else if (p.get('id')) ident = { jeton: p.get('id') };
    else if (p.get('lien')) {
      ident = { lien: p.get('lien') };
      try { localStorage.setItem('planning_lien', ident.lien); } catch (e) { /* stockage indisponible */ }
    }
    if (ident) {
      try { sessionStorage.setItem('planning_ident', JSON.stringify(ident)); } catch (e) { /* navigation privée */ }
      p.delete('admin'); p.delete('token'); p.delete('id'); p.delete('lien');
      const reste = p.toString();
      history.replaceState(null, '', location.pathname + (reste ? '?' + reste : '') + location.hash);
      return ident;
    }
    try { const s = JSON.parse(sessionStorage.getItem('planning_ident') || 'null'); if (s) return s; } catch (e) { /* rien */ }
    try { const l = localStorage.getItem('planning_lien'); if (l) return { lien: l }; } catch (e) { /* rien */ }
    return null;
  }

  const ident = lireJeton();

  async function appeler(action, params) {
    if (!ident) throw new Error('lien_invalide');
    let rep;
    try {
      rep = await fetch(URL_API, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(Object.assign({ action, params: params || {} }, ident)),
      });
    } catch (e) {
      throw new Error('Pas de connexion au serveur. Vérifie le réseau et réessaie.');
    }
    let corps = null;
    try { corps = await rep.json(); } catch (e) { /* réponse vide */ }
    if (!rep.ok || !corps || corps.ok !== true) {
      const err = (corps && corps.error) || ('Erreur ' + rep.status);
      if (err === 'lien_invalide' && ident.lien) { try { localStorage.removeItem('planning_lien'); sessionStorage.removeItem('planning_ident'); } catch (e) { /* rien */ } }
      throw new Error(err);
    }
    return corps;
  }

  window.PlanningAPI = { appeler, aUnJeton: () => !!ident };
})();

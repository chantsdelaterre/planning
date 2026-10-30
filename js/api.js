// Accès à l'Edge Function planning-api.
// Le jeton arrive dans l'adresse comme dans Suivi des temps : ?id=… pour un collaborateur,
// ?token=… (ou ?admin=…) pour un administrateur. Il est retiré de l'adresse aussitôt et gardé pour l'onglet seulement :
// il n'apparaît donc ni dans l'historique partagé, ni dans le pied de page d'une impression.
(function () {
  const URL_API = 'https://oldkmapumqnibdcniecd.supabase.co/functions/v1/planning-api';

  function lireJeton() {
    const p = new URLSearchParams(location.search);
    let ident = null;
    if (p.get('token') || p.get('admin')) ident = { jeton_admin: p.get('token') || p.get('admin') };
    else if (p.get('id')) ident = { jeton: p.get('id') };
    if (ident) {
      try { sessionStorage.setItem('planning_ident', JSON.stringify(ident)); } catch (e) { /* navigation privée */ }
      p.delete('admin'); p.delete('token'); p.delete('id');
      const reste = p.toString();
      history.replaceState(null, '', location.pathname + (reste ? '?' + reste : '') + location.hash);
      return ident;
    }
    try { return JSON.parse(sessionStorage.getItem('planning_ident') || 'null'); } catch (e) { return null; }
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
    if (!rep.ok || !corps || corps.ok !== true) throw new Error((corps && corps.error) || ('Erreur ' + rep.status));
    return corps;
  }

  window.PlanningAPI = { appeler, aUnJeton: () => !!ident };
})();

// Nome leggibile del lavoro per lo schermo del PC: mai la cartella temporanea.
//
// Un giro lanciato da una cartella mktemp (Tmp.5jCe2SqScj) finiva in «Ultimi lavori»
// con quella cartella al posto del nome: offload scrive progetto = nome della cartella
// di partenza e la pagina lo rendeva cosi' com'era. Qui si decide cosa mostrare: il
// comando leggibile (cosa) resta sempre, il progetto cade se sembra una temporanea.
// Puro, senza DOM: lo esegue la pagina (file://) e il test mac/tests/nome-lavoro-schermo.sh con node.
(function (root) {
'use strict';
// mktemp -t Tmp.XXXXXXXX su macOS (il caso visto: Tmp.5jCe2SqScj) e generiche tmp-xy12 / temp_ab12.
function cartellaTemporanea(nome) {
  const n = String(nome == null ? '' : nome).trim();
  return /^Tmp\.[A-Za-z0-9]{6,}$/.test(n) || /^(tmp|temp)[._-][A-Za-z0-9-]{4,}$/i.test(n);
}
// {progetto, cosa} -> {titolo, progetto}: stringa vuota = la pagina non la mostra.
function nomeLavoro(u) {
  u = u || {};
  const cosa = String(u.cosa == null ? '' : u.cosa);
  const progetto = String(u.progetto == null ? '' : u.progetto);
  return {
    titolo: cartellaTemporanea(cosa) ? '' : cosa,
    progetto: cartellaTemporanea(progetto) ? '' : progetto
  };
}
const api = { cartellaTemporanea: cartellaTemporanea, nomeLavoro: nomeLavoro };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
root.NomeLavoro = api;
})(typeof window !== 'undefined' ? window : globalThis);

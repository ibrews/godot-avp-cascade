/**
 * Godot Cascade — global leaderboard (Google Apps Script web app).
 *
 * Deploy (one-time):
 *   1. Create a Google Sheet. Note its tab name (default "Sheet1").
 *   2. Extensions → Apps Script. Paste this file. Set SHEET_ID + APP_KEY below.
 *   3. Deploy → New deployment → type "Web app".
 *        Execute as: Me   |   Who has access: Anyone
 *   4. Copy the /exec URL. Put it in the app (LEADERBOARD_URL) and in index.html.
 *
 * API:
 *   GET   ?top=20                                          → {"ok":true,"scores":[{name,score,ts},...]}
 *   GET   ?submit=1&name=ABC&score=1234&key=<APP_KEY>      → {"ok":true,"rank":N}
 *   POST  body: {"name":"ABC","score":1234,"key":"<APP_KEY>"} → {"ok":true,"rank":N}
 *
 * NOTE: the app submits via GET (?submit=1). Apps Script 302-redirects POSTs to
 * googleusercontent, and Godot's HTTPRequest follows that as a GET and drops the
 * body — so a GET submit is the reliable path from the engine. POST is kept for
 * curl/testing.
 *
 * The key is a light anti-spam measure only (the app is public; treat it as
 * obfuscation, not security). Names are clamped to 12 chars, scores to a sane range.
 */

const SHEET_ID = 'PUT_YOUR_SHEET_ID_HERE';   // from the Sheet URL: /d/<THIS>/edit
const TAB_NAME = 'Sheet1';
const APP_KEY  = 'cascade-2026';             // must match the app's LEADERBOARD_KEY
const MAX_SCORE = 1000000;

function _sheet() {
  return SpreadsheetApp.openById(SHEET_ID).getSheetByName(TAB_NAME);
}

// Append a (name, score) row and return its 1-based rank. Validates inputs.
function _record(rawName, rawScore, key) {
  if (String(key) !== APP_KEY) return _json({ ok: false, error: 'bad key' });
  let name = String(rawName || 'AAA').replace(/[^\x20-\x7E]/g, '').trim().slice(0, 12);
  if (name.length === 0) name = 'AAA';
  let score = Math.floor(Number(rawScore));
  if (!isFinite(score) || score < 0) score = 0;
  if (score > MAX_SCORE) score = MAX_SCORE;

  const sh = _sheet();
  sh.appendRow([new Date().toISOString(), name, score]);

  const all = sh.getRange(1, 3, sh.getLastRow(), 1).getValues()
    .map(function (r) { return Number(r[0]); }).filter(function (n) { return isFinite(n); });
  let rank = 1;
  for (let i = 0; i < all.length; i++) if (all[i] > score) rank++;
  return _json({ ok: true, rank: rank });
}

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    return _record(data.name, data.score, data.key);
  } catch (err) {
    return _json({ ok: false, error: String(err) });
  }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  // GET-based submit (the app uses this; survives Apps Script's POST→GET redirect).
  if (p.submit) {
    try { return _record(p.name, p.score, p.key); }
    catch (err) { return _json({ ok: false, error: String(err) }); }
  }
  const top = Math.min(100, Math.max(1, parseInt(p.top || '20', 10)));
  const sh = _sheet();
  const last = sh.getLastRow();
  if (last < 1) return _json({ ok: true, scores: [] });
  const rows = sh.getRange(1, 1, last, 3).getValues();
  const scores = rows
    .map(function (r) { return { ts: r[0], name: String(r[1]), score: Number(r[2]) }; })
    .filter(function (s) { return isFinite(s.score); })
    .sort(function (a, b) { return b.score - a.score; })
    .slice(0, top);
  return _json({ ok: true, scores: scores });
}

function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

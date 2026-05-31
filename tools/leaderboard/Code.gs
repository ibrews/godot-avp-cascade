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
 *   POST  body: {"name":"ABC","score":1234,"key":"<APP_KEY>"}  → {"ok":true,"rank":N}
 *   GET   ?top=20                                              → {"ok":true,"scores":[{name,score,ts},...]}
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

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    if (String(data.key) !== APP_KEY) return _json({ ok: false, error: 'bad key' });

    let name = String(data.name || 'AAA').replace(/[^\x20-\x7E]/g, '').trim().slice(0, 12);
    if (name.length === 0) name = 'AAA';
    let score = Math.floor(Number(data.score));
    if (!isFinite(score) || score < 0) score = 0;
    if (score > MAX_SCORE) score = MAX_SCORE;

    const sh = _sheet();
    sh.appendRow([new Date().toISOString(), name, score]);

    // Compute rank (1-based) among all scores.
    const all = sh.getRange(1, 3, sh.getLastRow(), 1).getValues()
      .map(function (r) { return Number(r[0]); }).filter(function (n) { return isFinite(n); });
    let rank = 1;
    for (let i = 0; i < all.length; i++) if (all[i] > score) rank++;
    return _json({ ok: true, rank: rank });
  } catch (err) {
    return _json({ ok: false, error: String(err) });
  }
}

function doGet(e) {
  const top = Math.min(100, Math.max(1, parseInt((e && e.parameter && e.parameter.top) || '20', 10)));
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

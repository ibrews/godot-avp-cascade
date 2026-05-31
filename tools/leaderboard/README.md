# Godot Cascade — Global Leaderboard

A zero-infra global leaderboard for the **Godot Cascade** AVP demo: the app POSTs
a score to a Google Apps Script web app, which stores it in a Google Sheet and
serves the top scores back as JSON. `index.html` renders the board publicly
(e.g. via GitHub Pages).

## Files
- `Code.gs` — the Apps Script web app (POST a score, GET the top N).
- `index.html` — public leaderboard page; fetches the JSON and renders a table.

## Deploy (one-time, ~5 min)
1. **Sheet:** create a Google Sheet. Copy its ID from the URL (`/d/<ID>/edit`).
2. **Script:** in that Sheet → *Extensions → Apps Script*. Replace the default with
   `Code.gs`. Set `SHEET_ID` and (optionally) `APP_KEY`.
3. **Deploy:** *Deploy → New deployment → Web app*. Execute as **Me**, access
   **Anyone**. Copy the `/exec` URL.
4. **Wire the app:** put the `/exec` URL in `LEADERBOARD_URL` in `main_v2.gd`
   (and keep `LEADERBOARD_KEY` == `APP_KEY`).
5. **Publish the page:** put the same `/exec` URL in `index.html`'s
   `LEADERBOARD_URL`, then host `index.html` on GitHub Pages (or any static host).

## API
| Method | Request | Response |
|--------|---------|----------|
| `POST` | `{"name":"ABC","score":1234,"key":"<APP_KEY>"}` | `{"ok":true,"rank":N}` |
| `GET`  | `?top=20` | `{"ok":true,"scores":[{"name","score","ts"},…]}` |

## Things to Try
1. Deploy `Code.gs` and `curl` a test score:
   `curl -L -d '{"name":"TST","score":42,"key":"cascade-2026"}' <EXEC_URL>`
2. Fetch the board: open `<EXEC_URL>?top=20` in a browser — you should see JSON.
3. Set `LEADERBOARD_URL` in `index.html`, open it locally — your test score shows.
4. Push `index.html` to a `gh-pages` branch / Pages-enabled repo and share the URL.
5. Play a 30-second round in the app and watch your score appear within ~15s.

## Notes
- `APP_KEY` is light anti-spam (obfuscation, not security — the app is public).
- Names are clamped to 12 ASCII chars; scores clamped to `[0, 1,000,000]`.
- The Sheet is the source of truth — sort/inspect/moderate rows there if needed.

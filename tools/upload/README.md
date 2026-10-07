# upload — minimal file-drop server

Stdlib-only Python server for getting screenshots and documents from your host into the jail's filesystem. Paste from clipboard, drop files, or pick from disk.

## Run

The server **starts automatically** with every jail session — `tini` (PID 1, set in the `Dockerfile`) launches it in the background via `tools/jail-entrypoint.sh` before handing the terminal to `claude`. It serves on container port `8000`, dropping files into `$UPLOAD_DIR`: `notes/uploads/` in a stack jail (outside every repo), this repo's gitignored `uploads/` in `jail-main`. Logs go to `/tmp/upload-server.log` inside the container.

Open the URL printed at launch (`upload: http://127.0.0.1:<port>/?t=<token>` — `jail-main` → 8000, a stack jail → its `UPLOAD_PORT` from `stacks/<stack>.conf`) and paste (Ctrl/Cmd+V), drop, or click. The token is fresh per container.

To run it manually against a different folder, note the auto-started instance already holds `8000` — give the manual one another port (only `8000` is published to the host, so a manual instance is reachable from inside the jail only):

```bash
UPLOAD_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(18))") python3 /workspace/tools/upload/upload.py --dir /workspace/notes/other --port 8100
```

### Ports & multiple sessions

- The container always serves on `8000`. Each launch publishes its own **host** port with `-p 127.0.0.1:<port>:8000` (loopback only — work laptops sit on office and client networks), so several sessions can run at once. `docker-compose.yml` declares no `ports:`.
- Only `jail-main` (or a stack jail launched with `--login`) also maps `127.0.0.1:54545:54545`, so it is where `/login` happens; the token persists in the shared credentials file and works in every stack jail.

## What it does

- `POST /upload` with `X-Filename` header → saves raw body to `<dir>/<filename>`. Name collisions auto-rename to `name-1.ext`.
- Pasted images get auto-named `paste-YYYYMMDD-HHMMSS.png`.
- Token auth (`?t=` for the page, `X-Upload-Token` for uploads), no HTTPS. The port is reachable by every container on the jail's Docker networks and by any page in the host browser; the token keeps them from dropping files where Claude reads them, and the custom header makes cross-origin posts fail the CORS preflight.
- 256 MiB per upload (`--max-mib`).
- Local jail tool only — do **not** expose to the internet.

## Why stdlib

The container has no pip and runs as a non-root user. `http.server` + a tiny request handler avoids the install dance entirely.

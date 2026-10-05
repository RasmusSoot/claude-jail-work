# upload — minimal file-drop server

Stdlib-only Python server for getting screenshots and documents from your host into the jail's filesystem. Paste from clipboard, drop files, or pick from disk.

## Run

The server **starts automatically** with every jail session — `tini` (PID 1, set in the `Dockerfile`) launches it in the background via `tools/jail-entrypoint.sh` before handing the terminal to `claude`. It serves on container port `8000`, dropping files into `$UPLOAD_DIR` — each project's gitignored `uploads/` inbox (set per jail by the launcher). Move files out of `uploads/` to commit them. Logs go to `/tmp/upload-server.log` inside the container.

Just open the host loopback port for your session (`jail-main` → <http://127.0.0.1:8000>, a client jail → its `UPLOAD_PORT` from `clients/<client>.conf`) and paste (Ctrl/Cmd+V), drop, or click.

To run it manually against a different folder, note the auto-started instance already holds `8000` — give the manual one another port (only `8000` is forwarded to the host, so reach others via `docker compose port` or by adding them to `ports:`):

```bash
python3 /workspace/tools/upload/upload.py --dir /workspace/SiVa/uploads --port 8100
```

### Ports & multiple sessions

- The container always serves on `8000`. Each launch publishes its own **host** port with `-p 127.0.0.1:<port>:8000` (loopback only — work laptops sit on office and client networks), so several sessions can run at once. `docker-compose.yml` declares no `ports:`.
- Only `jail-main` also maps `127.0.0.1:54545:54545`, so it is the only session that can complete `/login`; the token persists in the shared credentials file and works in every client jail.

## What it does

- `POST /upload` with `X-Filename` header → saves raw body to `<dir>/<filename>`. Name collisions auto-rename to `name-1.ext`.
- Pasted images get auto-named `paste-YYYYMMDD-HHMMSS.png`.
- No auth, no HTTPS. Local jail tool only — do **not** expose to the internet.

## Why stdlib

The container has no pip and runs as a non-root user. `http.server` + a tiny request handler avoids the install dance entirely.

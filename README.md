## What this is and who it is for

This package gives DevOps and security teams a plug-and-play way to run **OpenVSCode Server** locally with strict filesystem exposure, optional hardened reverse proxying, and managed client certificates. It is designed for operators who need repeatable workflows, auditable configuration, and minimal manual wiring.

Deliverables include:

- `run.sh` / `stop.sh` wrappers with validation, mount parsing, and usability extras.
- Minimal CA automation (`ca/ca-easy.sh`) capable of issuing server/client certificates and CRLs.
- Hardened Nginx templates (subdomain and subpath variants) ready for mTLS.
- A `Makefile` with a friendly UX for daily operations and certificate lifecycle.

---

## Prerequisites

- Docker **or** Podman (auto-detection prefers Docker).
- GNU Make 4.x or newer.
- OpenSSL 1.1+ (for the CA tooling).
- Nginx with HTTP/2 (for the optional reverse proxy).

---

## Quickstart (≤5 steps)

1. Copy the template: `cp .env.example .env`
2. Edit `.env` to set `INTERFACE`, `PORT`, and `SOURCE_PATHS`.
3. Review / adjust optional toggles (`OFFLINE_MODE`, `BASE_PATH`, `MOUNT_LABEL`, etc.).
4. Launch the workspace: `make run`
5. Open the printed URL and paste the connection token.

Use `make stop` to shut down, `make logs` to watch runtime logs, and `make dry-run` to preview changes.

---

## SOURCE_PATHS grammar

`SOURCE_PATHS` defines exactly which host directories are visible inside the container. Grammar:

```
<host_path>[:ro|:rw][@alias]
```

- Entries are comma-separated (no commas inside paths).
- Permission defaults to `ro`.
- Alias defaults to `basename(<host_path>)`.
- Aliases may contain letters, numbers, dot, underscore, or hyphen.
- Mounts appear inside the container under `/home/workspace/<alias>`.

Examples:

1. Default read-only alias from basename  
   `SOURCE_PATHS=/opt/shared/docs` → `/opt/shared/docs` mounted read-only at `/home/workspace/docs`
2. Explicit read-write with custom alias  
   `SOURCE_PATHS=/srv/project:rw@App`
3. Mixed mounts with different permissions  
   `SOURCE_PATHS=/srv/app:rw@App,/var/log:ro@Logs`
4. Alias omitted, basename used automatically  
   `SOURCE_PATHS=/home/dev/customer-a:rw`
5. Paths containing spaces (quote the entire variable)  
   `SOURCE_PATHS="/data/Client A:rw@ClientA,/data/Client B:ro@ClientB"`
6. Need a comma? Create a symlink without commas and mount that instead (documented workaround).  
   `ln -s "/mnt/clients/acme,inc" /mnt/clients/acme_inc`  
   `SOURCE_PATHS=/mnt/clients/acme_inc:rw@Acme`

Validation enforces path existence, readability, and unique aliases. Overlapping folders (e.g., `/srv` and `/srv/project`) trigger warnings, with the more specific mount taking precedence.

---

## Base path usage

When `BASE_PATH` is set (for example, `/clienteA`):

- `run.sh` passes `--server-base-path /clienteA` to OpenVSCode Server.
- The printed URL becomes `http://$INTERFACE:$PORT/clienteA/`.
- Use `nginx/ovscode_mtls_subpath.conf` to publish through a reverse proxy.
- Always include the leading slash and omit the trailing slash in `.env`.
- The subpath template issues a 301 to enforce `<BASE_PATH>/` and forwards WebSocket traffic correctly.

With `BASE_PATH` unset, the application serves from `/` and the subdomain Nginx template (`ovscode_mtls.conf`) is the right choice.

---

## Security notes and optional hardening

Threat model: host access is intentionally scoped to the exact directories you list. Every mount defaults to read-only, and the **OpenVSCode connection token stays enabled** unless you explicitly disable it in your own proxies.

Key features:

- `SOURCE_PATHS` defaults to `ro`; declare `:rw` only where edits are required.
- Tokens auto-generate using OpenSSL entropy and persist under `.ovscode_plug/.env.runtime`.
- `OFFLINE_MODE=true` runs the container with `--network none` (no marketplace/extensions updates).
- `READONLY_CONTAINER=true` adds `--read-only` plus minimal tmpfs mounts to limit writeable locations.
- `MOUNT_LABEL=:z` (or `:Z`) lets you cooperate with SELinux contexts.
- Runtime data (extensions, settings, cache) persists under `.ovscode_plug/workspace_home`, which is bind-mounted to `/home/workspace`. Remove it to reset the editor state safely.
- Logging: set `LOG_FILE=/var/log/openvscode-runtime.log` to tee container logs automatically.
- `PORT_STRATEGY=auto` finds an alternative port if your preferred value is occupied.

The README, Makefile, and scripts surface clear warnings for duplicate aliases, missing directories, and port conflicts so you can fail fast before any container starts.

---

## Podman support and engine detection

`scripts/detect_engine.sh` selects Docker when available, otherwise Podman. You can override by exporting `CONTAINER_ENGINE=podman` (or `docker`) in `.env` or via `make run CONTAINER_ENGINE=podman`. Podman users benefit from:

- `--tz UTC` for consistent timestamps.
- Identical bind-mount semantics (`:ro`, `:rw`, optional SELinux suffix).
- Systemd integration if you later convert the container to a service.

---

## Makefile UX

The `Makefile` consolidates daily tasks:

- `make run` / `make stop` / `make restart`
- `make dry-run` to print the container plan without executing.
- `make logs` to follow live logs (honors `CONTAINER_NAME` overrides).
- `make update` to `docker pull` / `podman pull` the configured image.
- `make ca-*` family for CA initialization, server/client issuance, and revocation.
- `make nginx-print` to remind you which template to use based on `BASE_PATH`.
- `make clean` to remove runtime artifacts (`CLEAN_CA=true` wipes CA outputs).

Any CLI variable (`make run PORT=7001`) overrides `.env` for that invocation.

---

## CA quick reference (`ca/ca-easy.sh`)

- `./ca/ca-easy.sh init` → Generates `ca.key`, `ca.crt`, `openssl.cnf`, and bookkeeping (`index.txt`, `serial`, `crlnumber`, `crl.pem`).
- `./ca/ca-easy.sh server dev.example.test dns:code.dev.example.test ip:127.0.0.1` → Issues `server.dev.example.test.{key,csr,crt}`.
- `./ca/ca-easy.sh client alice supersecret` → Issues `alice.{key,csr,crt,p12}` (PKCS#12 protected with `supersecret`).
- `./ca/ca-easy.sh revoke alice` → Updates `crl.pem`; redeploy it and reload Nginx to enforce revocation.

The generated `.p12` packages import smoothly on macOS, Windows, and Linux browsers.

---

## Nginx mTLS templates

- `nginx/ovscode_mtls.conf` (subdomain): listens on `443 ssl http2`, enforces client certificates, and handles WebSockets.
- `nginx/ovscode_mtls_subpath.conf` (subpath): same hardening plus `location` rules that maintain your `BASE_PATH`.
- `nginx/README-nginx.md` walks through placeholder replacement, certificate distribution, CRL updates, and troubleshooting.

Both templates default to strong TLS 1.2/1.3 ciphers, disable session tickets, and set `Strict-Transport-Security`, `X-Frame-Options`, and `Referrer-Policy`.

---

## Troubleshooting

- **Port already in use** → Set `PORT_STRATEGY=auto` or choose a different `PORT`. The validator fails fast in `strict` mode.
- **Path not found / unreadable** → Ensure the host path exists and that your user can read it. For shared storage, check NFS/SMB permissions.
- **Alias collision** → Aliases must be unique. Adjust the `@alias` suffix or let the basename fallback handle it.
- **Permission denied inside container** → For `:rw` mounts, verify the host user has write access, or override `USERMAP=uid:gid`.
- **SELinux issues** → Add `MOUNT_LABEL=:z` (or `:Z` for private contexts) so Docker/Podman relabels the mounts.
- **WSL/Windows hosts** → Use `/mnt/c/...` paths and ensure Docker Desktop shares the drive. Avoid symlinks that cross file systems.
- **Podman rootless** → Ensure the user has access to host paths and adjust `USERMAP` only when necessary.

---

## FAQ

- **How do I add another folder?**  
  Update `SOURCE_PATHS` (comma-separated). Run `make dry-run` to confirm the parsed mount table, then `make restart`.

- **Can I force everything to be read-only?**  
  Yes. Omit `:rw` everywhere. The validator warns when a path is `:rw` but not writable.

- **How do I disable the token behind mTLS?**  
  Keep the connection token for defense-in-depth. If you must disable it, set `CONNECTION_TOKEN=` and pass `--connection-token ''` in `run.sh` (requires script adjustment) or rely on Nginx `auth_request`. Document the trade-off.

- **Where do logs live?**  
  Use `make logs` for live output. Set `LOG_FILE=/var/log/openvscode-runtime.log` to tee logs automatically; the file rotates under your control.

- **How do I update the image?**  
  Run `make update`. Restart the container afterward (`make restart`) to use the new image.

- **What does dry-run show me?**  
  `make dry-run` prints the normalized mount table, resolved UID/GID, port selection, and the exact Docker/Podman command without starting anything.

- **How do I remove folders?**  
  Remove the entry from `SOURCE_PATHS`, then `make restart`. The workspace file regenerates automatically.

---

## Acceptance tests

Perform these manual checks whenever you change configuration:

- Open the editor and attempt to save a file inside a `:ro` mount → write must fail.
- Save a file inside a `:rw` mount → write must succeed.
- Define duplicate aliases → validator should stop with an error.
- Enable `OFFLINE_MODE=true` → marketplace/extensions requests should fail, proving outbound network is blocked.
- Access Nginx mTLS endpoint without a client cert → expect 400/403. Re-test with a valid client certificate → access succeeds.
- Set `BASE_PATH=/clienteA`, use the subpath template, and confirm URLs under `/clienteA/` load correctly.

Record outcomes in your runbook as part of acceptance.

---

## License

This repository is provided under the MIT License. See `LICENSE` for details.

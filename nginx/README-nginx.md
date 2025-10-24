# OpenVSCode + Nginx mTLS Gateway

This folder provides hardened Nginx examples for proxying OpenVSCode Server behind mutual TLS (mTLS). Certificates are expected to come from `ca/ca-easy.sh`.

Use the **subdomain** template when the editor lives at its own hostname. Use the **subpath** template together with `BASE_PATH` (for example, `/clienteA`) so the editor sits underneath an existing site.

---

## Prerequisites

- OpenVSCode Server launched with this toolkit.
- Certificates issued with `ca/ca-easy.sh` (`server.<domain>.{key,crt}`, `<name>.{crt,p12}`).
- Nginx built with HTTP/2 and TLS 1.3 support.

---

## Step-by-step

1. **Create the CA and issue certs**
   - `./ca/ca-easy.sh init`
   - `./ca/ca-easy.sh server dev.example.test dns:code.dev.example.test`
   - `./ca/ca-easy.sh client alice strongpass`

2. **Copy materials to your Nginx host**
   - Create a directory like `/opt/ovscode-certs/`.
   - Copy `ca/ca.crt`, `ca/server.dev.example.test.key`, and `ca/server.dev.example.test.crt`.
   - Optionally copy `ca/crl.pem` if you plan to enforce revocation.

3. **Pick the right template**
   - `ovscode_mtls.conf` → dedicated hostname (`code.example.test`).
   - `ovscode_mtls_subpath.conf` → subpath (set `BASE_PATH=/clienteA` in `.env` and expose via `https://portal.example.test/clienteA/`).

4. **Fill placeholders**
   - Replace `<SERVER_NAME>` with your hostname.
   - Point `<SERVER_CERT>` and `<SERVER_KEY>` to the server cert/key.
   - Set `<CA_CRT>` to the CA bundle (usually `ca.crt`).
   - For the subpath template, replace `<BASE_PATH>` everywhere with the same value used in `.env`.
   - Replace `<UPSTREAM_PORT>` with the host port where OpenVSCode listens (from `PORT`/`PORT_STRATEGY`).
   - If you generated a CRL, uncomment `ssl_crl` and point it to the deployed `crl.pem`.

5. **Enable the site and reload Nginx**
   - Drop the filled template into `/etc/nginx/conf.d/` or an `sites-available`/`sites-enabled` pair.
   - Check syntax: `sudo nginx -t`
   - Reload: `sudo systemctl reload nginx`

6. **Distribute client certificates**
   - Provide the `.p12` file to each authorized user.
   - macOS: double-click the file and choose the `login` keychain.
   - Windows: right-click → *Install PFX* → store in *Personal*.
   - Linux: `pk12util -i <name>.p12 -d sql:$HOME/.pki/nssdb` or import via the browser.

7. **Test mTLS**
   - Without the client certificate you should see `400`/`403` from Nginx.
  - After importing the client cert, the browser should present the private key and reach the editor.

---

## Troubleshooting

- **403 even with a cert** → Ensure the browser actually presents the certificate; check `journalctl -u nginx` for clues. Verify that the client cert chains to the deployed CA and is not revoked.
- **Revocation not enforced** → Confirm `ssl_crl` points to the latest CRL and reload Nginx after running `./ca-easy.sh revoke`.
- **SAN mismatch** → `openssl x509 -in server.<domain>.crt -text` and confirm the requested hostname is listed under *Subject Alternative Name*.
- **WebSockets failing** → Make sure the `proxy_set_header Upgrade` and `Connection` directives remain intact.
- **Subpath errors** → The `BASE_PATH` in `.env` must match the `<BASE_PATH>` placeholder in the Nginx template, and OpenVSCode must be started with the same base path.

---

## Notes

- TLS parameters prefer strong forward-secret ciphers and disable session tickets for better privacy.
- Client-side certificates complement (and can replace) the OpenVSCode connection token.
- Keep the CA private key offline whenever possible. Use `ca/ca-easy.sh server` and `client` on a hardened machine, then transfer only the issued certificates to production.

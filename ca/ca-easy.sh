#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$CA_DIR/openssl.cnf"
CA_KEY="$CA_DIR/ca.key"
CA_CERT="$CA_DIR/ca.crt"
INDEX_FILE="$CA_DIR/index.txt"
SERIAL_FILE="$CA_DIR/serial"
CERTS_DIR="$CA_DIR/certs"
CSR_DIR="$CA_DIR/csr"
CRL_FILE="$CA_DIR/crl.pem"

usage() {
  cat <<'EOF'
Usage:
  ca-easy.sh init
  ca-easy.sh server <domain> [SAN ...]
  ca-easy.sh client <name> [P12_PASSWORD]
  ca-easy.sh revoke <name>

Examples:
  ca-easy.sh init
  ca-easy.sh server dev.example.test dns:code.dev.example.test ip:127.0.0.1
  ca-easy.sh client alice
  ca-easy.sh client bob supersecret
  ca-easy.sh revoke alice

SAN syntax accepts tokens prefixed with dns: or ip:. Tokens are case-insensitive.
EOF
}

require_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'Error: openssl is required.\n' >&2
    exit 1
  fi
}

ensure_ca_initialized() {
  if [[ ! -f "$CA_KEY" || ! -f "$CA_CERT" || ! -f "$CONFIG_FILE" ]]; then
    printf 'Error: CA not initialized. Run ./ca-easy.sh init first.\n' >&2
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

init_ca() {
  require_openssl
  if [[ -f "$CA_KEY" || -f "$CA_CERT" ]]; then
    printf 'Error: CA material already exists in %s. Clean up manually if you need a fresh CA.\n' "$CA_DIR" >&2
    exit 1
  fi

  mkdir -p "$CERTS_DIR" "$CSR_DIR"
  : > "$INDEX_FILE"
  if [[ ! -f "$SERIAL_FILE" ]]; then
    printf '1000\n' > "$SERIAL_FILE"
  fi

  umask 077
  openssl req \
    -x509 \
    -nodes \
    -newkey rsa:4096 \
    -days 3650 \
    -sha256 \
    -subj "/CN=OpenVSCode Local Root CA" \
    -keyout "$CA_KEY" \
    -out "$CA_CERT"

  cat > "$CONFIG_FILE" <<EOF
[ ca ]
default_ca = local_ca

[ local_ca ]
dir               = $CA_DIR
certs             = $CERTS_DIR
crl_dir           = $CA_DIR
database          = $INDEX_FILE
new_certs_dir     = $CERTS_DIR
certificate       = $CA_CERT
serial            = $SERIAL_FILE
private_key       = $CA_KEY
default_days      = 825
default_md        = sha256
preserve          = no
policy            = local_policy
email_in_dn       = no
copy_extensions   = copy
unique_subject    = no
crlnumber         = $CA_DIR/crlnumber
crl               = $CRL_FILE

[ local_policy ]
commonName = supplied

[ server_cert ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ client_cert ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF

  if [[ ! -f "$CA_DIR/crlnumber" ]]; then
    printf '1000\n' > "$CA_DIR/crlnumber"
  fi

  printf 'Root CA created.\n'
  printf '  Key:  %s\n' "$CA_KEY"
  printf '  Cert: %s\n' "$CA_CERT"
  printf '\nNext steps:\n'
  printf '  1. Distribute %s to trusted systems.\n' "$CA_CERT"
  printf '  2. Use "./ca-easy.sh server" to issue a server certificate.\n'
  printf '  3. Use "./ca-easy.sh client" to issue client certificates.\n'
}

build_req_config() {
  local cfg="$1"
  local cn="$2"
  shift 2 || true
  local san_tokens=("$@")
  local dns_index=1
  local ip_index=1

  {
    printf '[ req ]\n'
    printf 'default_bits = 4096\n'
    printf 'prompt = no\n'
    printf 'default_md = sha256\n'
    printf 'distinguished_name = req_dn\n'
    printf 'req_extensions = req_ext\n'
    printf '\n[ req_dn ]\n'
    printf 'CN = %s\n' "$cn"
    printf '\n[ req_ext ]\n'
    printf 'subjectAltName = @alt_names\n'
    printf '\n[ alt_names ]\n'
    printf 'DNS.%d = %s\n' "$dns_index" "$cn"
  } > "$cfg"

  for token in "${san_tokens[@]}"; do
    [[ -n "$token" ]] || continue
    token="$(trim "$token")"
    [[ -n "$token" ]] || continue
    local lowered
    lowered="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    case "$lowered" in
      dns:*)
        dns_index=$((dns_index + 1))
        printf 'DNS.%d = %s\n' "$dns_index" "${token#*:}" >> "$cfg"
        ;;
      ip:*)
        printf 'IP.%d = %s\n' "$ip_index" "${token#*:}" >> "$cfg"
        ip_index=$((ip_index + 1))
        ;;
      *)
        printf 'DNS.%d = %s\n' "$((dns_index + 1))" "$token" >> "$cfg"
        dns_index=$((dns_index + 1))
        ;;
    esac
  done
}

issue_server() {
  ensure_ca_initialized
  require_openssl
  local domain="${1:-}"
  shift || true
  [[ -n "$domain" ]] || { printf 'Error: server command requires <domain>.\n' >&2; exit 1; }

  local key_file="$CA_DIR/server.${domain}.key"
  local csr_file="$CA_DIR/server.${domain}.csr"
  local crt_file="$CA_DIR/server.${domain}.crt"
  local req_cfg
  req_cfg="$(mktemp)"
  trap 'rm -f "$req_cfg"' EXIT

  build_req_config "$req_cfg" "$domain" "$@"

  umask 077
  openssl req -new -nodes -newkey rsa:4096 -config "$req_cfg" -keyout "$key_file" -out "$csr_file"
  openssl ca -config "$CONFIG_FILE" -extensions server_cert -batch -in "$csr_file" -out "$crt_file"

  rm -f "$req_cfg"
  trap - EXIT

  printf 'Server certificate issued for %s\n' "$domain"
  printf '  Key: %s\n' "$key_file"
  printf '  CSR: %s\n' "$csr_file"
  printf '  Cert: %s\n' "$crt_file"
  printf '\nNext steps:\n'
  printf '  - Copy %s, %s, and %s to your Nginx host (e.g., /opt/certs/).\n' "$crt_file" "$key_file" "$CA_CERT"
  printf '  - Reference them in nginx/ovscode_mtls.conf or nginx/ovscode_mtls_subpath.conf.\n'
}

issue_client() {
  ensure_ca_initialized
  require_openssl
  local name="${1:-}"
  [[ -n "$name" ]] || { printf 'Error: client command requires <name>.\n' >&2; exit 1; }
  shift || true
  local p12_password="${1:-}"

  local key_file="$CA_DIR/${name}.key"
  local csr_file="$CA_DIR/${name}.csr"
  local crt_file="$CA_DIR/${name}.crt"
  local p12_file="$CA_DIR/${name}.p12"
  local req_cfg
  req_cfg="$(mktemp)"
  trap 'rm -f "$req_cfg"' EXIT

  build_req_config "$req_cfg" "$name"

  umask 077
  openssl req -new -nodes -newkey rsa:4096 -config "$req_cfg" -keyout "$key_file" -out "$csr_file"
  openssl ca -config "$CONFIG_FILE" -extensions client_cert -batch -in "$csr_file" -out "$crt_file"

  if [[ -n "$p12_password" ]]; then
    openssl pkcs12 -export -in "$crt_file" -inkey "$key_file" -certfile "$CA_CERT" -out "$p12_file" -passout "pass:$p12_password"
  else
    openssl pkcs12 -export -in "$crt_file" -inkey "$key_file" -certfile "$CA_CERT" -out "$p12_file" -passout pass:
  fi

  rm -f "$req_cfg"
  trap - EXIT

  printf 'Client certificate issued for %s\n' "$name"
  printf '  Key:  %s\n' "$key_file"
  printf '  CSR:  %s\n' "$csr_file"
  printf '  Cert: %s\n' "$crt_file"
  printf '  P12:  %s\n' "$p12_file"
  printf '\nImport guidance:\n'
  printf '  - macOS: double-click %s (enter password if set).\n' "$p12_file"
  printf '  - Windows: right-click the .p12, choose "Install PFX", place in Personal store.\n'
  printf '  - Linux: use "pk12util -i %s -d sql:$HOME/.pki/nssdb" or browser certificate manager.\n' "$p12_file"
}

revoke_client() {
  ensure_ca_initialized
  require_openssl
  local name="${1:-}"
  [[ -n "$name" ]] || { printf 'Error: revoke command requires <name>.\n' >&2; exit 1; }

  local crt_file="$CA_DIR/${name}.crt"
  if [[ ! -f "$crt_file" ]]; then
    printf 'Error: Certificate %s not found.\n' "$crt_file" >&2
    exit 1
  fi

  openssl ca -config "$CONFIG_FILE" -revoke "$crt_file"
  openssl ca -config "$CONFIG_FILE" -gencrl -out "$CRL_FILE"

  printf 'Certificate for %s revoked.\n' "$name"
  printf 'Updated CRL available at %s\n' "$CRL_FILE"
  printf 'Remember to deploy the new CRL to your Nginx hosts (ssl_crl directive).\n'
}

main() {
  local subcommand="${1:-}"
  case "$subcommand" in
    init)
      init_ca
      ;;
    server)
      shift
      issue_server "$@"
      ;;
    client)
      shift
      issue_client "$@"
      ;;
    revoke)
      shift
      revoke_client "$@"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

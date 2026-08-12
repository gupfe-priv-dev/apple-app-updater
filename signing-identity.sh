#!/usr/bin/env zsh
# Manage the local code-signing identity for UpdateAll.
#
#   ./signing-identity.sh create              make a self-signed identity
#   ./signing-identity.sh status              is one present?
#   ./signing-identity.sh remove              delete it
#   ./signing-identity.sh export     [file]   base64 of a password-protected .p12
#   ./signing-identity.sh import     [file]   restore from that base64
#   ./signing-identity.sh export-pem <dir>    write key.pem + cert.pem
#   ./signing-identity.sh import-pem <key> <cert>   rebuild the identity from those
#
# Why this exists: an ad-hoc signature identifies an app by its code hash, which
# changes on every build, so macOS treats each build of UpdateAll as a different
# app and revokes its App Management grant. Signing with a certificate gives a
# stable designated requirement — the hash still changes, the requirement
# doesn't — so the grant survives rebuilds.
#
# The identity lives in the login keychain, which does NOT sync to iCloud. Back
# it up (export → password manager or CI secret) or a new Mac starts over.
#
# The private key is the sensitive half: anyone holding it can sign code macOS
# will accept as this app. It is never shipped inside the app — the app doesn't
# need it, only whatever *builds* the app does.
set -euo pipefail

CN="${UPDATEALL_SIGNING_CN:-UpdateAll Local Signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"
}

# Import a key+cert pair and mark the certificate trusted for code signing.
# Shared by `create`, `import` and `import-pem` so there's one code path that
# knows Apple's quirks.
install_pair() {  # $1 = key.pem  $2 = cert.pem
  local _t; _t=$(mktemp -d)
  # The PKCS#12 is only transport between these two commands, so its password
  # is random and discarded; the key's real protection is the login keychain.
  #
  # Apple's importer rejects OpenSSL 3's default MAC ("MAC verification
  # failed") and also rejects an empty password, so pin the legacy algorithms
  # and use a real one. Works under Homebrew openssl and system LibreSSL alike.
  local _pw; _pw=$(openssl rand -hex 24)
  openssl pkcs12 -export -out "$_t/id.p12" -inkey "$1" -in "$2" \
    -passout "pass:$_pw" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
  # -A: no ACL restriction, so codesign uses the key without prompting on
  # every build.
  security import "$_t/id.p12" -k "$LOGIN_KEYCHAIN" -P "$_pw" -A -T /usr/bin/codesign >/dev/null
  # Without trusting it for code signing it imports but never counts as a
  # *valid* identity, and codesign won't find it.
  security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$2"
  rm -rf "$_t"
}

# Refuse to write key material anywhere inside a git working tree. .gitignore
# covers the obvious names, but the only reliable rule is "not in the repo" —
# a private key that reaches a public repo lets anyone sign code macOS will
# accept as this app.
refuse_if_in_repo() {  # $1 = path being written
  local dir; dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd) || return 0
  if (cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    echo "Refusing to write '$1' — it is inside a git working tree." >&2
    echo "Write it somewhere else, e.g. ~/Desktop, and delete it once it's in" >&2
    echo "your password manager." >&2
    exit 1
  fi
}

read_password() {  # $1 = prompt
  printf '%s' "$1" >&2
  read -rs PW; echo >&2
  [[ -n "$PW" ]] || { echo "A password is required." >&2; exit 1; }
}

case "${1:-}" in
  status)
    have_identity && echo current || echo missing
    ;;

  name)
    echo "$CN"
    ;;

  create)
    if have_identity; then echo "already set up"; exit 0; fi
    _t=$(mktemp -d); trap 'rm -rf "$_t"' EXIT
    # codeSigning EKU is what makes it show up as a signing identity at all.
    openssl req -newkey rsa:2048 -nodes -keyout "$_t/key.pem" \
      -x509 -days 3650 -out "$_t/cert.pem" -subj "/CN=$CN" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    install_pair "$_t/key.pem" "$_t/cert.pem"
    echo "Created '$CN'. Rebuild UpdateAll, grant App Management once more, and it will stick from then on."
    echo "Back it up:  ./signing-identity.sh export identity.b64"
    ;;

  remove)
    if ! have_identity; then echo "already removed"; exit 0; fi
    security delete-identity -c "$CN" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
    echo "Removed — builds fall back to ad-hoc signing"
    ;;

  export)
    have_identity || { echo "No identity named '$CN'. Run: $0 create" >&2; exit 1; }
    # `security export` can't select one identity by name, so refuse rather
    # than quietly bundling up unrelated keys.
    _count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c ')' || true)
    if [[ "$_count" -gt 1 ]]; then
      echo "$_count code-signing identities present and 'security export' can't pick one by name." >&2
      echo "Export '$CN' from Keychain Access, then: base64 -i <file.p12>" >&2
      exit 1
    fi
    [[ -n "${2:-}" ]] && refuse_if_in_repo "$2"
    read_password 'Password to encrypt the backup: '
    _t=$(mktemp -d); trap 'rm -rf "$_t"' EXIT
    # macOS asks permission to read the private key here — expected.
    security export -k "$LOGIN_KEYCHAIN" -t identities -f pkcs12 -P "$PW" -o "$_t/id.p12"
    if [[ -n "${2:-}" ]]; then
      base64 -i "$_t/id.p12" > "$2"; chmod 600 "$2"
      echo "Wrote $(wc -c <"$2" | tr -d ' ') bytes to $2 — store it with its password, then delete the file." >&2
    else
      base64 -i "$_t/id.p12"
    fi
    ;;

  import)
    _t=$(mktemp -d); trap 'rm -rf "$_t"' EXIT
    if [[ -n "${2:-}" ]]; then base64 -d -i "$2" > "$_t/id.p12"
    else echo "Paste the base64, then Ctrl-D:" >&2; base64 -d > "$_t/id.p12"; fi
    read_password 'Password the backup was encrypted with: '
    security import "$_t/id.p12" -k "$LOGIN_KEYCHAIN" -P "$PW" -A -T /usr/bin/codesign
    openssl pkcs12 -in "$_t/id.p12" -clcerts -nokeys -passin "pass:$PW" -out "$_t/cert.pem" -legacy 2>/dev/null \
      || openssl pkcs12 -in "$_t/id.p12" -clcerts -nokeys -passin "pass:$PW" -out "$_t/cert.pem" 2>/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$_t/cert.pem"
    echo "Imported:"; security find-identity -v -p codesigning
    ;;

  export-pem)
    DIR="${2:-}"; [[ -n "$DIR" ]] || { echo "Usage: $0 export-pem <dir>" >&2; exit 2; }
    have_identity || { echo "No identity named '$CN'. Run: $0 create" >&2; exit 1; }
    refuse_if_in_repo "$DIR/key.pem"
    read_password 'Temporary password (used only to move the key out of the keychain): '
    mkdir -p "$DIR"
    _t=$(mktemp -d); trap 'rm -rf "$_t"' EXIT
    security export -k "$LOGIN_KEYCHAIN" -t identities -f pkcs12 -P "$PW" -o "$_t/id.p12"
    openssl pkcs12 -in "$_t/id.p12" -nocerts -nodes -passin "pass:$PW" -out "$DIR/key.pem" -legacy 2>/dev/null \
      || openssl pkcs12 -in "$_t/id.p12" -nocerts -nodes -passin "pass:$PW" -out "$DIR/key.pem" 2>/dev/null
    openssl pkcs12 -in "$_t/id.p12" -clcerts -nokeys -passin "pass:$PW" -out "$DIR/cert.pem" -legacy 2>/dev/null \
      || openssl pkcs12 -in "$_t/id.p12" -clcerts -nokeys -passin "pass:$PW" -out "$DIR/cert.pem" 2>/dev/null
    chmod 600 "$DIR/key.pem"
    echo "Wrote $DIR/key.pem and $DIR/cert.pem — key.pem is unencrypted, keep it safe." >&2
    ;;

  import-pem)
    KEY="${2:-}"; CERT="${3:-}"
    [[ -n "$KEY" && -n "$CERT" ]] || { echo "Usage: $0 import-pem <key.pem> <cert.pem>" >&2; exit 2; }
    install_pair "$KEY" "$CERT"
    echo "Imported:"; security find-identity -v -p codesigning
    ;;

  *)
    sed -n '2,10p' "$0" >&2
    exit 2
    ;;
esac

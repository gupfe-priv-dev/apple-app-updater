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

# Split a multi-identity PKCS#12 and write out just the key and certificate
# belonging to $CN, as "$3/key.pem" and "$3/cert.pem".
#
# `security export -t identities` exports *every* identity in the keychain and
# has no way to select one, so the p12 this script produces can carry unrelated
# keys. `openssl pkcs12 -clcerts`/`-nocerts` then emit all of them and taking
# the first is a coin flip: it shipped a CN=localhost certificate to CI, which
# trusted that one, found no valid UpdateAll identity, and signed three
# releases ad-hoc while reporting success. So match the certificate by name,
# then pair it with the key that actually belongs to it rather than assuming
# the orders line up.
split_identity() {  # $1 = p12  $2 = password  $3 = output dir
  local _t; _t=$(mktemp -d)
  mkdir -p "$3"
  _pk12() { openssl pkcs12 -in "$1" -passin "pass:$2" "$@[3,-1]" -legacy 2>/dev/null \
            || openssl pkcs12 -in "$1" -passin "pass:$2" "$@[3,-1]" 2>/dev/null; }
  _pk12 "$1" "$2" -clcerts -nokeys  > "$_t/certs.pem"
  _pk12 "$1" "$2" -nocerts  -nodes  > "$_t/keys.pem"

  # Each -----BEGIN block into a file of its own.
  awk -v d="$_t" 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=d"/cert"n".pem"} n>0{print > f}' "$_t/certs.pem"
  awk -v d="$_t" 'BEGIN{n=0} /BEGIN .*PRIVATE KEY/{n++; f=d"/key"n".pem"} n>0{print > f}' "$_t/keys.pem"

  local c=""
  for f in "$_t"/cert*.pem; do
    if openssl x509 -in "$f" -noout -subject 2>/dev/null | grep -q "CN *= *$CN"; then c="$f"; break; fi
  done
  [[ -n "$c" ]] || { echo "No certificate named '$CN' in that backup." >&2; rm -rf "$_t"; return 1; }

  # Pair by public key: the only reliable link between the two lists.
  local want; want=$(openssl x509 -in "$c" -pubkey -noout 2>/dev/null)
  local k=""
  for f in "$_t"/key*.pem; do
    if [[ "$(openssl pkey -in "$f" -pubout 2>/dev/null)" == "$want" ]]; then k="$f"; break; fi
  done
  [[ -n "$k" ]] || { echo "Found the '$CN' certificate but not its private key." >&2; rm -rf "$_t"; return 1; }

  cp "$c" "$3/cert.pem"; cp "$k" "$3/key.pem"; chmod 600 "$3/key.pem"
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
    # Other code-signing identities in the keychain are fine: the backup is
    # narrowed to '$CN' below rather than carrying whatever else is there.
    [[ -n "${2:-}" ]] && refuse_if_in_repo "$2"
    read_password 'Password to encrypt the backup: '
    _t=$(mktemp -d); trap 'rm -rf "$_t"' EXIT
    # macOS asks permission to read the private key here — expected.
    _xp=$(openssl rand -hex 24)
    security export -k "$LOGIN_KEYCHAIN" -t identities -f pkcs12 -P "$_xp" -o "$_t/all.p12"
    split_identity "$_t/all.p12" "$_xp" "$_t/one"
    # Rebuild a p12 holding this identity alone, under the user's password.
    openssl pkcs12 -export -out "$_t/id.p12" -inkey "$_t/one/key.pem" -in "$_t/one/cert.pem" \
      -passout "pass:$PW" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
    echo "Backing up: $(openssl x509 -in "$_t/one/cert.pem" -noout -subject)" >&2
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
    # Older backups may hold several identities; install only ours, so the
    # trust mark lands on the right certificate.
    split_identity "$_t/id.p12" "$PW" "$_t/one"
    install_pair "$_t/one/key.pem" "$_t/one/cert.pem"
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
    split_identity "$_t/id.p12" "$PW" "$DIR"
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

#!/usr/bin/env bash
# Guided, resumable setup for Developer ID signing and notarization.
#
#   scripts/setup-signing.sh cert     # step 1: private key + CSR, then the .p12
#   scripts/setup-signing.sh notary   # step 2: check the App Store Connect API key
#   scripts/setup-signing.sh secrets  # step 3: push everything to GitHub Actions
#   scripts/setup-signing.sh verify   # check what is in place
#
# Generating the key with openssl rather than Keychain Access means the same key
# can be imported locally and handed to CI without an export dance, and the .p12
# carries Apple's intermediate so a clean runner can build the chain.
set -euo pipefail

TEAM_ID="${APPLE_TEAM_ID:-29GCN65AP9}"
TEAM_NAME="${APPLE_TEAM_NAME:-Flexpa USA Inc.}"
IDENTITY="Developer ID Application: $TEAM_NAME ($TEAM_ID)"
REPO="${BRIDGE_REPO:-flexpa/bridge}"
DIR="${SIGNING_DIR:-$HOME/.flexpa-signing}"
INTERMEDIATE_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓  %s\033[0m\n' "$*"; }

mkdir -p "$DIR"
chmod 700 "$DIR"

cmd_cert() {
  if security find-identity -v -p codesigning | grep -q "Developer ID Application.*$TEAM_ID"; then
    ok "A Developer ID Application identity for $TEAM_ID is already in your keychain."
    security find-identity -v -p codesigning | grep "Developer ID Application"
    echo "Re-run with 'secrets' to push it to CI, or delete it from Keychain Access to start over."
    return 0
  fi

  if [ ! -f "$DIR/developerID.key" ]; then
    step "Generating a private key and a certificate request"
    read -r -p "  Apple ID email for the request [${APPLE_ID_EMAIL:-}]: " EMAIL
    EMAIL="${EMAIL:-${APPLE_ID_EMAIL:-}}"
    [ -n "$EMAIL" ] || { echo "An email is required." >&2; exit 1; }
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$DIR/developerID.key" \
      -out "$DIR/developerID.csr" \
      -subj "/emailAddress=$EMAIL/CN=$TEAM_NAME/C=US" 2>/dev/null
    chmod 600 "$DIR/developerID.key"
    ok "Wrote $DIR/developerID.csr"
  else
    ok "Using the existing request at $DIR/developerID.csr"
  fi

  if [ ! -f "$DIR/developerID.cer" ]; then
    cat <<EOF

$(bold "Now do this in a browser, then come back:")

  1. Open  https://developer.apple.com/account/resources/certificates/add
  2. Choose  Developer ID Application  (under Software).
     If that option is missing, your Apple Developer role cannot create it.
     Only the Account Holder can. Ask whoever holds that role, or have them
     transfer it to you at  https://developer.apple.com/account/#/membership
  3. Profile Type: leave the default (G2 Sub-CA).
  4. Upload this file:
       $DIR/developerID.csr
     (it is on your clipboard now)
  5. Download the resulting certificate and save it as:
       $DIR/developerID.cer

EOF
    command -v pbcopy > /dev/null && pbcopy < "$DIR/developerID.csr" || true
    read -r -p "Press return once $DIR/developerID.cer exists… "
    [ -f "$DIR/developerID.cer" ] || { echo "Not found: $DIR/developerID.cer" >&2; exit 1; }
  fi

  step "Building the .p12 and importing it"
  curl -fsSL "$INTERMEDIATE_URL" -o "$DIR/intermediate.cer"
  openssl x509 -inform DER -in "$DIR/developerID.cer" -out "$DIR/developerID.pem"
  openssl x509 -inform DER -in "$DIR/intermediate.cer" -out "$DIR/intermediate.pem"

  # macOS `security import` rejects a PKCS#12 built with OpenSSL 3's modern defaults
  # ("MAC verification failed"). OpenSSL 3 needs -legacy; LibreSSL has no such flag
  # and already defaults to algorithms macOS accepts. Pick accordingly, then prove
  # the file imports before it becomes a CI secret nobody can use.
  P12_ARGS=()
  if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    P12_ARGS+=(-legacy)
  fi

  P12_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  openssl pkcs12 -export "${P12_ARGS[@]}" \
    -inkey "$DIR/developerID.key" \
    -in "$DIR/developerID.pem" \
    -certfile "$DIR/intermediate.pem" \
    -name "$IDENTITY" \
    -out "$DIR/developerID.p12" \
    -passout "pass:$P12_PASSWORD"
  printf '%s' "$P12_PASSWORD" > "$DIR/p12-password.txt"
  chmod 600 "$DIR/developerID.p12" "$DIR/p12-password.txt"

  step "Checking the .p12 imports cleanly (this is what CI will do)"
  PROBE="$(mktemp -d)/probe.keychain"
  security create-keychain -p probe "$PROBE" 2>/dev/null
  if security import "$DIR/developerID.p12" -k "$PROBE" -P "$P12_PASSWORD" 2>&1 | grep -qi "imported"; then
    ok "importable"
  else
    security delete-keychain "$PROBE" 2>/dev/null || true
    echo "  The .p12 cannot be imported by macOS. openssl in use: $(openssl version)" >&2
    echo "  Try again with the system one:  PATH=/usr/bin:\$PATH $0 cert" >&2
    exit 1
  fi
  security delete-keychain "$PROBE" 2>/dev/null || true

  security import "$DIR/developerID.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
  ok "Imported into your login keychain"

  if security find-identity -v -p codesigning | grep -q "Developer ID Application.*$TEAM_ID"; then
    ok "Ready to sign as: $IDENTITY"
    echo "  .p12 and its password are in $DIR (mode 600). Back them up somewhere safe; they are not in git."
  else
    warn "The identity did not appear. The certificate may not match the key in $DIR."
  fi
}

cmd_notary() {
  step "App Store Connect API key for notarization"
  if [ -f "$DIR/notary.p8" ] && [ -f "$DIR/notary-key-id.txt" ] && [ -f "$DIR/notary-issuer-id.txt" ]; then
    ok "Key already saved in $DIR"
  else
    cat <<EOF

$(bold "Do this in a browser, then come back:")

  1. Open  https://appstoreconnect.apple.com/access/integrations/api
  2. Team Keys tab → + → Name it "Notarization", Access: Developer → Generate.
  3. Download the .p8 (Apple lets you download it exactly once) and save it as:
       $DIR/notary.p8
  4. Copy the KEY ID from that row and the ISSUER ID from the top of the page.

EOF
    read -r -p "Press return once $DIR/notary.p8 exists… "
    [ -f "$DIR/notary.p8" ] || { echo "Not found: $DIR/notary.p8" >&2; exit 1; }
    read -r -p "  Key ID: " KEY_ID
    read -r -p "  Issuer ID: " ISSUER_ID
    printf '%s' "$KEY_ID" > "$DIR/notary-key-id.txt"
    printf '%s' "$ISSUER_ID" > "$DIR/notary-issuer-id.txt"
    chmod 600 "$DIR/notary.p8" "$DIR"/notary-*.txt
  fi

  step "Asking Apple whether the key works"
  if xcrun notarytool history \
      --key "$DIR/notary.p8" \
      --key-id "$(cat "$DIR/notary-key-id.txt")" \
      --issuer "$(cat "$DIR/notary-issuer-id.txt")" 2>&1 | head -5; then
    ok "Apple accepted the key. (An empty history is expected before your first submission.)"
  else
    warn "Apple rejected the key. Check the Key ID and Issuer ID, and that the role is Developer or higher."
  fi
}

cmd_secrets() {
  step "Pushing secrets to $REPO"
  gh repo view "$REPO" > /dev/null 2>&1 || {
    echo "  $REPO does not exist or you cannot see it. Create it first." >&2
    exit 1
  }
  for f in developerID.p12 p12-password.txt notary.p8 notary-key-id.txt notary-issuer-id.txt; do
    [ -f "$DIR/$f" ] || { echo "  Missing $DIR/$f — run the cert and notary steps first." >&2; exit 1; }
  done

  base64 -i "$DIR/developerID.p12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO"
  gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO" < "$DIR/p12-password.txt"
  printf '%s' "$IDENTITY" | gh secret set MACOS_SIGNING_IDENTITY --repo "$REPO"
  gh secret set NOTARY_PRIVATE_KEY --repo "$REPO" < "$DIR/notary.p8"
  gh secret set NOTARY_KEY_ID --repo "$REPO" < "$DIR/notary-key-id.txt"
  gh secret set NOTARY_ISSUER_ID --repo "$REPO" < "$DIR/notary-issuer-id.txt"
  ok "Set six secrets on $REPO"
  gh secret list --repo "$REPO"
  echo
  echo "  HOMEBREW_TAP_TOKEN is optional: a fine-grained PAT with contents:write on"
  echo "  flexpa/homebrew-tap. Without it the release still publishes; only the cask bump is skipped."
}

cmd_verify() {
  step "Signing identity"
  if security find-identity -v -p codesigning | grep "Developer ID Application.*$TEAM_ID"; then
    ok "present"
  else
    warn "no Developer ID Application certificate for $TEAM_ID — run: $0 cert"
  fi

  step "Notary key"
  if [ -f "$DIR/notary.p8" ]; then
    ok "saved in $DIR"
  else
    warn "missing — run: $0 notary"
  fi

  step "Repository secrets"
  if gh repo view "$REPO" > /dev/null 2>&1; then
    gh secret list --repo "$REPO" 2>/dev/null || warn "cannot list secrets"
  else
    warn "$REPO does not exist yet"
  fi
}

case "${1:-verify}" in
  cert) cmd_cert ;;
  notary) cmd_notary ;;
  secrets) cmd_secrets ;;
  verify) cmd_verify ;;
  *) echo "usage: $0 {cert|notary|secrets|verify}" >&2; exit 2 ;;
esac

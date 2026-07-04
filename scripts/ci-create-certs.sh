#!/usr/bin/env bash
# scripts/ci-create-certs.sh
#
# Step-by-step guide to create the Apple signing certificates needed for
# Hermit CI builds. Run this BEFORE ci-secrets-export.sh.
#
# What this creates:
#   1. Certificate Signing Request (CSR) — needed to request certs from Apple
#   2. Instructions to create Developer ID Application cert (macOS DMG)
#   3. Instructions to create Apple Distribution cert (iPad TestFlight)
#   4. Installs both certs into your login keychain
#
# Usage:
#   chmod +x scripts/ci-create-certs.sh
#   ./scripts/ci-create-certs.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

header()  { echo; echo -e "${BOLD}${BLUE}══ $1 ══${RESET}"; echo; }
step()    { echo -e "${BOLD}▶ $1${RESET}"; }
info()    { echo -e "  ${BLUE}ℹ${RESET}  $1"; }
success() { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
pause()   { echo -e "  ${YELLOW}Press Enter when done...${RESET}"; read -r; }

echo -e "${BOLD}Hermit CI Certificate Setup${RESET}"
echo "This script walks you through creating the two Apple signing"
echo "certificates needed for CI builds."
echo

# ── Check existing certs ─────────────────────────────────────────────────────

header "Checking Existing Certificates"

DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)
APPLE_DIST=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Distribution" || true)

if [ -n "$DEV_ID" ]; then
  success "Developer ID Application already installed:"
  echo "  $DEV_ID"
else
  warn "Developer ID Application — NOT found (needs to be created)"
fi

if [ -n "$APPLE_DIST" ]; then
  success "Apple Distribution already installed:"
  echo "  $APPLE_DIST"
else
  warn "Apple Distribution — NOT found (needs to be created)"
fi

[ -n "$DEV_ID" ] && [ -n "$APPLE_DIST" ] && {
  success "Both certificates already installed. Run ci-secrets-export.sh next."
  exit 0
}

# ── Generate CSR ─────────────────────────────────────────────────────────────

header "Step 1: Generate a Certificate Signing Request (CSR)"

info "Apple requires a CSR to prove you control the private key."
info "We generate ONE CSR and use it for both certificates."

CSR_PATH="$HOME/Desktop/HermitCI-CertificateRequest.certSigningRequest"
KEY_PATH="$HOME/Desktop/HermitCI-private.key"

if [ -f "$CSR_PATH" ]; then
  warn "CSR already exists at $CSR_PATH — using it"
else
  info "Enter the email address on your Apple Developer account:"
  echo -n "  Email: "
  read -r APPLE_EMAIL

  info "Generating CSR and private key..."
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$KEY_PATH" \
    -out "$CSR_PATH" \
    -subj "/emailAddress=${APPLE_EMAIL}/CN=Hermit CI/O=Hermit CI/C=US"

  success "CSR created: $CSR_PATH"
  success "Private key: $KEY_PATH"
  warn    "Keep $KEY_PATH safe — you need it to install the downloaded certs"
fi

open "$(dirname $CSR_PATH)"
echo
info "The CSR file is now open in Finder."
pause

# ── Developer ID Application ─────────────────────────────────────────────────

if [ -z "$DEV_ID" ]; then

  header "Step 2a: Create Developer ID Application Certificate (macOS)"

  info "This certificate signs the macOS .app for distribution outside the App Store."
  info ""
  info "Steps:"
  info "  1. Open this URL in your browser:"
  echo ""
  echo -e "     ${BLUE}https://developer.apple.com/account/resources/certificates/add${RESET}"
  echo ""
  info "  2. Select: ${BOLD}Developer ID Application${RESET}"
  info "     (Under the 'Software' section — not 'Services')"
  info "  3. Click Continue"
  info "  4. When asked for a CSR, upload: ${CSR_PATH}"
  info "  5. Click Continue → Download the .cer file"
  info "  6. Save it to your Desktop as: ${BOLD}developer_id_application.cer${RESET}"
  echo ""

  open "https://developer.apple.com/account/resources/certificates/add"
  pause

  CER_PATH=""
  for candidate in \
    "$HOME/Desktop/developer_id_application.cer" \
    "$HOME/Downloads/developer_id_application.cer" \
    "$HOME/Downloads/developerID_application.cer"; do
    [ -f "$candidate" ] && CER_PATH="$candidate" && break
  done

  if [ -z "$CER_PATH" ]; then
    warn "Could not auto-find the .cer file. Enter the path:"
    echo -n "  Path to downloaded .cer: "
    read -r CER_PATH
    CER_PATH="${CER_PATH/#\~/$HOME}"
  fi

  info "Installing certificate into your keychain..."
  # Convert .cer + private key into a .p12, then import
  openssl x509 -in "$CER_PATH" -inform DER -out /tmp/devid.pem
  openssl pkcs12 -export \
    -inkey "$KEY_PATH" \
    -in /tmp/devid.pem \
    -out /tmp/devid.p12 \
    -passout pass:hermitci-temp \
    -name "Developer ID Application (Hermit CI)"
  security import /tmp/devid.p12 \
    -k ~/Library/Keychains/login.keychain-db \
    -P hermitci-temp \
    -T /usr/bin/codesign \
    -T /usr/bin/security
  rm /tmp/devid.pem /tmp/devid.p12

  security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 \
    && success "Developer ID Application certificate installed!" \
    || warn "Certificate not found after import — check the steps above"

fi

# ── Apple Distribution ───────────────────────────────────────────────────────

if [ -z "$APPLE_DIST" ]; then

  header "Step 2b: Create Apple Distribution Certificate (iPad)"

  info "This certificate signs the iPad .ipa for TestFlight and App Store."
  info ""
  info "Steps:"
  info "  1. Open this URL in your browser (same page, different type):"
  echo ""
  echo -e "     ${BLUE}https://developer.apple.com/account/resources/certificates/add${RESET}"
  echo ""
  info "  2. Select: ${BOLD}Apple Distribution${RESET}"
  info "     (Under the 'Software' section)"
  info "  3. Click Continue"
  info "  4. Upload the same CSR: ${CSR_PATH}"
  info "  5. Click Continue → Download the .cer file"
  info "  6. Save it to your Desktop as: ${BOLD}apple_distribution.cer${RESET}"
  echo ""

  open "https://developer.apple.com/account/resources/certificates/add"
  pause

  DIST_CER_PATH=""
  for candidate in \
    "$HOME/Desktop/apple_distribution.cer" \
    "$HOME/Downloads/apple_distribution.cer"; do
    [ -f "$candidate" ] && DIST_CER_PATH="$candidate" && break
  done

  if [ -z "$DIST_CER_PATH" ]; then
    warn "Could not auto-find the .cer file. Enter the path:"
    echo -n "  Path to downloaded .cer: "
    read -r DIST_CER_PATH
    DIST_CER_PATH="${DIST_CER_PATH/#\~/$HOME}"
  fi

  info "Installing certificate into your keychain..."
  openssl x509 -in "$DIST_CER_PATH" -inform DER -out /tmp/dist.pem
  openssl pkcs12 -export \
    -inkey "$KEY_PATH" \
    -in /tmp/dist.pem \
    -out /tmp/dist.p12 \
    -passout pass:hermitci-temp \
    -name "Apple Distribution (Hermit CI)"
  security import /tmp/dist.p12 \
    -k ~/Library/Keychains/login.keychain-db \
    -P hermitci-temp \
    -T /usr/bin/codesign \
    -T /usr/bin/security
  rm /tmp/dist.pem /tmp/dist.p12

  security find-identity -v -p codesigning 2>/dev/null | grep "Apple Distribution" | head -1 \
    && success "Apple Distribution certificate installed!" \
    || warn "Certificate not found after import — check the steps above"

fi

# ── Verify ───────────────────────────────────────────────────────────────────

header "Verification"

echo "Installed signing identities:"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /'

echo ""
success "Certificates are ready. Run the next step:"
echo ""
echo -e "  ${BOLD}./scripts/ci-secrets-export.sh${RESET}"
echo ""
info "When ci-secrets-export.sh asks for the .p12 files, re-export them"
info "from Keychain Access with a password you choose (not the temp one"
info "used during install). Right-click the cert → Export → .p12"
echo ""
warn "Clean up the private key from your Desktop when done:"
echo "  rm $KEY_PATH $CSR_PATH"

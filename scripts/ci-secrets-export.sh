#!/usr/bin/env bash
# scripts/ci-secrets-export.sh
#
# Interactive guide to export every secret needed for Hermit CI builds.
# Produces ready-to-paste values for all GitHub Actions secrets.
#
# Usage:
#   chmod +x scripts/ci-secrets-export.sh
#   ./scripts/ci-secrets-export.sh
#
# What this exports:
#   macOS DMG (native-macos job):
#     APPLE_DEV_ID_CERT_P12          Developer ID Application cert
#     APPLE_DEV_ID_CERT_PASSWORD     cert export password
#     APPLE_NOTARY_KEY_ID            App Store Connect API key ID
#     APPLE_NOTARY_KEY_ISSUER        App Store Connect issuer UUID
#     APPLE_NOTARY_KEY_P8            App Store Connect API key contents
#
#   iPad IPA (native-ipad job):
#     APPLE_DIST_CERT_P12            Apple Distribution cert
#     APPLE_DIST_CERT_PASSWORD       cert export password
#     APPLE_IPAD_PROVISIONING_PROFILE  mobileprovision for iPad
#
#   Shared:
#     APPLE_TEAM_ID                  10-char Team ID
#     APPLE_BUNDLE_ID                production bundle ID
#
# Where to add them:
#   https://github.com/hashneo/hermit/settings/secrets/actions

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

header()  { echo; echo -e "${BOLD}${BLUE}══ $1 ══${RESET}"; echo; }
step()    { echo -e "${BOLD}▶ $1${RESET}"; }
info()    { echo -e "  ${BLUE}ℹ${RESET}  $1"; }
success() { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
secret()  {
  local name="$1" value="$2"
  echo
  echo -e "  ${BOLD}Secret name:${RESET}  ${GREEN}${name}${RESET}"
  echo -e "  ${BOLD}Value:${RESET}"
  echo "  $value"
  echo
  if command -v pbcopy >/dev/null 2>&1; then
    echo "$value" | pbcopy
    echo -e "  ${GREEN}(copied to clipboard)${RESET}"
  fi
  echo -e "  ${YELLOW}Add at: https://github.com/hashneo/hermit/settings/secrets/actions/new${RESET}"
  echo -e "  Press Enter to continue..."
  read -r
}
OUTPUT_FILE="/tmp/hermit-ci-secrets-$(date +%Y%m%d-%H%M%S).txt"

echo -e "${BOLD}Hermit CI Secrets Export${RESET}"
echo "Outputs will also be saved to: ${OUTPUT_FILE}"
echo "(Delete this file when done — it contains sensitive values)"
echo

# ── Prerequisite checks ──────────────────────────────────────────────────────

header "Prerequisite Checks"

MISSING=0
for cmd in security openssl xcrun base64 python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    success "$cmd found"
  else
    warn "$cmd NOT found — some steps may fail"
    MISSING=$((MISSING+1))
  fi
done

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools not installed. Run: xcode-select --install"
  MISSING=$((MISSING+1))
fi

[ $MISSING -gt 0 ] && warn "Some prerequisites missing — fix before continuing" || success "All prerequisites found"
echo -e "  Press Enter to continue..."
read -r

# ── Team ID ──────────────────────────────────────────────────────────────────

header "Step 1: Apple Developer Team ID"

info "Find your Team ID at:"
info "  https://developer.apple.com/account → Membership Details → Team ID"
info "  OR: look in Xcode → Settings → Accounts → your Apple ID → Team"
info ""
info "Auto-detecting from your signing certificates..."

TEAM_ID=""
TEAM_ID=$(security find-certificate -a -p /Library/Keychains/System.keychain \
  2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
  | grep -oE 'OU=[A-Z0-9]{10}' | head -1 | cut -d= -f2 || true)

if [ -z "$TEAM_ID" ]; then
  TEAM_ID=$(security find-certificate -a -p ~/Library/Keychains/login.keychain-db \
    2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[A-Z0-9]{10}' | head -1 | cut -d= -f2 || true)
fi

if [ -n "$TEAM_ID" ]; then
  success "Detected Team ID: ${TEAM_ID}"
else
  echo -n "  Enter your 10-character Team ID: "
  read -r TEAM_ID
fi

echo "APPLE_TEAM_ID=${TEAM_ID}" >> "$OUTPUT_FILE"
secret "APPLE_TEAM_ID" "$TEAM_ID"

# ── Bundle ID ────────────────────────────────────────────────────────────────

header "Step 2: Bundle ID"

BUNDLE_ID=""
if [ -f "hermit-native/Local.xcconfig" ]; then
  BUNDLE_ID=$(grep -E '^HERMIT_BUNDLE_ID\s*=' hermit-native/Local.xcconfig \
    | head -1 | sed 's/.*=[ \t]*//' | tr -d '[:space:]' || true)
fi

if [ -n "$BUNDLE_ID" ] && ! echo "$BUNDLE_ID" | grep -q "yourname"; then
  success "Detected bundle ID from Local.xcconfig: ${BUNDLE_ID}"
else
  info "Enter the production bundle ID for the Hermit app."
  info "This must be registered in your Apple Developer account."
  info "Example: com.mycompany.hermit-native"
  echo -n "  Bundle ID: "
  read -r BUNDLE_ID
fi

echo "APPLE_BUNDLE_ID=${BUNDLE_ID}" >> "$OUTPUT_FILE"
secret "APPLE_BUNDLE_ID" "$BUNDLE_ID"

# ── Developer ID Application certificate (macOS DMG) ────────────────────────

header "Step 3: Developer ID Application Certificate (macOS DMG)"

info "This certificate signs the macOS .app for distribution outside the App Store."
info ""
info "To export:"
info "  1. Open Keychain Access.app"
info "  2. Search for: 'Developer ID Application'"
info "  3. Right-click the certificate (not the private key) → Export"
info "  4. Save as: /tmp/developer-id-application.p12"
info "  5. Set a strong export password when prompted"
info ""
info "OR run this to list available Developer ID certs:"
echo ""
security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" \
  | sed 's/^/  /' || echo "  (none found in login keychain)"
echo ""

P12_PATH=""
while [ ! -f "$P12_PATH" ]; do
  echo -n "  Path to exported Developer ID Application .p12: "
  read -r P12_PATH
  P12_PATH="${P12_PATH/#\~/$HOME}"
  [ -f "$P12_PATH" ] || warn "File not found: $P12_PATH"
done

echo -n "  Export password: "
read -rs DEV_ID_PASS
echo

# Verify the p12 can be read
if openssl pkcs12 -in "$P12_PATH" -passin "pass:$DEV_ID_PASS" -noout 2>/dev/null; then
  success "Certificate verified successfully"
else
  warn "Could not verify certificate with that password — double-check"
fi

DEV_ID_B64=$(base64 -i "$P12_PATH")
echo "APPLE_DEV_ID_CERT_P12=${DEV_ID_B64}" >> "$OUTPUT_FILE"
echo "APPLE_DEV_ID_CERT_PASSWORD=${DEV_ID_PASS}" >> "$OUTPUT_FILE"

secret "APPLE_DEV_ID_CERT_P12" "$DEV_ID_B64"
secret "APPLE_DEV_ID_CERT_PASSWORD" "$DEV_ID_PASS"

# ── Apple Distribution certificate (iPad IPA) ────────────────────────────────

header "Step 4: Apple Distribution Certificate (iPad IPA)"

info "This certificate signs the iPad .ipa for App Store / TestFlight distribution."
info ""
info "To create (if you don't have one):"
info "  1. developer.apple.com → Certificates → + → Apple Distribution"
info "  2. Follow the CSR instructions to generate and download"
info "  3. Double-click the .cer to add to Keychain"
info ""
info "To export from Keychain:"
info "  1. Open Keychain Access.app"
info "  2. Search for: 'Apple Distribution'"
info "  3. Right-click the certificate → Export"
info "  4. Save as: /tmp/apple-distribution.p12"
info "  5. Set a strong export password"
info ""
security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Distribution" \
  | sed 's/^/  /' || echo "  (none found)"
echo ""

P12_DIST_PATH=""
while [ ! -f "$P12_DIST_PATH" ]; do
  echo -n "  Path to exported Apple Distribution .p12: "
  read -r P12_DIST_PATH
  P12_DIST_PATH="${P12_DIST_PATH/#\~/$HOME}"
  [ -f "$P12_DIST_PATH" ] || warn "File not found: $P12_DIST_PATH"
done

echo -n "  Export password: "
read -rs DIST_PASS
echo

if openssl pkcs12 -in "$P12_DIST_PATH" -passin "pass:$DIST_PASS" -noout 2>/dev/null; then
  success "Certificate verified successfully"
else
  warn "Could not verify certificate with that password"
fi

DIST_B64=$(base64 -i "$P12_DIST_PATH")
echo "APPLE_DIST_CERT_P12=${DIST_B64}" >> "$OUTPUT_FILE"
echo "APPLE_DIST_CERT_PASSWORD=${DIST_PASS}" >> "$OUTPUT_FILE"

secret "APPLE_DIST_CERT_P12" "$DIST_B64"
secret "APPLE_DIST_CERT_PASSWORD" "$DIST_PASS"

# ── iPad Provisioning Profile ────────────────────────────────────────────────

header "Step 5: iPad Provisioning Profile"

info "This profile authorises the bundle ID to run on App Store / TestFlight."
info ""
info "To create:"
info "  1. developer.apple.com → Profiles → + → App Store"
info "  2. Select App ID: ${BUNDLE_ID} (must be registered first)"
info "  3. Select your Apple Distribution certificate"
info "  4. Name it: 'Hermit iPad Distribution'"
info "  5. Download the .mobileprovision file"
info ""
info "OR in Xcode (easier):"
info "  1. Open hermit-native/HermitNative.xcodeproj"
info "  2. Select the HermitNative target → Signing & Capabilities"
info "  3. Set Team to your team, enable Automatically manage signing"
info "  4. Switch to Release configuration"
info "  5. The profile is auto-created and stored in:"
info "     ~/Library/MobileDevice/Provisioning Profiles/"
info ""

PROFILE_PATH=""
while [ ! -f "$PROFILE_PATH" ]; do
  echo -n "  Path to .mobileprovision file: "
  read -r PROFILE_PATH
  PROFILE_PATH="${PROFILE_PATH/#\~/$HOME}"
  [ -f "$PROFILE_PATH" ] || warn "File not found: $PROFILE_PATH"
done

# Extract and show profile info
PROFILE_UUID=$(security cms -D -i "$PROFILE_PATH" 2>/dev/null \
  | python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print(d['UUID'])" 2>/dev/null || true)
PROFILE_NAME=$(security cms -D -i "$PROFILE_PATH" 2>/dev/null \
  | python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print(d['Name'])" 2>/dev/null || true)
PROFILE_EXPIRY=$(security cms -D -i "$PROFILE_PATH" 2>/dev/null \
  | python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print(d.get('ExpirationDate','unknown'))" 2>/dev/null || true)

success "Profile: ${PROFILE_NAME}"
info    "UUID:    ${PROFILE_UUID}"
info    "Expires: ${PROFILE_EXPIRY}"

PROFILE_B64=$(base64 -i "$PROFILE_PATH")
echo "APPLE_IPAD_PROVISIONING_PROFILE=${PROFILE_B64}" >> "$OUTPUT_FILE"

secret "APPLE_IPAD_PROVISIONING_PROFILE" "$PROFILE_B64"

# ── App Store Connect API Key ────────────────────────────────────────────────

header "Step 6: App Store Connect API Key (notarization + TestFlight upload)"

info "One key covers both macOS notarization and TestFlight upload."
info ""
info "To create:"
info "  1. appstoreconnect.apple.com → Users and Access"
info "  2. Integrations → App Store Connect API"
info "  3. Click + → Name: 'Hermit CI' → Role: Developer"
info "  4. Download the .p8 file (only downloadable ONCE)"
info "  5. Note the Key ID (shown in the list) and Issuer ID (at the top)"
info ""

echo -n "  App Store Connect API Key ID (e.g. ABC123DEFG): "
read -r NOTARY_KEY_ID

echo -n "  App Store Connect Issuer ID (UUID format): "
read -r NOTARY_ISSUER

P8_PATH=""
while [ ! -f "$P8_PATH" ]; do
  echo -n "  Path to downloaded .p8 file: "
  read -r P8_PATH
  P8_PATH="${P8_PATH/#\~/$HOME}"
  [ -f "$P8_PATH" ] || warn "File not found: $P8_PATH"
done

P8_CONTENTS=$(cat "$P8_PATH")

echo "APPLE_NOTARY_KEY_ID=${NOTARY_KEY_ID}" >> "$OUTPUT_FILE"
echo "APPLE_NOTARY_KEY_ISSUER=${NOTARY_ISSUER}" >> "$OUTPUT_FILE"
echo "APPLE_NOTARY_KEY_P8=${P8_CONTENTS}" >> "$OUTPUT_FILE"

secret "APPLE_NOTARY_KEY_ID" "$NOTARY_KEY_ID"
secret "APPLE_NOTARY_KEY_ISSUER" "$NOTARY_ISSUER"
secret "APPLE_NOTARY_KEY_P8" "$P8_CONTENTS"

# ── Summary ──────────────────────────────────────────────────────────────────

header "Complete — Summary"

echo -e "${BOLD}All 10 secrets to add at:${RESET}"
echo -e "  ${BLUE}https://github.com/hashneo/hermit/settings/secrets/actions${RESET}"
echo ""
echo -e "${BOLD}macOS DMG (native-macos job):${RESET}"
echo "  APPLE_DEV_ID_CERT_P12"
echo "  APPLE_DEV_ID_CERT_PASSWORD"
echo "  APPLE_NOTARY_KEY_ID"
echo "  APPLE_NOTARY_KEY_ISSUER"
echo "  APPLE_NOTARY_KEY_P8"
echo ""
echo -e "${BOLD}iPad IPA (native-ipad job):${RESET}"
echo "  APPLE_DIST_CERT_P12"
echo "  APPLE_DIST_CERT_PASSWORD"
echo "  APPLE_IPAD_PROVISIONING_PROFILE"
echo ""
echo -e "${BOLD}Shared by both:${RESET}"
echo "  APPLE_TEAM_ID          ${TEAM_ID}"
echo "  APPLE_BUNDLE_ID        ${BUNDLE_ID}"
echo ""
echo -e "${YELLOW}All values saved to: ${OUTPUT_FILE}${RESET}"
echo -e "${RED}${BOLD}⚠  Delete this file after adding the secrets to GitHub:${RESET}"
echo -e "${RED}   rm ${OUTPUT_FILE}${RESET}"
echo ""
success "Done!"

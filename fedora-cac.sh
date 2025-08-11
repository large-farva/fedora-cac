#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Fedora DoD CAC One-Shot Setup
# - Installs smart card stack (REQ_PKGS)
# - Enables pcscd.socket
# - Fetches + installs DoD certificate bundle into system trust
# - (Optional) registers OpenSC in user NSS DBs for Firefox/Chromium
# -------------------------------------------------------------------

SCRIPT_VERSION="1.2"
CERTS_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_v5-6_dod.zip"

CAC_DIR="$HOME/.cac"
CERTS_DIR="$CAC_DIR/certs"
LOGS_DIR="$CAC_DIR/logs"
RUN_STAMP="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOGS_DIR/fedora-cac-setup_${RUN_STAMP}.log"
LOG_PREFIX="[fedora-cac]"

REQ_PKGS=(
  pcsc-lite
  pcsc-lite-ccid
  opensc
  p11-kit
  p11-kit-trust
  p11-kit-tools
  nss-tools
  ca-certificates
  unzip
  openssl
  curl
  pcsc-tools # optional, but useful for verification
)

# -----------------------------
# Pre-flight
# -----------------------------
mkdir -p "$CERTS_DIR" "$LOGS_DIR"

# Log everything from this point
exec > >(tee -a "$LOG_FILE") 2>&1

echo "$LOG_PREFIX DoD CAC setup starting (v$SCRIPT_VERSION)…"

# Fedora-only guard
if ! command -v dnf >/dev/null 2>&1 || [[ ! -f /etc/fedora-release ]]; then
  echo "$LOG_PREFIX ERROR: This script supports Fedora (dnf) only."
  echo "$LOG_PREFIX Detected: dnf present? $(command -v dnf >/dev/null && echo yes || echo no), /etc/fedora-release present? $( [[ -f /etc/fedora-release ]] && echo yes || echo no )"
  exit 1
fi

# -----------------------------
# Helpers
# -----------------------------
pkg_install() {
  echo "$LOG_PREFIX Installing required packages with dnf…"
  sudo dnf -y install "${REQ_PKGS[@]}"
}

enable_pcscd() {
  echo "$LOG_PREFIX Enabling and starting pcscd.socket…"
  sudo systemctl enable --now pcscd.socket
}

install_dod_certs() {
  echo "$LOG_PREFIX Downloading DoD PKI bundle…"
  local zip="$CERTS_DIR/dod_${RUN_STAMP}.zip"
  curl -fsSL "$CERTS_URL" -o "$zip"

  echo "$LOG_PREFIX Extracting ZIP to $CERTS_DIR…"
  unzip -q -o "$zip" -d "$CERTS_DIR"

  # Locate a .p7b/.p7c inside CERTS_DIR
  local p7b
  p7b="$(find "$CERTS_DIR" -maxdepth 2 -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | head -n1 || true)"
  if [[ -z "${p7b:-}" ]]; then
    echo "$LOG_PREFIX ERROR: Couldn’t locate a PKCS#7 (.p7b/.p7c) file in the downloaded bundle."
    return 1
  fi
  echo "$LOG_PREFIX Found PKCS#7 bundle: $p7b"

  local pem="$CERTS_DIR/dod_bundle_${RUN_STAMP}.pem"
  echo "$LOG_PREFIX Converting PKCS#7 to PEM…"
  # Try DER first, then fallback to auto/PEM
  if ! openssl pkcs7 -inform DER -print_certs -in "$p7b" -out "$pem" 2>/dev/null; then
    openssl pkcs7 -print_certs -in "$p7b" -out "$pem"
  fi

  if [[ ! -s "$pem" ]]; then
    echo "$LOG_PREFIX ERROR: PEM conversion failed."
    return 1
  fi

  echo "$LOG_PREFIX Splitting PEM into individual certificates under $CERTS_DIR…"
  # Clean any old split artifacts from prior runs (only our naming pattern)
  rm -f "$CERTS_DIR"/cert-*.pem 2>/dev/null || true
  csplit -s -z -f "$CERTS_DIR/cert-" "$pem" '/-----BEGIN CERTIFICATE-----/' '{*}'
  # Ensure all split files end with .pem for clarity
  for f in "$CERTS_DIR"/cert-*; do
    [[ -f "$f" ]] && mv -f "$f" "${f}.pem"
  done

  echo "$LOG_PREFIX Installing DoD certificates into system trust (p11-kit)…"
  shopt -s nullglob
  local count=0
  for c in "$CERTS_DIR"/cert-*.pem; do
    grep -q "BEGIN CERTIFICATE" "$c" || continue
    sudo trust anchor "$c" || true
    ((count++))
  done
  echo "$LOG_PREFIX Installed/updated ~$count DoD certificate(s) in system trust."

  echo "$LOG_PREFIX Verifying DoD entries (sample)…"
  trust list | grep -iE 'DoD|Department of Defense' || true
}

nss_add_opensc_module_if_missing() {
  local dbdir="$1"
  local label="OpenSC PKCS#11"
  local lib="/usr/lib64/pkcs11/opensc-pkcs11.so"

  command -v modutil >/dev/null 2>&1 || return 0
  [[ -f "$lib" ]] || return 0

  if modutil -dbdir "$dbdir" -list 2>/dev/null | grep -q "$label"; then
    echo "$LOG_PREFIX NSS: module already present in $dbdir"
  else
    echo "$LOG_PREFIX NSS: adding OpenSC module to $dbdir"
    modutil -dbdir "$dbdir" -add "$label" -libfile "$lib" -force || true
  fi
}

configure_legacy_nss_modules() {
  echo "$LOG_PREFIX (optional) Registering OpenSC in user NSS DBs…"

  # Chromium/Chrome NSS DB
  local chrome_db="sql:$HOME/.pki/nssdb"
  mkdir -p "$HOME/.pki/nssdb"
  nss_add_opensc_module_if_missing "$chrome_db"

  # Firefox profiles
  local ff_dir="$HOME/.mozilla/firefox"
  if [[ -d "$ff_dir" ]]; then
    while IFS= read -r -d '' prof; do
      local db="sql:$prof"
      nss_add_opensc_module_if_missing "$db"
    done < <(find "$ff_dir" -maxdepth 1 -type d -name "*.default*" -print0 2>/dev/null)
  fi
}

final_notes() {
  echo
  echo "------------------------------------------------------------------"
  echo "$LOG_PREFIX Setup complete (v$SCRIPT_VERSION)."
  echo
  echo "Artifacts saved to:"
  echo "  - Certificates: $CERTS_DIR"
  echo "  - Log (this run): $LOG_FILE"
  echo
  echo "Test steps:"
  echo "  1) Plug in your CAC reader and card."
  echo "  2) Run:  pcsc_scan    (from pcsc-tools) to confirm the card is detected."
  echo "  3) Open Firefox or Chromium (RPM builds preferred over Flatpak) and try a CAC-gated site."
  echo
  echo "Troubleshooting tips:"
  echo "  - If the reader isn’t detected, check:  systemctl status pcscd.socket"
  echo "  - For Flatpak browsers, host PKCS#11 visibility can be limited."
  echo "    Prefer the RPM builds for CAC use on Fedora."
  echo "------------------------------------------------------------------"
}

# -----------------------------
# Execution
# -----------------------------
pkg_install
enable_pcscd
install_dod_certs

# Optional legacy NSS registration (uncomment to enable by default)
# configure_legacy_nss_modules

echo "$LOG_PREFIX Done."
final_notes


#!/usr/bin/env bash
set -Eeuo pipefail  # -E (errtrace) so ERR trap fires in subshells

# -------------------------------------------------------------------
# Fedora DoD CAC One-Shot Setup (v1.3, instrumented)
# - Fedora (dnf) only
# - Logs:    ~/.cac/logs/fedora-cac-setup_YYYY-MM-DD_HH-MM-SS.log
# - Artifacts: ~/.cac/certs/
# -------------------------------------------------------------------

SCRIPT_VERSION="1.3"

CERTS_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_v5-6_dod.zip"

CAC_DIR="$HOME/.cac"
CERTS_DIR="$CAC_DIR/certs"
LOGS_DIR="$CAC_DIR/logs"
RUN_STAMP="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOGS_DIR/fedora-cac-setup_${RUN_STAMP}.log"

LOG_PREFIX="[fedora-cac]"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # INFO or DEBUG
DEBUG_ENABLED=0
[[ "$LOG_LEVEL" == "DEBUG" ]] && DEBUG_ENABLED=1

REQ_PKGS=(
  pcsc-lite
  pcsc-lite-ccid
  opensc
  p11-kit
  p11-kit-trust
  nss-tools
  ca-certificates
  unzip
  openssl
  curl
  pcsc-tools
)

# ---------------- Logging ----------------
_ts() { date +"%Y-%m-%d %H:%M:%S"; }
log_i() { echo "$(_ts) $LOG_PREFIX [INFO]  $*"; }
log_w() { echo "$(_ts) $LOG_PREFIX [WARN]  $*"; }
log_e() { echo "$(_ts) $LOG_PREFIX [ERROR] $*"; }
log_d() {
  if [[ "$DEBUG_ENABLED" -eq 1 ]]; then
    echo "$(_ts) $LOG_PREFIX [DEBUG] $*"
  fi
}

# Ensure dirs; tee stdout/stderr to log
mkdir -p "$CERTS_DIR" "$LOGS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------- Traps ----------------
on_fail() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  log_e "Script failed (exit=$exit_code) near line $line."
  log_e "Last command: ${BASH_COMMAND:-unknown}"
  log_e "Full log: $LOG_FILE"
}
on_exit() {
  local ec=$?
  if [[ $ec -eq 0 ]]; then
    log_i "EXIT: normal completion."
  else
    log_e "EXIT: non-zero ($ec). See error lines above."
  fi
  exit $ec
}
on_abort() {
  log_e "Received interrupt/termination signal; aborting."
  exit 130
}
trap on_fail ERR
trap on_exit EXIT
trap on_abort INT TERM

# ---------------- Helpers ----------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log_e "Missing required command: $1"; exit 1; }
}

run() {
  log_d "\$ $*"
  if output="$("$@" 2>&1)"; then
    [[ -n "$output" ]] && log_d "$output"
    return 0
  else
    local rc=$?
    log_e "Command failed (exit=$rc): $*"
    [[ -n "$output" ]] && log_e "$output"
    return $rc
  fi
}

run_req() { run "$@" || { log_e "Required step failed: $*"; exit 1; }; }

fedora_guard() {
  if ! command -v dnf >/dev/null 2>&1 || [[ ! -f /etc/fedora-release ]]; then
    log_e "This script supports Fedora (dnf) only."
    log_e "Detected: dnf=$([[ -n "$(command -v dnf 2>/dev/null || true)" ]] && echo yes || echo no), /etc/fedora-release=$([[ -f /etc/fedora-release ]] && echo yes || echo no)"
    exit 1
  fi
}

preflight_summary() {
  log_i "==== PHASE: Preflight ===="
  log_i "DoD CAC setup starting (v$SCRIPT_VERSION)  LOG=$LOG_FILE"
  log_i "System summary:"
  run_req uname -a
  [[ -f /etc/fedora-release ]] && run_req cat /etc/fedora-release
  run_req dnf --version | head -n 1

  log_i "Checking network reachability for the DoD PKI bundle URL..."
  if curl -fsI "$CERTS_URL" >/dev/null 2>&1; then
    log_i "Network OK: HEAD succeeded."
  else
    log_w "HEAD failed; trying a small ranged GET..."
    curl -fsSL --range 0-128 "$CERTS_URL" >/dev/null 2>&1 || { log_e "Cannot reach $CERTS_URL"; exit 1; }
    log_i "Network OK: ranged GET succeeded."
  fi
  log_i "Preflight complete."
}

pkg_install() {
  log_i "==== PHASE: Package install ===="
  local missing=()
  for p in "${REQ_PKGS[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    log_i "All required packages already installed."
  else
    log_i "Installing missing packages: ${missing[*]}"
    run_req sudo dnf -y install "${missing[@]}"
  fi
  log_i "Package install complete."
}

enable_pcscd() {
  log_i "==== PHASE: pcscd ===="
  run_req sudo systemctl enable --now pcscd.socket
  run_req systemctl is-active pcscd.socket
  run_req systemctl is-enabled pcscd.socket
  log_i "pcscd.socket is enabled and active."
}

install_dod_certs() {
  log_i "==== PHASE: Certificates ===="
  local zip="$CERTS_DIR/dod_${RUN_STAMP}.zip"
  log_i "Downloading DoD PKI bundle to $zip ..."
  run_req curl -fsSL "$CERTS_URL" -o "$zip"

  log_i "Extracting ZIP to $CERTS_DIR..."
  run_req unzip -q -o "$zip" -d "$CERTS_DIR"

  local p7b
  p7b="$(find "$CERTS_DIR" -maxdepth 2 -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | head -n 1 || true)"
  [[ -n "${p7b:-}" ]] || { log_e "No .p7b/.p7c found in extracted bundle."; exit 1; }
  log_i "Found PKCS#7 bundle: $p7b"

  local pem="$CERTS_DIR/dod_bundle_${RUN_STAMP}.pem"
  log_i "Converting PKCS#7 to PEM (DER attempt, 30s timeout)..."
  if ! output="$(timeout 30s openssl pkcs7 -inform DER -print_certs -in "$p7b" -out "$pem" 2>&1)"; then
    log_w "DER conversion attempt failed: $output"
    log_i "Trying auto-detect (PEM) conversion (30s timeout)..."
    output="$(timeout 30s openssl pkcs7 -print_certs -in "$p7b" -out "$pem" 2>&1)" || { log_e "OpenSSL conversion failed: $output"; exit 1; }
  fi
  if [[ ! -s "$pem" ]]; then
    log_e "PEM conversion produced an empty file: $pem"
    exit 1
  fi
  local pem_size
  pem_size="$(wc -c < "$pem")"
  log_i "PEM created: $pem (${pem_size} bytes)"

  log_i "Counting existing DoD anchors (pre-install)..."
  local before_count
  before_count="$( (trust list 2>/dev/null | grep -iEc 'DoD|Department of Defense') || true )"
  log_i "Existing DoD-related trust entries: ${before_count:-0}"

  log_i "Splitting PEM into individual certificates..."
  run rm -f "$CERTS_DIR"/cert-*.pem || true
  run_req csplit -s -z -f "$CERTS_DIR/cert-" "$pem" '/-----BEGIN CERTIFICATE-----/' '{*}'
  for f in "$CERTS_DIR"/cert-*; do
    [[ -f "$f" ]] && mv -f "$f" "${f}.pem"
  done

  # Batch install with one sudo call to avoid hangs
  log_i "Preparing to install certificates into system trust (p11-kit)..."
  if ! sudo -n true 2>/dev/null; then
    log_i "Elevating privileges for anchor install (sudo)..."
    run_req sudo -v
  fi

  shopt -s nullglob
  mapfile -t _certs < <(
    for c in "$CERTS_DIR"/cert-*.pem; do
      if [[ -f "$c" ]] && grep -q "BEGIN CERTIFICATE" "$c"; then
        echo "$c"
      fi
    done
  )

  local total=${#_certs[@]}
  if (( total == 0 )); then
    log_w "No certificate files found after split; nothing to install."
  else
    log_i "Installing $total certificate(s) into system trust (batched)..."
    printf '%s\0' "${_certs[@]}" | sudo xargs -0 -r -n 50 trust anchor
  fi

  local after_count
  after_count="$( (trust list 2>/dev/null | grep -iEc 'DoD|Department of Defense') || true )"
  log_i "DoD-related trust entries now: ${after_count:-0} (before: ${before_count:-0})"

  log_i "Verification sample:"
  run trust list | grep -iE 'DoD|Department of Defense' | head -n 20 || true
  log_i "Certificates phase complete."
}

nss_add_opensc_module_if_missing() {
  local dbdir="$1"
  local label="OpenSC PKCS#11"
  local lib="/usr/lib64/pkcs11/opensc-pkcs11.so"

  if [[ ! -f "$lib" ]]; then
    log_w "OpenSC PKCS#11 not found at $lib; skipping NSS add."
    return 0
  fi
  need_cmd modutil

  if modutil -dbdir "$dbdir" -list 2>/dev/null | grep -q "$label"; then
    log_i "NSS: module already present in $dbdir"
  else
    log_i "NSS: adding OpenSC module to $dbdir"
    run modutil -dbdir "$dbdir" -add "$label" -libfile "$lib" -force || true
  fi
}

configure_legacy_nss_modules() {
  log_i "==== PHASE: NSS (optional) ===="
  run mkdir -p "$HOME/.pki/nssdb"
  nss_add_opensc_module_if_missing "sql:$HOME/.pki/nssdb"

  local ff_dir="$HOME/.mozilla/firefox"
  if [[ -d "$ff_dir" ]]; then
    while IFS= read -r -d '' prof; do
      nss_add_opensc_module_if_missing "sql:$prof"
    done < <(find "$ff_dir" -maxdepth 1 -type d -name "*.default*" -print0 2>/dev/null)
  else
    log_w "Firefox profile directory not found; skipping."
  fi
  log_i "NSS phase complete."
}

post_diagnostics() {
  log_i "==== PHASE: Diagnostics ===="
  run systemctl status pcscd.socket --no-pager
  run journalctl -u pcscd --since "1 hour ago" --no-pager | tail -n 100 || true
  if [[ -f /usr/lib64/pkcs11/opensc-pkcs11.so ]]; then
    log_i "OpenSC PKCS#11 present at /usr/lib64/pkcs11/opensc-pkcs11.so"
  else
    log_w "OpenSC PKCS#11 library NOT found at the expected path."
  fi
  if command -v timeout >/dev/null 2>&1 && command -v pcsc_scan >/dev/null 2>&1; then
  log_i "Capturing brief pcsc_scan sample (3s)..."
  if timeout 3s pcsc_scan >/dev/null 2>&1; then
    log_i "pcsc_scan sample captured."
  else
    # Exit 124 from timeout is expected; anything else we'll warn
    rc=$?
    if [[ $rc -eq 124 ]]; then
      log_i "pcsc_scan timed out after 3s (expected)."
    else
      log_w "pcsc_scan exited with code $rc (non-fatal)."
    fi
  fi
else
  log_w "Skipping pcsc_scan sample (timeout or pcsc_scan not available)."
fi
}

final_notes() {
  log_i "==== PHASE: Complete ===="
  log_i "Artifacts:"
  log_i "  - Certificates: $CERTS_DIR"
  log_i "  - Log (this run): $LOG_FILE"
  log_i "Test steps:"
  log_i "  1) Plug in your CAC reader and card."
  log_i "  2) Run:  pcsc_scan    (from pcsc-tools) to confirm the card is detected."
  log_i "  3) Open Firefox or Chromium (RPM builds preferred over Flatpak) and try a CAC-gated site."
  log_i "Troubleshooting tips:"
  log_i "  - If the reader is not detected, check:  systemctl status pcscd.socket"
  log_i "  - For Flatpak browsers, host PKCS#11 visibility can be limited; prefer RPM builds."
}

# ---------------- Execution ----------------
# Fail early if core tools are missing
need_cmd bash
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd curl
need_cmd openssl
need_cmd unzip
need_cmd csplit
need_cmd rpm
need_cmd systemctl
need_cmd trust
need_cmd dnf
need_cmd timeout
need_cmd xargs

fedora_guard
preflight_summary
pkg_install
enable_pcscd
install_dod_certs
# Optional legacy NSS registration (off by default)
# configure_legacy_nss_modules
post_diagnostics
final_notes


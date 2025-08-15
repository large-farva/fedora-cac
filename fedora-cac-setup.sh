#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Fedora DoD CAC One-Shot Setup (with enhanced logging)
# - Installs smart card stack (REQ_PKGS)
# - Enables pcscd.socket
# - Fetches + installs DoD certificate bundle into system trust
# - Optional user-profile NSS registration (Legacy - function present, off by default)
#
# Logs:
#   ~/.cac/logs/fedora-cac-setup_YYYY-MM-DD_HH-MM-SS.log
# Certs/artifacts:
#   ~/.cac/certs/
# -------------------------------------------------------------------

SCRIPT_VERSION="1.3"

CERTS_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_v5-6_dod.zip"

CAC_DIR="$HOME/.cac"
CERTS_DIR="$CAC_DIR/certs"
LOGS_DIR="$CAC_DIR/logs"
RUN_STAMP="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOGS_DIR/fedora-cac-setup_${RUN_STAMP}.log"

LOG_PREFIX="[fedora-cac]"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DEBUG_ENABLED=0
[[ "$LOG_LEVEL" == "DEBUG" ]] && DEBUG_ENABLED=1

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
  pcsc-tools
)

# --------------- Logging ---------------
_ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log_i(){ echo "$(_ts) $LOG_PREFIX [INFO]  $*" ; }
log_w(){ echo "$(_ts) $LOG_PREFIX [WARN]  $*" ; }
log_e(){ echo "$(_ts) $LOG_PREFIX [ERROR] $*" ; }
log_d(){ [[ $DEBUG_ENABLED -eq 1 ]] && echo "$(_ts) $LOG_PREFIX [DEBUG] $*"; }

# Stream everything to logfile (stdout+stderr)
mkdir -p "$CERTS_DIR" "$LOGS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# Failure trap (prints failing line and last command)
on_fail(){
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  log_e "Script failed (exit=$exit_code) near line $line."
  log_e "Last command: ${BASH_COMMAND:-unknown}"
  log_e "See diagnostics above. Full log: $LOG_FILE"
  exit $exit_code
}
trap on_fail ERR

# --------------- Helpers ---------------
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_e "Missing required command: $1"; exit 1; }
}

run(){
  # Run a command, log it, show exit code; does not stop on failure unless caller set -e
  log_d "\$ $*"
  if output="$("$@" 2>&1)"; then
    log_d "OK: $*"
    [[ -n "$output" ]] && log_d "$output"
    return 0
  else
    local rc=$?
    log_e "Command failed (exit=$rc): $*"
    [[ -n "$output" ]] && log_e "$output"
    return $rc
  fi
}

run_req(){
  # Same as run, but hard-fails the script on nonzero exit
  if ! run "$@"; then
    log_e "Required step failed. Aborting."
    exit 1
  fi
}

fedora_guard(){
  if ! command -v dnf >/dev/null 2>&1 || [[ ! -f /etc/fedora-release ]]; then
    log_e "This script supports Fedora (dnf) only."
    log_e "Detected: dnf=$(command -v dnf >/dev/null && echo yes || echo no), /etc/fedora-release=$( [[ -f /etc/fedora-release ]] && echo yes || echo no )"
    exit 1
  fi
}

preflight_summary(){
  log_i "DoD CAC setup starting (v$SCRIPT_VERSION)  LOG=$LOG_FILE"
  log_i "System summary:"
  run_req uname -a
  [[ -f /etc/fedora-release ]] && run_req cat /etc/fedora-release
  run_req dnf --version | head -n 1

  log_i "Checking network reachability for the DoD PKI bundle URL…"
  # HEAD is not guaranteed; use a small download range to verify
  if curl -fsI "$CERTS_URL" >/dev/null 2>&1; then
    log_i "Network OK: reachable."
  else
    log_w "HEAD failed; trying a small ranged GET…"
    if curl -fsSL --range 0-128 "$CERTS_URL" >/dev/null 2>&1; then
      log_i "Network OK: ranged GET succeeded."
    else
      log_e "Cannot reach the certificate bundle URL. Check network/proxy and try again."
      exit 1
    fi
  fi
}

pkg_install(){
  log_i "Installing required packages via dnf…"
  # Show which are missing
  missing=()
  for p in "${REQ_PKGS[@]}"; do
    if ! rpm -q "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log_i "All required packages already installed."
    return 0
  fi
  log_i "Missing packages: ${missing[*]}"
  run_req sudo dnf -y install "${missing[@]}"
}

enable_pcscd(){
  log_i "Enabling and starting pcscd.socket…"
  run_req sudo systemctl enable --now pcscd.socket
  run_req systemctl is-active pcscd.socket
  run_req systemctl is-enabled pcscd.socket
}

install_dod_certs(){
  log_i "Downloading DoD PKI bundle…"
  local zip="$CERTS_DIR/dod_${RUN_STAMP}.zip"
  run_req curl -fsSL "$CERTS_URL" -o "$zip"

  log_i "Extracting ZIP to $CERTS_DIR…"
  run_req unzip -q -o "$zip" -d "$CERTS_DIR"

  # Locate p7b/p7c
  local p7b
  p7b="$(find "$CERTS_DIR" -maxdepth 2 -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | head -n1 || true)"
  if [[ -z "${p7b:-}" ]]; then
    log_e "Couldn’t locate a PKCS#7 (.p7b/.p7c) file in the downloaded bundle."
    exit 1
  fi
  log_i "Found PKCS#7 bundle: $p7b"

  local pem="$CERTS_DIR/dod_bundle_${RUN_STAMP}.pem"
  log_i "Converting PKCS#7 to PEM…"
  if ! run openssl pkcs7 -inform DER -print_certs -in "$p7b" -out "$pem"; then
    run_req openssl pkcs7 -print_certs -in "$p7b" -out "$pem"
  fi
  [[ -s "$pem" ]] || { log_e "PEM conversion failed (empty file)."; exit 1; }

  # Count existing DoD anchors before installing (rough estimate)
  local before_count
  before_count="$(trust list | grep -iEc 'DoD|Department of Defense' || true)"
  log_d "Existing DoD-related trust entries before: $before_count"

  log_i "Splitting PEM into individual certs under $CERTS_DIR…"
  # Clean previous split artifacts from earlier runs
  run rm -f "$CERTS_DIR"/cert-*.pem
  run_req csplit -s -z -f "$CERTS_DIR/cert-" "$pem" '/-----BEGIN CERTIFICATE-----/' '{*}'
  for f in "$CERTS_DIR"/cert-*; do
    [[ -f "$f" ]] && mv -f "$f" "${f}.pem"
  done

  log_i "Installing DoD certificates into system trust (p11-kit)…"
  shopt -s nullglob
  local added=0
  for c in "$CERTS_DIR"/cert-*.pem; do
    grep -q "BEGIN CERTIFICATE" "$c" || continue
    # trust anchor is idempotent; if already present, it updates/keeps
    run sudo trust anchor "$c" || true
    ((added++))
  done
  log_i "Processed ~$added certificate files."

  local after_count
  after_count="$(trust list | grep -iEc 'DoD|Department of Defense' || true)"
  log_i "DoD-related trust entries now: $after_count (before: $before_count)"
  log_i "Verification sample:"
  run trust list | grep -iE 'DoD|Department of Defense' | head -n 20 || true
}

nss_add_opensc_module_if_missing(){
  local dbdir="$1"
  local label="OpenSC PKCS#11"
  local lib="/usr/lib64/pkcs11/opensc-pkcs11.so"

  if [[ ! -f "$lib" ]]; then
    log_w "OpenSC PKCS#11 library not found at $lib; skipping NSS add."
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

configure_legacy_nss_modules(){
  log_i "(optional) Registering OpenSC in user NSS DBs…"

  # Chromium/Chrome
  local chrome_db="sql:$HOME/.pki/nssdb"
  run mkdir -p "$HOME/.pki/nssdb"
  nss_add_opensc_module_if_missing "$chrome_db"

  # Firefox
  local ff_dir="$HOME/.mozilla/firefox"
  if [[ -d "$ff_dir" ]]; then
    while IFS= read -r -d '' prof; do
      local db="sql:$prof"
      nss_add_opensc_module_if_missing "$db"
    done < <(find "$ff_dir" -maxdepth 1 -type d -name "*.default*" -print0 2>/dev/null)
  else
    log_w "Firefox profile directory not found; skipping."
  fi
}

post_diagnostics(){
  log_i "---- Diagnostics ----"
  # pcscd status
  run systemctl status pcscd.socket --no-pager
  run journalctl -u pcscd --since "1 hour ago" --no-pager | tail -n 100 || true

  # OpenSC library present?
  if [[ -f /usr/lib64/pkcs11/opensc-pkcs11.so ]]; then
    log_i "OpenSC PKCS#11 library present at /usr/lib64/pkcs11/opensc-pkcs11.so"
  else
    log_w "OpenSC PKCS#11 library NOT found at expected path."
  fi

  # Quick reader/card probe (timeout to avoid hanging logs)
  if command -v timeout >/dev/null 2>&1 && command -v pcsc_scan >/dev/null 2>&1; then
    log_i "Capturing brief pcsc_scan sample (3s)…"
    run timeout 3s pcsc_scan || true
  else
    log_w "Skipping pcsc_scan sample (timeout or pcsc_scan not available)."
  fi
}

final_notes(){
  echo
  log_i "------------------------------------------------------------------"
  log_i "Setup complete (v$SCRIPT_VERSION)."
  log_i "Artifacts:"
  log_i "  - Certificates: $CERTS_DIR"
  log_i "  - Log (this run): $LOG_FILE"
  log_i ""
  log_i "Test steps:"
  log_i "  1) Plug in your CAC reader and card."
  log_i "  2) Run:  pcsc_scan    (from pcsc-tools) to confirm the card is detected."
  log_i "  3) Open Firefox or Chromium (RPM builds preferred over Flatpak) and try a CAC-gated site."
  log_i ""
  log_i "Troubleshooting tips:"
  log_i "  - If the reader isn’t detected, check:  systemctl status pcscd.socket"
  log_i "  - For Flatpak browsers, host PKCS#11 visibility can be limited."
  log_i "  - Prefer the RPM builds for CAC use on Fedora."
  log_i "------------------------------------------------------------------"
}

# --------------- Execution ---------------
need_cmd bash
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd curl
need_cmd openssl
need_cmd unzip
need_cmd rpm
need_cmd systemctl
need_cmd trust
need_cmd dnf

fedora_guard
preflight_summary
pkg_install
enable_pcscd
install_dod_certs

# Optional: per-profile NSS registration (leave commented unless needed)
# configure_legacy_nss_modules

post_diagnostics
final_notes

#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Fedora DoD CAC One-Shot Setup (v1.4.4)
#
# Terminal:
#   - Clean phase headers + compact step lines (OK/SKIP/FAIL)
#   - Spinner while (re)installing trust anchors
#   - Sudo password prompts appear on their own line
#   - Shows pcsc_scan(1) sample output in the terminal
#
# Log (verbose):
#   - ~/.cac/logs/fedora-cac-setup_YYYY-MM-DD_HH-MM-SS.log
#
# What this does:
#   1) Preflight checks (Fedora, network, tooling)
#   2) Install required packages (dnf)
#   3) Enable pcscd.socket
#   4) Clean previous split certs; download/convert DoD bundle
#   5) If DoD anchors exist: prompt to SKIP or REINSTALL (remove+add)
#   6) Install anchors if needed
#   7) Quick diagnostics (pcsc_scan sample printed to terminal)
# -------------------------------------------------------------------

SCRIPT_VERSION="1.4.4"
CERTS_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_v5-6_dod.zip"

# Workspace
CAC_DIR="$HOME/.cac"
CERTS_DIR="$CAC_DIR/certs"
LOGS_DIR="$CAC_DIR/logs"
RUN_STAMP="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOGS_DIR/fedora-cac-setup_${RUN_STAMP}.log"

# Required packages
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

# --- Create dirs and redirect stdout/stderr to the log (tidy terminal) ---
mkdir -p "$CERTS_DIR" "$LOGS_DIR"
TERM_FD="/dev/tty"
if [[ ! -e "$TERM_FD" || ! -w "$TERM_FD" ]]; then TERM_FD="/proc/self/fd/1"; fi
exec >>"$LOG_FILE" 2>&1

# Logging (to log file)
LOG_PREFIX="[fedora-cac]"
_ts() { date +"%Y-%m-%d %H:%M:%S"; }
log_i() { echo "$(_ts) $LOG_PREFIX [INFO]  $*"; }
log_w() { echo "$(_ts) $LOG_PREFIX [WARN]  $*"; }
log_e() { echo "$(_ts) $LOG_PREFIX [ERROR] $*"; }

# Minimal terminal UI (never pollutes the log)
ui()     { printf "%s\n" "$*" >"$TERM_FD"; }
phase()  { printf "\n== %s ==\n" "$*" >"$TERM_FD"; }
step()   { printf "  • %s ... " "$*" >"$TERM_FD"; }
ok()     { printf "OK\n"   >"$TERM_FD"; }
skip()   { printf "SKIP\n" >"$TERM_FD"; }
fail()   { printf "FAIL\n" >"$TERM_FD"; }

# Spinner
SPINNER_PID=""
start_spinner() {
  ( while :; do for c in '|' '/' '-' '\\'; do printf "%s" "$c" >"$TERM_FD"; sleep 0.1; printf "\b" >"$TERM_FD"; done; done ) & SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}
stop_spinner_ok()   { [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null || true; SPINNER_PID=""; ok; }
stop_spinner_fail() { [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null || true; SPINNER_PID=""; fail; }

# Traps
on_fail() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null || true
  log_e "Script failed (exit=$exit_code) near line $line."
  log_e "Last command: ${BASH_COMMAND:-unknown}"
  log_e "Full log: $LOG_FILE"
  fail
}
on_exit() {
  local ec=$?
  [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null || true
  if [[ $ec -eq 0 ]]; then ok; else fail; fi
  ui ""
  ui "Log: $LOG_FILE"
  exit $ec
}
on_abort() { [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null || true; log_e "Interrupted by user."; fail; ui "Log: $LOG_FILE"; exit 130; }
trap on_fail ERR
trap on_exit EXIT
trap on_abort INT TERM

# Helpers (log-only)
need_cmd() { command -v "$1" >/dev/null 2>&1 || { log_e "Missing required command: $1"; exit 1; }; }
run()     { log_i "\$ $*"; "$@"; }
run_req() { run "$@" || { log_e "Required step failed: $*"; exit 1; }; }
ask_yn() {
  local q="$1" ans
  printf "%s " "$q [y/N]:" >"$TERM_FD"
  read -r ans <"$TERM_FD" || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

fedora_guard() {
  if ! command -v dnf >/dev/null 2>&1 || [[ ! -f /etc/fedora-release ]]; then
    log_e "This script supports Fedora (dnf) only."
    ui "This script targets Fedora with dnf. See log for details."
    exit 1
  fi
}

preflight() {
  phase "Preflight"
  step "Environment checks"
  log_i "DoD CAC setup starting (v$SCRIPT_VERSION)  LOG=$LOG_FILE"
  need_cmd curl; need_cmd openssl; need_cmd unzip; need_cmd rpm; need_cmd systemctl; need_cmd trust; need_cmd grep
  local dnf_ver; dnf_ver="$(dnf --version 2>&1 | head -n 1 || true)"; [[ -n "$dnf_ver" ]] && log_i "$dnf_ver"
  ok

  step "Network reachability"
  if curl -fsI "$CERTS_URL" >/dev/null 2>&1; then
    log_i "Network OK: HEAD succeeded."
    ok
  else
    log_w "HEAD failed; trying a small ranged GET."
    if curl -fsSL --range 0-128 "$CERTS_URL" >/dev/null 2>&1; then
      log_i "Network OK: ranged GET succeeded."
      ok
    else
      log_e "Cannot reach the certificate bundle URL."
      fail; exit 1
    fi
  fi
}

pkg_install() {
  phase "Packages"
  local missing=()
  for p in "${REQ_PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=( "$p" ); done

  if ((${#missing[@]} == 0)); then
    step "Install required packages"
    log_i "All required packages already installed."
    skip
    return
  fi

  step "Install required packages"
  ui ""  # newline so sudo prompt is on its own line
  ui "  (sudo may prompt for your password)"
  sudo -v
  run_req sudo dnf -y install "${missing[@]}"
  ok
}

enable_pcscd() {
  phase "Smart card service"
  step "Enable/start pcscd.socket"
  ui ""  # newline so sudo prompt is on its own line
  sudo -v
  run_req sudo systemctl enable --now pcscd.socket
  run_req systemctl is-active pcscd.socket
  run_req systemctl is-enabled pcscd.socket
  ok
}

split_pem_into_files() {
  local pem="$1"
  run rm -f "$CERTS_DIR"/cert-*.pem || true
  run_req csplit -s -z -f "$CERTS_DIR/cert-" "$pem" '/-----BEGIN CERTIFICATE-----/' '{*}'
  shopt -s nullglob
  for f in "$CERTS_DIR"/cert-*; do [[ -f "$f" ]] && mv -f "$f" "${f}.pem"; done
  shopt -u nullglob
}

count_dod() { trust list 2>/dev/null | grep -iEc 'DoD|Department of Defense' || true; }

batch_trust_add() {
  # $@ = files
  shopt -s nullglob
  local files=( "$@" )
  shopt -u nullglob
  ((${#files[@]} > 0)) || return 0

  start_spinner
  if sudo trust anchor "${files[@]}" 2>>/dev/null; then
    :
  else
    log_w "Batch add failed; attempting chunked add."
    local chunk_size=20 chunk=() c
    for c in "${files[@]}"; do
      chunk+=( "$c" )
      if ((${#chunk[@]} == chunk_size)); then
        sudo trust anchor "${chunk[@]}" || true
        chunk=()
      fi
    done
    ((${#chunk[@]})) && sudo trust anchor "${chunk[@]}" || true
  fi
  sudo update-ca-trust extract || true
  stop_spinner_ok
}

batch_trust_remove() {
  # $@ = files
  shopt -s nullglob
  local files=( "$@" )
  shopt -u nullglob
  ((${#files[@]} > 0)) || return 0

  start_spinner
  if sudo trust anchor --remove "${files[@]}" 2>>/dev/null; then
    :
  else
    log_w "Batch remove failed; attempting chunked remove."
    local chunk_size=20 chunk=() c
    for c in "${files[@]}"; do
      chunk+=( "$c" )
      if ((${#chunk[@]} == chunk_size)); then
        sudo trust anchor --remove "${chunk[@]}" || true
        chunk=()
      fi
    done
    ((${#chunk[@]})) && sudo trust anchor --remove "${chunk[@]}" || true
  fi
  sudo update-ca-trust extract || true
  stop_spinner_ok
}

install_dod_certs() {
  phase "Certificates"

  step "Clean previous certificate artifacts"
  run rm -f "$CERTS_DIR"/cert-*.pem || true
  find "$CERTS_DIR" -maxdepth 1 -type d -name 'Certificates_PKCS7_*' -exec rm -rf {} + 2>/dev/null || true
  ok

  local zip="$CERTS_DIR/dod_${RUN_STAMP}.zip"
  local pem="$CERTS_DIR/dod_bundle_${RUN_STAMP}.pem"

  step "Download DoD PKI bundle"
  run_req curl -fsSL "$CERTS_URL" -o "$zip"
  ok

  step "Extract bundle"
  run_req unzip -q -o "$zip" -d "$CERTS_DIR"
  ok

  # Locate PKCS#7
  local p7b
  p7b="$(find "$CERTS_DIR" -maxdepth 2 -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | head -n 1 || true)"
  if [[ -z "${p7b:-}" ]]; then
    log_e "PKCS#7 (.p7b/.p7c) not found after extraction."
    fail; exit 1
  fi
  log_i "Found PKCS#7 bundle: $p7b"

  step "Convert PKCS#7 to PEM"
  if ! timeout 30s openssl pkcs7 -inform DER -print_certs -in "$p7b" -out "$pem"; then
    run_req openssl pkcs7 -print_certs -in "$p7b" -out "$pem"
  fi
  [[ -s "$pem" ]] || { log_e "PEM conversion failed (empty)."; fail; exit 1; }
  ok

  step "Split PEM into individual cert files"
  split_pem_into_files "$pem"
  ok

  # Decide: skip or reinstall if anchors exist
  local before after t0 t1
  before="$(count_dod)"
  if (( before > 0 )); then
    ui "  • Existing DoD anchors detected: $before"
    if ask_yn "Reinstall DoD anchors from the current bundle?"; then
      step "Remove existing DoD anchors (matching bundle)"
      ui ""    # sudo prompt on its own line
      sudo -v
      batch_trust_remove "$CERTS_DIR"/cert-*.pem
      ok

      step "Install certificates into system trust (p11-kit)"
      ui ""    # sudo prompt on its own line
      sudo -v
      t0=$(date +%s)
      batch_trust_add "$CERTS_DIR"/cert-*.pem
      t1=$(date +%s)
      after="$(count_dod)"
      log_i "DoD-related trust entries now: $after (before: $before); took $((t1 - t0))s."
    else
      step "Install certificates into system trust (p11-kit)"
      skip
      log_i "User chose to skip reinstall. Existing DoD entries remain: $before."
      return 0
    fi
  else
    # No anchors yet; proceed to install
    step "Install certificates into system trust (p11-kit)"
    ui ""    # sudo prompt on its own line
    sudo -v
    t0=$(date +%s)
    batch_trust_add "$CERTS_DIR"/cert-*.pem
    t1=$(date +%s)
    after="$(count_dod)"
    log_i "DoD-related trust entries now: $after (before: $before); took $((t1 - t0))s."
  fi

  step "Verify installed DoD anchors"
  trust list | grep -iE 'DoD|Department of Defense' | head -n 20 || true
  ok
}

diagnostics() {
  phase "Diagnostics"
  step "Check OpenSC PKCS#11"
  if [[ -f /usr/lib64/pkcs11/opensc-pkcs11.so ]]; then
    log_i "OpenSC PKCS#11 present at /usr/lib64/pkcs11/opensc-pkcs11.so"
    ok
  else
    log_w "OpenSC PKCS#11 library NOT found at expected path."
    skip
  fi

  step "pcsc_scan sample (3s)"
  if command -v timeout >/dev/null 2>&1 && command -v pcsc_scan >/dev/null 2>&1; then
    timeout 3s pcsc_scan | tee "$TERM_FD" || true
    ok
  else
    log_w "pcsc_scan or timeout not available; skipping."
    skip
  fi
}

final_notes() {
  phase "Complete"
  ui "Artifacts:"
  ui "  - Certificates: $CERTS_DIR"
  ui "  - Log (this run): $LOG_FILE"
  ui ""
  ui "Test steps:"
  ui "  1) Plug in your CAC reader and card."
  ui "  2) Run:  pcsc_scan    (from pcsc-tools) to confirm the card is detected."
  ui "  3) Open Firefox or Chromium (RPM builds preferred over Flatpak) and try a CAC-gated site."
  ui ""
  ui "Troubleshooting:"
  ui "  - If the reader isn’t detected, check:  systemctl status pcscd.socket"
  ui "  - Flatpak browsers may not see host PKCS#11; prefer RPM builds."
}

# ---------------- Main ----------------
phase "Starting"
fedora_guard
preflight
pkg_install
enable_pcscd
install_dod_certs
diagnostics
final_notes


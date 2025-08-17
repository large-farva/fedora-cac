#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Fedora DoD CAC rollback (v0.4.1)
#
# Terminal:
#   - Minimal phase headers + compact step lines (OK/SKIP/FAIL)
#   - Spinner while removing trust anchors
#   - Sudo password prompts appear on their own line
#
# Log:
#   - Full detail (commands, outputs, errors)
#   - ~/.cac/logs/fedora-cac-rollback_YYYY-MM-DD_HH-MM-SS.log
#
# Y/N steps:
#   1) Remove DoD trust anchors (p11-kit)  [batched + spinner]
#   2) Disable pcscd.socket
#   3) Remove CAC-related packages (SAFE set only)
#   4) Clear ~/.cac contents (wipe certs; wipe old logs; keep this log)
# -------------------------------------------------------------------

SCRIPT_VERSION="0.4.1"
CERTS_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_v5-6_dod.zip"

# Workspace
CAC_DIR="$HOME/.cac"
CERTS_DIR="$CAC_DIR/certs"
LOGS_DIR="$CAC_DIR/logs"
RUN_STAMP="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOGS_DIR/fedora-cac-rollback_${RUN_STAMP}.log"

# --- Create dirs and redirect ALL stdout/stderr to the log (quiet terminal) ---
mkdir -p "$CERTS_DIR" "$LOGS_DIR"
TERM_FD="/dev/tty"
if [[ ! -e "$TERM_FD" || ! -w "$TERM_FD" ]]; then TERM_FD="/proc/self/fd/1"; fi
exec >>"$LOG_FILE" 2>&1

# Logging (to log file)
LOG_PREFIX="[fedora-cac:rollback]"
_ts() { date +"%Y-%m-%d %H:%M:%S"; }
log_i() { echo "$(_ts) $LOG_PREFIX [INFO]  $*"; }
log_w() { echo "$(_ts) $LOG_PREFIX [WARN]  $*"; }
log_e() { echo "$(_ts) $LOG_PREFIX [ERROR] $*"; }

# Minimal terminal UI
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
  log_e "Failed (exit=$exit_code) near line $line."
  log_e "Last command: ${BASH_COMMAND:-unknown}"
  log_e "Log: $LOG_FILE"
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

# Helpers
need_cmd() { command -v "$1" >/dev/null 2>&1 || { log_e "Missing command: $1"; exit 1; }; }
ask_yn() {
  local q="$1" ans
  printf "%s " "$q [y/N]:" >"$TERM_FD"
  read -r ans <"$TERM_FD" || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

fedora_guard() {
  if ! command -v dnf >/dev/null 2>&1 || [[ ! -f /etc/fedora-release ]]; then
    log_e "This rollback targets Fedora with dnf."
    ui "This rollback targets Fedora with dnf. See log for details."
    exit 1
  fi
}

preflight() {
  phase "Preflight"
  log_i "Starting rollback (v$SCRIPT_VERSION). Log: $LOG_FILE"
  need_cmd trust; need_cmd openssl; need_cmd unzip; need_cmd csplit; need_cmd curl; need_cmd systemctl; need_cmd rpm
  local dnf_out; dnf_out="$(dnf --version 2>&1 || true)"; local dnf_ver="${dnf_out%%$'\n'*}"
  [[ -n "$dnf_ver" ]] && log_i "$dnf_ver"
  ok
}

# Build cert set (prefer local split certs, else download & split)
CERT_FILES=()
TMP_DIR=""
build_cert_set() {
  phase "Build removal set"
  shopt -s nullglob
  CERT_FILES=( "$CERTS_DIR"/cert-*.pem )
  shopt -u nullglob

  local filtered=()
  for c in "${CERT_FILES[@]:-}"; do
    [[ -f "$c" ]] && grep -q "BEGIN CERTIFICATE" "$c" && filtered+=( "$c" )
  done
  CERT_FILES=( "${filtered[@]:-}" )

  if ((${#CERT_FILES[@]} > 0)); then
    log_i "Using local certs (${#CERT_FILES[@]} file(s))."
    ok
    return
  fi

  log_i "Local certs not found; downloading bundle..."
  TMP_DIR="$(mktemp -d)"
  local zip="$TMP_DIR/dod.zip"
  curl -fsSL "$CERTS_URL" -o "$zip"
  unzip -q -o "$zip" -d "$TMP_DIR"

  local p7b
  p7b="$(find "$TMP_DIR" -maxdepth 2 -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | head -n 1 || true)"
  [[ -n "${p7b:-}" ]] || { log_e "PKCS#7 bundle not found in ZIP."; exit 1; }

  local pem="$TMP_DIR/dod_bundle.pem"
  if ! openssl pkcs7 -inform DER -print_certs -in "$p7b" -out "$pem"; then
    openssl pkcs7 -print_certs -in "$p7b" -out "$pem"
  fi
  [[ -s "$pem" ]] || { log_e "PEM conversion failed."; exit 1; }

  csplit -s -z -f "$TMP_DIR/cert-" "$pem" '/-----BEGIN CERTIFICATE-----/' '{*}'
  for f in "$TMP_DIR"/cert-*; do [[ -f "$f" ]] && mv -f "$f" "${f}.pem"; done

  shopt -s nullglob
  CERT_FILES=( "$TMP_DIR"/cert-*.pem )
  shopt -u nullglob
  log_i "Prepared ${#CERT_FILES[@]} cert file(s) for removal."
  ok
}

count_dod() { trust list 2>/dev/null | grep -iEc 'DoD|Department of Defense' || true; }

remove_anchors() {
  phase "Trust anchors"
  if ! ask_yn "Remove DoD trust anchors from system trust?"; then
    log_i "Skipping trust anchor removal."
    skip
    return
  fi
  (( ${#CERT_FILES[@]} > 0 )) || build_cert_set

  local before_count; before_count="$(count_dod)"
  log_i "Current DoD entries: ${before_count:-0}"

  ui ""  # newline so sudo prompt is on its own line
  ui "  Elevating privileges (sudo)..."
  sudo -v

  step "Removing anchors (batched)"
  local t0 t1
  t0=$(date +%s)
  start_spinner
  if sudo trust anchor --remove "${CERT_FILES[@]}" 2>>/dev/null; then
    :
  else
    log_w "Batch removal failed; attempting chunked removal."
    local chunk_size=20 chunk=() c
    for c in "${CERT_FILES[@]}"; do
      chunk+=( "$c" )
      if ((${#chunk[@]} == chunk_size)); then
        sudo trust anchor --remove "${chunk[@]}" || true
        chunk=()
      fi
    done
    ((${#chunk[@]})) && sudo trust anchor --remove "${chunk[@]}" || true
  fi
  sudo update-ca-trust extract || true
  t1=$(date +%s)
  stop_spinner_ok
  log_i "Anchor removal phase took $((t1 - t0))s."

  local after_count; after_count="$(count_dod)"
  log_i "DoD entries now: ${after_count:-0} (before: ${before_count:-0})"
}

disable_pcscd() {
  phase "pcscd.socket"
  if ! ask_yn "Disable and stop pcscd.socket?"; then
    log_i "Leaving pcscd.socket enabled."
    skip
    return
  fi
  ui ""  # newline so sudo prompt is on its own line
  ui "  Elevating privileges (sudo)..."
  sudo -v
  sudo systemctl disable --now pcscd.socket || true
  log_i "pcscd.socket disabled/stopped (if applicable)."
  ok
}

remove_packages() {
  phase "Packages (safe)"
  if ! ask_yn "Remove CAC-related packages (safe set)?"; then
    log_i "Package removal skipped."
    skip
    return
  fi

  local SAFE_REMOVE_PKGS=(pcsc-lite pcsc-lite-ccid opensc nss-tools pcsc-tools)
  local installed=()
  for p in "${SAFE_REMOVE_PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 && installed+=( "$p" ); done
  if ((${#installed[@]} == 0)); then
    log_i "No matching packages are installed."
    ok
    return
  fi

  ui ""  # newline so sudo prompt is on its own line
  ui "  Elevating privileges (sudo)..."
  sudo -v
  sudo dnf -y remove "${installed[@]}"
  log_i "Removed: ${installed[*]}"
  ok
}

clear_cac_contents() {
  phase "~/.cac cleanup"
  if ! ask_yn "Clear ~/.cac contents (wipe certs; wipe old logs; keep this log)?"; then
    log_i "Leaving $CAC_DIR as-is."
    skip
    return
  fi

  mkdir -p "$CERTS_DIR" "$LOGS_DIR"
  shopt -s nullglob dotglob
  for f in "$CERTS_DIR"/*; do rm -rf -- "$f"; done
  for f in "$LOGS_DIR"/*; do [[ "$f" == "$LOG_FILE" ]] && continue; rm -rf -- "$f"; done
  shopt -u nullglob dotglob

  log_i "Cleared certs and old logs. Preserved current log: $LOG_FILE"
  ok
}

cleanup_tmp() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

# Main
fedora_guard
preflight
build_cert_set
remove_anchors
disable_pcscd
remove_packages
clear_cac_contents
cleanup_tmp

phase "Complete"
ui "Rollback finished."
ui "Log: $LOG_FILE"


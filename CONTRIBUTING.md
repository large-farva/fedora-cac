# Contributing to `fedora-cac`

Thanks for your interest in improving this project! Contributions of all kinds are welcome — bug reports, docs, and code.

The goal is simple: **make CAC on Fedora “just work”** with clear logging and minimal surprises.

---

## Ways to Contribute

- **Bug reports** — Problems running the script, unexpected errors, or confusing behavior.
- **Feature requests** — Small, high‑impact improvements that keep the script simple and auditable.
- **Documentation** — Clarify the README, add troubleshooting steps, or correct inaccuracies.
- **Code changes** — Refactors or fixes that improve reliability, idempotence, or logging.

---

## Ground Rules

- Keep it **Fedora (dnf)** focused in this repo. rpm‑ostree (Silverblue/uBlue) support may live in a sibling script.
- Prefer **no new runtime dependencies** beyond Fedora base/standard repos.
- **Security:** Do not post private keys or sensitive URLs. Redact PII in logs.
- Be respectful and concise. Clear logs > clever tricks.

---

## Before You File an Issue

1. **Update** to the latest `main` version of the script.

2. **Reproduce** with `LOG_LEVEL=DEBUG` for detailed logs:
   
   ```bash
   LOG_LEVEL=DEBUG ./fedora-cac-setup.sh
   ```

3. Collect environment details:
   
   - Fedora release: `cat /etc/fedora-release`
   - Kernel: `uname -a`
   - DNF version: `dnf --version | head -n1`
   - Browser and packaging: **Firefox/Chromium (RPM or Flatpak)** + version
   - CAC reader model
   - Short `pcsc_scan` excerpt (if available)
   - `systemctl status pcscd.socket`
   - `journalctl -u pcscd --since "1 hour ago" | tail -n 200`
   - `trust list | grep -iE 'DoD|Department of Defense' | head -n 20`
   - OpenSC lib exists: `/usr/lib64/pkcs11/opensc-pkcs11.so`

Attach your **per‑run log** from `~/.cac/logs/` (redact anything sensitive).

---

## Filing a Good Bug Report

Please include:

- **Summary** of the problem and the exact error text (if any)
- **Environment** (Fedora version, browser variant, reader model)
- **Steps to Reproduce**
- **Expected** vs **Actual** results
- **Logs**: the single run log from `~/.cac/logs/…`
- Any **workarounds** you tried

---

## Proposing a Change (PRs)

1. **Fork** the repo and create a feature branch:
   
   ```bash
   git checkout -b feat/short-description
   ```

2. Keep the script:
   
   - Bash with `set -euo pipefail`
   - Idempotent where practical
   - **Clear, leveled logging** (`INFO/WARN/ERROR/DEBUG`)
   - Fedora‑only assumptions; do not add rpm‑ostree handling here

3. **Style & Quality**
   
   - Run `shellcheck` locally and fix warnings where reasonable.
   - Avoid subshell-heavy constructs that obscure failures.
   - Keep functions small and explicit; log what you change.

4. **Testing**
   
   - Test on a fresh Fedora VM if possible.
   - Verify **re‑runs** don’t break (idempotence).
   - Validate logs are readable at both INFO and DEBUG levels.

5. **Docs**
   
   - Update `README.md` when behavior or flags change.

6. **Commits**
   
   - Use clear commit subjects (≤ 72 chars) and explanatory bodies when needed.

---

## Security & Responsible Disclosure

If you believe a change has **security implications** (e.g., trust store handling), open an issue and flag it clearly. If you’re unsure, contact the repo owner privately first and avoid posting sensitive details publicly.

Thanks again for helping improve `fedora-cac`!
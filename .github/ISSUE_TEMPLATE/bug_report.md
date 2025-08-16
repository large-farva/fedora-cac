# BUG REPORT
cat > .github/ISSUE_TEMPLATE/bug_report.md << 'EOF'
---
name: Bug report
about: Create a report to help us improve
title: "[Bug] Short description"
labels: bug
assignees: ""
---

## Summary

A clear and concise description of the problem.

## Environment

- Fedora: `cat /etc/fedora-release`
- Kernel: `uname -a`
- DNF: `dnf --version | head -n 1`
- Browser & packaging: (Firefox/Chromium, RPM or Flatpak) + version
- CAC reader model:

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

What you expected to happen.

## Actual Behavior

What actually happened, including any error messages.

## Logs

Attach the **single per-run log** from `~/.cac/logs/…` (redact anything sensitive).

## Diagnostics (copy/paste outputs if available)

```bash
systemctl status pcscd.socket
journalctl -u pcscd --since "1 hour ago" | tail -n 200
trust list | grep -iE 'DoD|Department of Defense' | head -n 20
pcsc_scan  # (Ctrl+C after reader/card appears)
ls -l /usr/lib64/pkcs11/opensc-pkcs11.so


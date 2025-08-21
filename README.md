# fedora-cac

Set up a Fedora system to use a U.S. DoD Common Access Card (CAC) with Firefox and Chromium.

This project provides a one-shot script that:

- Installs the smart-card stack (pcsc-lite, OpenSC, p11-kit, etc.).
- Enables `pcscd.socket`.
- Downloads the official DoD PKI bundle, converts it, and installs the trust anchors system-wide.
- Saves artifacts and detailed logs under `~/.cac/` for easy auditing and troubleshooting.

> **Scope:** Fedora **Workstation/Server (dnf-based)** only.
> **Not** for Silverblue/uBlue/other rpm-ostree variants.

---

## Table of Contents

- [Quick Start](#quick-start)
- [What the Script Does](#what-the-script-does)
- [Requirements](#requirements)
- [Directory Layout](#directory-layout)
- [Usage](#usage)
- [Logging & Diagnostics](#logging--diagnostics)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Uninstall / Rollback](#uninstall--rollback)
- [Contributing](#contributing)
- [Security & Privacy Notes](#security--privacy-notes)
- [License](#license)

---

## Quick Start

# 1) Clone and enter the repo
git clone https://github.com/<your-username>/fedora-cac.git
cd fedora-cac

# 2) Make the script executable
chmod +x fedora-cac-setup.sh

# 3) Run it (INFO logs by default)
./fedora-cac-setup.sh

#    (Optional) Run with more verbose logs:
LOG_LEVEL=DEBUG ./fedora-cac-setup.sh

After it completes, artifacts live in `~/.cac/` and a full per-run log is at `~/.cac/logs/…`.

---

## What the Script Does

1. **Installs packages** needed for CAC:

   - `pcsc-lite`, `pcsc-lite-ccid` (smart-card services & CCID driver)
   - `opensc` (PKCS#11 middleware)
   - `p11-kit`, `p11-kit-trust`, `p11-kit-tools` (system trust / PKCS#11 integration)
   - `nss-tools` (NSS utilities, handy for edge cases)
   - `ca-certificates`, `curl`, `openssl`, `unzip`
   - `pcsc-tools` (for `pcsc_scan` verification)

2. **Enables the service runtime**:

   - `systemctl enable --now pcscd.socket`

3. **Installs DoD certificates**:

   - Downloads the DoD PKI bundle (from Cyber.mil).
   - Converts PKCS#7 → PEM, splits into individual certs.
   - Installs each certificate as a **system trust anchor** with `p11-kit`.

4. **Saves everything** under `~/.cac/`:

   - `certs/` – the downloaded zip, converted PEM, and split certificates
   - `logs/` – a single timestamped log per run

5. **Diagnostics**:

   - Captures service status, a short `pcsc_scan` sample, and trust store summary.

> By default, the script does **not** modify per-profile NSS databases. You generally don’t need this on modern Fedora. If you do, there’s an optional function in the script you can uncomment.

---

## Requirements

- Fedora with `sudo` privileges
- Internet access to fetch the DoD PKI bundle
- A CCID-compatible CAC reader

---

## Directory Layout

```bash
~/.cac/
├── certs/
│   ├── dod_YYYY-MM-DD_HH-MM-SS.zip
│   ├── dod_bundle_YYYY-MM-DD_HH-MM-SS.pem
│   └── cert-0000.pem
│       cert-0001.pem
│       ...
└── logs/
    └── fedora-cac-setup_YYYY-MM-DD_HH-MM-SS.log
```
---

## Usage

# Clone, chmod, run
git clone https://github.com/<your-username>/fedora-cac.git
cd fedora-cac
chmod +x fedora-cac-setup.sh
./fedora-cac-setup.sh

# Optional: more verbose logs
LOG_LEVEL=DEBUG ./fedora-cac-setup.sh

**After running:** Re-plug your reader if needed and test with your target site.

---

## Logging & Diagnostics

- **Single per-run log:** `~/.cac/logs/fedora-cac-setup_… .log`
- **Log levels:** `INFO` by default; set `LOG_LEVEL=DEBUG` for command-by-command output.
- **Built-in checks:**
  - Fedora release, kernel, and `dnf` availability
  - Network reachability to the PKI bundle
  - `pcscd.socket` status & journal tail
  - OpenSC library presence (`/usr/lib64/pkcs11/opensc-pkcs11.so`)
  - Short `pcsc_scan` capture (if available)

---

## Verification

1. **Reader & card detection**

   ```bash
   pcsc_scan   # Ctrl+C to stop after it shows your reader/card

2. **Service status**

   ```bash
   systemctl status pcscd.socket

3. **Trust store (sample)**

   ```bash
   trust list | grep -iE 'DoD|Department of Defense'

4. **Firefox (only if manual step is needed)**

   - Preferences → Privacy & Security → **Security Devices**
   - If necessary, **Load**: `/usr/lib64/pkcs11/opensc-pkcs11.so`

> For **Chromium/Chrome**, prefer the RPM package on Fedora. Flatpak browsers may not see host PKCS#11 modules without extra configuration.

---

## Troubleshooting

- **The site doesn’t prompt for a certificate**

  - Confirm `pcsc_scan` shows the reader/card.
  - Ensure `pcscd.socket` is **active** and **enabled**.
  - Make sure you’re using **RPM** Firefox/Chromium.
  - Check `~/.cac/logs/…` for errors around certificate install or service enablement.

- **Reader not detected**

  - Re-seat the reader and card; try another USB port.
  - Verify `pcsc-lite-ccid` is installed.
  - `journalctl -u pcscd --since "1 hour ago"` to see if the daemon reports issues.

- **DoD trust anchors didn’t appear**

  - Re-run the script with `LOG_LEVEL=DEBUG` and search the log for `trust anchor`.
  - Try listing trust again:

    ```bash
    trust list | grep -iE 'DoD|Department of Defense'

- **Firefox still doesn’t see the card**

  - Add OpenSC manually: `/usr/lib64/pkcs11/opensc-pkcs11.so` (see Verification §4).

---

## FAQ

**Q: Can I run the script multiple times?**
A: Yes. It’s idempotent where practical (package installs and trust anchors won’t break on re-run).

**Q: Does this support Silverblue/uBlue?**
A: Not in this script. A separate rpm-ostree version is planned.

**Q: Where are the logs and certs saved?**
A: `~/.cac/logs/…` and `~/.cac/certs/…`.

**Q: Does this modify my browser profile?**
A: No, not by default. Modern Fedora integrates PKCS#11 via p11-kit. A helper function exists in the script if you need legacy per-profile registration.

---

## Uninstall / Rollback

To remove the DoD trust anchors added by this script:

```bash
# Remove the anchors using the exact cert files we installed
sudo trust anchor --remove ~/.cac/certs/cert-*.pem || true
```
```bash
# (Optional) Update the consolidated trust store
sudo update-ca-trust || true
```

> Notes:
>
> - Removal uses the same certificate contents, so it doesn’t depend on internal filenames.
> - If you manually added OpenSC to a browser profile, remove it from the browser’s security devices UI.

To disable smart-card services:

```bash
sudo systemctl disable --now pcscd.socket
```

Packages can be removed with:

```bash
sudo dnf remove pcsc-lite pcsc-lite-ccid opensc p11-kit p11-kit-trust p11-kit-tools nss-tools pcsc-tools
```

---

## Contributing

PRs and issues are welcome. Please include:

- Fedora version (`cat /etc/fedora-release`)
- Browser variant (RPM/Flatpak) and version
- Reader model and a short `pcsc_scan` excerpt
- The run log from `~/.cac/logs/…` (redact anything sensitive)

Style: keep the script POSIX-friendly where reasonable, fail fast with clear logs, and avoid distro-specific hacks beyond Fedora.

---

## Security & Privacy Notes

- The script downloads the **official DoD PKI bundle** and installs certificates as system trust anchors.
- Review the source and log output if your environment requires strict audit trails.
- No private keys are created or handled; only public CA certificates are installed.

---

## License

MIT. See [`LICENSE`](./LICENSE).

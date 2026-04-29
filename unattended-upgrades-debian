#!/usr/bin/env bash
#
# setup-unattended-upgrades.sh
#
# Purges, reinstalls, and configures unattended-upgrades for security-only
# updates with no automatic reboots. Designed for Debian containers.
#
# Idempotent: safe to re-run. Always overwrites custom config.
#
# Usage:  sudo ./setup-unattended-upgrades.sh
#

set -euo pipefail

# ---- helpers ---------------------------------------------------------------
log()  { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2; }

# ---- preflight -------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "Must run as root (use sudo)."
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    err "This script requires apt (Debian/Ubuntu)."
    exit 1
fi

log "Starting unattended-upgrades setup"

# ---- step 1: purge ---------------------------------------------------------
log "Step 1/4: Purging unattended-upgrades (if installed)"

if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    apt purge -y unattended-upgrades
    ok "Package purged"
else
    ok "Package not installed, skipping purge"
fi

# Clean up orphaned dependencies and leftover logs
apt autoremove -y >/dev/null
rm -rf /var/log/unattended-upgrades

# ---- step 2: verify nukage -------------------------------------------------
log "Step 2/4: Verifying clean slate"

# dpkg -l returns 1 when the package is unknown, which is what we want.
# The 'ii' check ensures we don't false-positive on 'rc' (residual config).
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    err "Package still installed after purge — aborting"
    exit 1
fi

for f in /etc/apt/apt.conf.d/50unattended-upgrades \
         /etc/apt/apt.conf.d/20auto-upgrades; do
    if [[ -e "$f" ]]; then
        err "Config file still present after purge: $f"
        exit 1
    fi
done

ok "System is clean"

# ---- step 3: install -------------------------------------------------------
log "Step 3/4: Installing unattended-upgrades"

apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades

# Sanity check
if ! systemctl is-enabled --quiet unattended-upgrades; then
    err "Service is not enabled after install"
    exit 1
fi

ok "Package installed and service enabled"

# ---- step 4: configure -----------------------------------------------------
log "Step 4/4: Writing custom config (security-only, no auto-reboot)"

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
// Managed by setup-unattended-upgrades.sh
// Security updates only, no auto-reboot
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

chmod 644 /etc/apt/apt.conf.d/50unattended-upgrades
ok "Config written"

# ---- final verification ----------------------------------------------------
log "Running dry-run to verify config parses correctly"

# Capture the dry-run output first, then grep — avoids SIGPIPE killing
# the upstream command under `set -o pipefail`.
dry_run_output="$(unattended-upgrade --dry-run --debug 2>&1)"
if grep -q 'Allowed origins.*Debian-Security' <<<"$dry_run_output"; then
    ok "Dry-run confirms Debian-Security origin is active"
else
    err "Dry-run did not show expected Debian-Security origin"
    err "Full output:"
    echo "$dry_run_output" >&2
    exit 1
fi

echo
log "Restarting service to apply new config"
systemctl restart unattended-upgrades

# Confirm it actually came back up
if systemctl is-active --quiet unattended-upgrades; then
    ok "Service restarted successfully"
else
    err "Service failed to restart after config change"
    systemctl --no-pager status unattended-upgrades >&2 || true
    exit 1
fi

echo
ok "All done. Service status:"
systemctl --no-pager --lines=0 status unattended-upgrades || true

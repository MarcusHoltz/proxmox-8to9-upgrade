#!/bin/bash
set -euo pipefail

# --- CONFIGURATION ---
TARGET_CODENAME="trixie"
CURRENT_CODENAME="bookworm"
BACKUP_DIR="/root/apt_backup_$(date +%F_%H-%M)"
# ---------------------

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() { echo -e "${BLUE}=== $1 ===${NC}"; }

clear
cat <<"EOF"
    ____                                          ____          ___  
   / __ \_________ __  ______ ___  ____  _  __   ( __ )   _   / _ \ 
  / /_/ / ___/ __ `/ |/_/ __ `__ \/ __ \| |/_/  / __  | (_) / (_) |
 / ____/ /  / /_/ />  </ / / / / / /_/ />  <   / /_/ /  _    \__, / 
/_/   /_/   \__,_/_/|_/_/ /_/ /_/\____/_/|_|  /_____/  (_)      /_/  
                                                                      
         ALL-IN-ONE UPGRADE & POST-INSTALL AUTOMATION
EOF
echo ""

# 1. Root Check
if [[ $EUID -ne 0 ]]; then err "Must run as root."; fi

# 2. Detect Proxmox Version
log "Detecting Proxmox VE version..."
if ! command -v pveversion &>/dev/null; then
    err "pveversion not found. Is this a Proxmox VE system?"
fi

PVE_VERSION=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d. -f1)
PVE_MINOR=$(echo "$PVE_VERSION" | cut -d. -f2)

echo -e "Detected: Proxmox VE ${GREEN}$PVE_VERSION${NC} (Major: $PVE_MAJOR, Minor: $PVE_MINOR)"

# Detect products
HAS_PBS=$(dpkg -l 2>/dev/null | grep -q "proxmox-backup-server" && echo "yes" || echo "no")
HAS_PDM=$(dpkg -l 2>/dev/null | grep -q "proxmox-datacenter-manager" && echo "yes" || echo "no")

echo -e " - PBS (Backup Server): $HAS_PBS"
echo -e " - PDM (Manager): $HAS_PDM"
echo ""

# 3. Version-specific workflow
if [[ "$PVE_MAJOR" == "8" ]]; then
    header "Proxmox VE 8 → 9 Upgrade Mode"
    
    # Run pre-flight checks
    log "Running pve8to9 pre-flight checks..."
    if ! command -v pve8to9 &>/dev/null; then
        err "pve8to9 tool missing. Run: apt update && apt dist-upgrade first"
    fi
    
    if ! pve8to9 --full; then
        err "Pre-flight checks failed. Fix errors above before continuing."
    fi
    
    # Check PBS tasks
    if [[ "$HAS_PBS" == "yes" ]] && command -v proxmox-backup-manager &>/dev/null; then
        ACTIVE_JOBS=$(proxmox-backup-manager task list --all 2>/dev/null | grep -i "running" | wc -l || echo "0")
        if [[ $ACTIVE_JOBS -gt 0 ]]; then
            warn "PBS has $ACTIVE_JOBS running tasks. This may cause issues during upgrade."
            warn "Consider stopping tasks first, but continuing anyway..."
        fi
    fi
    
    # Check cluster
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
        warn "This node is CLUSTERED. Upgrade ONE node at a time!"
        sleep 3
    fi
    
    # Backup sources (only if not already backed up today)
    BACKUP_TODAY="/root/apt_backup_$(date +%F)*"
    if compgen -G "$BACKUP_TODAY" > /dev/null; then
        log "Backup already exists for today, skipping..."
    else
        log "Backing up APT configuration to $BACKUP_DIR..."
        mkdir -p "$BACKUP_DIR"
        cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
        cp -r /etc/apt/sources.list.d/ "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Update repositories bookworm → trixie
    log "Updating repositories: $CURRENT_CODENAME → $TARGET_CODENAME..."
    
    shopt -s nullglob
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        if [[ -f "$file" ]] && grep -q "$CURRENT_CODENAME" "$file"; then
            log "  Updating: $file"
            sed -i "s/$CURRENT_CODENAME/$TARGET_CODENAME/g" "$file"
        fi
    done
    shopt -u nullglob
    
    log "Repository update complete. Ready for dist-upgrade."
    
elif [[ "$PVE_MAJOR" == "9" ]]; then
    header "Proxmox VE 9 Post-Install Mode"
    log "Already on PVE 9, running post-install configuration..."
    
else
    err "Unsupported Proxmox VE version: $PVE_MAJOR (Only 8.x and 9.x supported)"
fi

# === UNIVERSAL POST-INSTALL ROUTINES ===
header "Post-Install Configuration"

# Configure repositories based on version
if [[ "$PVE_MAJOR" == "8" ]]; then
    log "Configuring Debian 12 (Bookworm) sources..."
    cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
    
    log "Disabling pve-enterprise repository..."
    cat >/etc/apt/sources.list.d/pve-enterprise.list <<EOF
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
    
    log "Enabling pve-no-subscription repository..."
    cat >/etc/apt/sources.list.d/pve-install-repo.list <<EOF
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
    
    log "Configuring Ceph repositories (disabled)..."
    cat >/etc/apt/sources.list.d/ceph.list <<EOF
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
    
    log "Adding pvetest repository (disabled)..."
    cat >/etc/apt/sources.list.d/pvetest-for-beta.list <<EOF
# deb http://download.proxmox.com/debian/pve bookworm pvetest
EOF

elif [[ "$PVE_MAJOR" == "9" ]]; then
    # Remove enterprise repos first (they cause 401 errors without subscription)
    log "Removing enterprise repositories..."
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    rm -f /etc/apt/sources.list.d/ceph-enterprise.sources
    
    # Disable legacy sources if they exist (idempotent check)
    if [[ -f /etc/apt/sources.list ]] && grep -qE '^\s*deb ' /etc/apt/sources.list; then
        log "Disabling legacy /etc/apt/sources.list..."
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
        sed -i '/^\s*deb /s/^/# Disabled by upgrade script /' /etc/apt/sources.list
    fi
    
    # Rename .list files to .bak (only if not already renamed)
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list; do
        if [[ -f "$f" && ! -f "$f.bak" ]]; then
            mv "$f" "$f.bak" && log "Renamed $f to .bak"
        fi
    done
    shopt -u nullglob
    
    log "Configuring Debian 13 (Trixie) sources (deb822 format)..."
    cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    
    log "Configuring pve-no-subscription repository (deb822)..."
    cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    
    log "Configuring Ceph repository (deb822)..."
    cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    
    log "Adding pvetest repository (deb822, disabled)..."
    cat >/etc/apt/sources.list.d/pve-test.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
fi

# Disable subscription nag (idempotent)
header "Disabling Subscription Nag"

if [[ ! -f /usr/local/bin/pve-remove-nag.sh ]]; then
    log "Creating nag removal script..."
    mkdir -p /usr/local/bin
    cat >/usr/local/bin/pve-remove-nag.sh <<'NAGEOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) { dialog.remove(); }" \
      "    });" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) { card.remove(); }" \
      "    });" \
      "  }" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" >> "$MOBILE_TPL"
fi
NAGEOF

    chmod 755 /usr/local/bin/pve-remove-nag.sh
    log "Nag removal script created"
else
    log "Nag removal script already exists, skipping..."
fi

if [[ ! -f /etc/apt/apt.conf.d/no-nag-script ]]; then
    log "Configuring APT hook for nag removal..."
    cat >/etc/apt/apt.conf.d/no-nag-script <<'NAGEOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
NAGEOF
    chmod 644 /etc/apt/apt.conf.d/no-nag-script
    log "APT hook configured"
else
    log "APT hook already configured, skipping..."
fi

# Disable HA services (unless clustered)
if systemctl is-active --quiet pve-ha-lrm; then
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
        log "Node is clustered - keeping HA services enabled"
    else
        log "Disabling HA services (single node)..."
        systemctl disable --now pve-ha-lrm &>/dev/null || true
        systemctl disable --now pve-ha-crm &>/dev/null || true
        systemctl disable --now corosync &>/dev/null || true
    fi
fi

# Reinstall widget toolkit to apply nag removal
log "Reinstalling proxmox-widget-toolkit to apply nag removal..."
apt-get --reinstall install proxmox-widget-toolkit -y &>/dev/null || warn "Widget toolkit reinstall failed"

# Final summary
header "Configuration Complete!"
echo ""
echo -e "${GREEN}✓${NC} Repositories configured"
echo -e "${GREEN}✓${NC} Subscription nag removed"
echo -e "${GREEN}✓${NC} HA services optimized"
echo ""
echo -e "${YELLOW}CRITICAL NEXT STEPS (DO THESE MANUALLY):${NC}"
if [[ "$PVE_MAJOR" == "8" ]]; then
    echo -e "1. Review changes above carefully"
    echo -e "2. Run: ${RED}apt update${NC}"
    echo -e "3. Run: ${RED}apt dist-upgrade${NC}"
    echo -e "   ${YELLOW}→ Review package changes BEFORE confirming!${NC}"
    echo -e "   ${YELLOW}→ Choose 'Keep Current Version' for Proxmox configs${NC}"
    echo -e "4. ${RED}REBOOT after successful upgrade${NC}"
else
    echo -e "1. Run: ${RED}apt update${NC}"
    echo -e "2. Run: ${RED}apt upgrade${NC} (or dist-upgrade if needed)"
    echo -e "3. ${RED}REBOOT${NC}"
fi
echo -e "5. Clear browser cache (Ctrl+Shift+R) before using Web UI"
if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
    echo -e "6. ${RED}If clustered: Run this script on OTHER nodes ONE AT A TIME${NC}"
fi
echo ""
echo -e "Backup location: ${BLUE}$BACKUP_DIR${NC}"
echo ""

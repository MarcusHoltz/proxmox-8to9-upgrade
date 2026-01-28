#!/bin/bash
# =============================================================================
# Proxmox VE 8 to 9 Unattended Upgrade Script
# =============================================================================
# This script automates the upgrade from Proxmox VE 8.x to 9.x, with support for
# both unattended and manual modes. It handles repository changes, removes
# enterprise repos, backs up APT sources, and applies post-install optimizations.
#
# FEATURES:
# - Fully unattended or manual upgrade modes
# - Removes all enterprise repositories (prevents 401 errors)
# - Backs up APT sources before changes
# - Configures Debian 13 (Trixie) repositories in deb822 format
# - Disables subscription nags in the web UI
# - Manages HA services appropriately for clustered/single nodes
# - Non-interactive APT operations (safe for SSH/automation)
#
# USAGE:
# 1. Save this script as proxmox-8to9-upgrade.sh
# 2. Make it executable: chmod +x proxmox-8to9-upgrade.sh
# 3. Run as root: sudo ./proxmox-8to9-upgrade.sh
#
# EXAMPLES:
# - Manual mode (default, review changes before upgrade):
#   sudo ./proxmox-8to9-upgrade.sh
#
# DO THIS:
# - Unattended mode (auto-upgrade, no prompts):
#   sudo AUTO_UPGRADE=true ./proxmox-8to9-upgrade.sh
#
# CONFIGURATION:
# Edit the CONFIGURATION section below to change:
# - TARGET_CODENAME: Target Debian release (default: trixie)
# - CURRENT_CODENAME: Current Debian release (default: bookworm)
# - BACKUP_DIR: Where to store APT source backups
# - AUTO_UPGRADE: Set to 'true' for unattended dist-upgrade
#
# NOTES:
# - Always review changes before upgrading in manual mode.
# - If clustered, upgrade ONE node at a time.
# - Reboot is required after upgrade.
# - Clear browser cache after reboot (Ctrl+Shift+R).
# =============================================================================

set -euo pipefail

# =============================================
# CONFIGURATION
# =============================================
TARGET_CODENAME="trixie"
CURRENT_CODENAME="bookworm"
BACKUP_DIR="/root/apt_backup_$(date +%F_%H-%M)"
AUTO_UPGRADE="${AUTO_UPGRADE:-false}"  # Set to 'true' for unattended dist-upgrade
# EXAMPLE to run unattended:
# AUTO_UPGRADE=true ./proxmox-8to9-upgrade.sh
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

# =============================================
# GLOBAL APT CONFIGURATION
# =============================================
# Makes all apt operations fully unattended (no prompts, no hangs)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Centralized APT options for all package operations
declare -a APT_OPTS=(
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
    -o APT::Get::Assume-Yes=true
    -o APT::Get::allow-downgrades=false
    -o APT::Get::allow-remove-essential=false
    -o APT::Get::allow-change-held-packages=false
)

# =============================================
# FUNCTIONS
# =============================================

# --- Configures needrestart for automatic service restarts (no prompts)
# RUN: At script start, before any apt operations
configure_needrestart() {
    if ! command -v needrestart &>/dev/null; then
        log "Installing needrestart for automatic service restart handling..."
        apt-get install -y needrestart 2>/dev/null || true
    fi
    if [[ -d /etc/needrestart ]]; then
        log "Configuring needrestart for automatic service restarts..."
        mkdir -p /etc/needrestart/conf.d
        cat > /etc/needrestart/conf.d/99-auto.conf <<'EOF'
$nrconf{restart} = 'a';
EOF
    fi
}

# --- Detects Proxmox VE version and returns version, major, and minor numbers
# RUN: After root check, before version-specific logic
detect_pve_version() {
    if ! command -v pveversion &>/dev/null; then
        err "pveversion not found. Is this a Proxmox VE system?"
    fi
    local version_str
    version_str=$(pveversion | awk -F'/' '{print $2}')
    PVE_VERSION=$(echo "$version_str" | awk -F'-' '{print $1}')
    PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d. -f1)
    PVE_MINOR=$(echo "$PVE_VERSION" | cut -d. -f2)
    echo "$PVE_VERSION" "$PVE_MAJOR" "$PVE_MINOR"
}

# --- Backs up current APT sources to a dated directory
# RUN: After pre-flight checks, before repo changes
backup_sources() {
    local backup_glob="/root/apt_backup_$(date +%F)*"
    if compgen -G "$backup_glob" > /dev/null; then
        log "Backup for today already exists, skipping..."
    else
        log "Backing up APT sources to $BACKUP_DIR..."
        mkdir -p "$BACKUP_DIR"
        cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
        cp -r /etc/apt/sources.list.d/ "$BACKUP_DIR/" 2>/dev/null || true
    fi
}

# --- Removes ALL enterprise repositories and ensures pve-no-subscription is present
# RUN: BEFORE ANY APT OPERATIONS, especially before installing pve8to9
ensure_no_enterprise_repos() {
    log "Checking for and removing enterprise repositories..."
    # Remove ALL enterprise repos (both .list and .sources)
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources
    rm -f /etc/apt/sources.list.d/ceph-enterprise.list
    rm -f /etc/apt/sources.list.d/ceph-enterprise.sources
    rm -f /etc/apt/sources.list.d/ceph.list  # <-- NEW: Added missing ceph.list
    # Ensure pve-no-subscription repo is present (as .list for PVE 8)
    if [[ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]]; then
        log "Adding pve-no-subscription repository..."
        cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve $CURRENT_CODENAME pve-no-subscription
EOF
    fi
    # Update apt to apply changes
    apt-get update
}

# --- Removes enterprise repositories (called during repo config for PVE 9)
# RUN: During configure_repos_for_trixie
remove_enterprise_repos() {
    log "Removing enterprise repositories..."
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources
    rm -f /etc/apt/sources.list.d/ceph-enterprise.list
    rm -f /etc/apt/sources.list.d/ceph-enterprise.sources
    rm -f /etc/apt/sources.list.d/ceph.list  # <-- NEW: Added missing ceph.list
}

# --- Configures repositories for Debian 13 (Trixie) in deb822 format
# RUN: After backup, before upgrade
configure_repos_for_trixie() {
    log "Configuring Debian 13 (Trixie) sources (deb822 format)..."
    # Disable legacy sources if they exist
    if [[ -f /etc/apt/sources.list ]] && grep -qE '^\s*deb ' /etc/apt/sources.list; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
        sed -i '/^\s*deb /s/^/# Disabled by upgrade script /' /etc/apt/sources.list
    fi
    # Rename .list files to .bak
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/*.list; do
        if [[ -f "$f" && ! -f "$f.bak" ]]; then
            mv "$f" "$f.bak" && log "Renamed $f to .bak"
        fi
    done
    shopt -u nullglob
    # Write new sources
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

    cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
}

# --- Sets up nag removal script and APT hook
# RUN: During post-install configuration
setup_nag_removal() {
    if [[ ! -f /usr/local/bin/pve-remove-nag.sh ]]; then
        log "Creating nag removal script..."
        mkdir -p /usr/local/bin
        cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi
MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    printf "%s\n" "$MARKER" "<script>function removeSubscriptionElements(){const dialogs=document.querySelectorAll('dialog.pwt-outer-dialog');dialogs.forEach(dialog=>{const text=(dialog.textContent||'').toLowerCase();if(text.includes('subscription')){dialog.remove();}});const cards=document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');cards.forEach(card=>{const text=(card.textContent||'').toLowerCase();const hasButton=card.querySelector('button');if(!hasButton&&text.includes('subscription')){card.remove();}});}const observer=new MutationObserver(removeSubscriptionElements);observer.observe(document.body,{childList:true,subtree:true});removeSubscriptionElements();setInterval(removeSubscriptionElements,300);setTimeout(()=>{observer.disconnect();},10000);} </script>" >> "$MOBILE_TPL"
fi
EOF
        chmod +x /usr/local/bin/pve-remove-nag.sh
    fi
    if [[ ! -f /etc/apt/apt.conf.d/no-nag-script ]]; then
        log "Creating APT hook for nag removal..."
        cat > /etc/apt/apt.conf.d/no-nag-script <<EOF
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
        chmod 644 /etc/apt/apt.conf.d/no-nag-script
    fi
}

# --- Manages HA services (disables on single node, keeps on cluster)
# RUN: During post-install configuration
manage_ha_services() {
    if systemctl is-active --quiet pve-ha-lrm; then
        if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
            log "Node is clustered; keeping HA services active."
        else
            log "Disabling HA services for single node..."
            systemctl disable --now pve-ha-lrm pve-ha-crm corosync || true
        fi
    fi
}

# =============================================
# MAIN LOGIC
# =============================================

clear
cat <<"EOF"
    ____                                          ____        ___
   / __ \_________ __  ______ ___  ____  _  __   ( __ )  _   / _ \
  / /_/ / ___/ __ `/ |/_/ __ `__ \/ __ \| |/_/  / __  | (_) / (_) |
 / ____/ /  / /_/ />  </ / / / / / /_/ />  <   / /_/ /  _   \__, /
/_/   /_/   \__,_/_/|_/_/ /_/ /_/\____/_/|_|  /_____/  (_)    /_/

         ALL-IN-ONE UPGRADE & POST-INSTALL AUTOMATION
        (UNATTENDED OPTIONAL WITH: AUTO_UPGRADE=true)
EOF
echo ""

# --- 1. Root Check ---
if [[ $EUID -ne 0 ]]; then err "Must run as root."; fi

# --- 2. Configure non-interactive mode early ---
configure_needrestart

# --- 3. Basic network check ---
if ! ping -c 1 -W 2 deb.debian.org &>/dev/null; then
    warn "No internet connectivity detected. Apt operations may fail."
fi

# --- 4. Detect Proxmox Version ---
log "Detecting Proxmox VE version..."
read PVE_VERSION PVE_MAJOR PVE_MINOR < <(detect_pve_version)
echo -e "Detected: Proxmox VE ${GREEN}$PVE_VERSION${NC} (Major: $PVE_MAJOR, Minor: $PVE_MINOR)"

# --- Detect products ---
HAS_PBS=$(dpkg -l 2>/dev/null | grep -q "proxmox-backup-server" && echo "yes" || echo "no")
HAS_PDM=$(dpkg -l 2>/dev/null | grep -q "proxmox-datacenter-manager" && echo "yes" || echo "no")
echo -e " - PBS (Backup Server): $HAS_PBS"
echo -e " - PDM (Manager): $HAS_PDM"
echo ""

# --- 5. Version-specific workflow ---
if [[ "$PVE_MAJOR" == "8" ]]; then
    header "Proxmox VE 8 → 9 Upgrade Mode"

    # --- 5.1. Ensure no enterprise repos before any apt operations ---
    ensure_no_enterprise_repos

    # --- 5.2. Run pre-flight checks (install pve8to9 if missing) ---
    log "Running pve8to9 pre-flight checks..."
    if ! command -v pve8to9 &>/dev/null; then
        warn "pve8to9 tool missing. Installing prerequisites automatically..."
        apt-get update
        apt-get dist-upgrade "${APT_OPTS[@]}"
        if ! command -v pve8to9 &>/dev/null; then
            err "pve8to9 still not available after update. Manual intervention required."
        fi
        log "pve8to9 now available. Continuing..."
    fi

    if ! pve8to9 --full; then
        err "Pre-flight checks failed. Fix errors above before continuing."
    fi

    # --- 5.3. Check PBS tasks ---
    if [[ "$HAS_PBS" == "yes" ]] && command -v proxmox-backup-manager &>/dev/null; then
        ACTIVE_JOBS=$(proxmox-backup-manager task list --all 2>/dev/null | grep -i "running" | wc -l || echo "0")
        if (( ACTIVE_JOBS > 0 )); then
            warn "PBS has $ACTIVE_JOBS running tasks. This may cause issues during upgrade."
        fi
    fi

    # --- 5.4. Check cluster ---
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
        warn "This node is CLUSTERED. Upgrade ONE node at a time!"
        sleep 3
    fi

    # --- 5.5. Backup sources ---
    backup_sources

    # --- 5.6. Update repositories bookworm → trixie ---
    remove_enterprise_repos
    configure_repos_for_trixie

    # --- 5.7. Auto-upgrade if explicitly requested ---
    if [[ "$AUTO_UPGRADE" == "true" ]]; then
        header "Performing Automatic Upgrade (AUTO_UPGRADE=true)"
        warn "Starting unattended dist-upgrade in 5 seconds..."
        sleep 5

        log "Running: apt update..."
        apt-get update

        log "Running: apt dist-upgrade (unattended)..."
        apt-get dist-upgrade "${APT_OPTS[@]}"

        log "Upgrade complete!"
    fi

elif [[ "$PVE_MAJOR" == "9" ]]; then
    header "Proxmox VE 9 Post-Install Mode"
    log "Already on PVE 9, ensuring configuration is correct..."
    remove_enterprise_repos
    configure_repos_for_trixie
else
    err "Unsupported Proxmox VE version: $PVE_MAJOR (Only 8.x and 9.x supported)"
fi

# =============================================
# UNIVERSAL POST-INSTALL ROUTINES
# =============================================
header "Post-Install Configuration"
setup_nag_removal
manage_ha_services
log "Reinstalling proxmox-widget-toolkit to apply nag removal..."
apt-get --reinstall install "${APT_OPTS[@]}" proxmox-widget-toolkit || warn "Widget toolkit reinstall failed"

# =============================================
# FINAL SUMMARY
# =============================================
header "Configuration Complete!"
echo ""
echo -e "${GREEN}✓${NC} System configured"
echo -e "${GREEN}✓${NC} Subscription nag removed"
echo -e "${GREEN}✓${NC} HA services optimized"
echo -e "${GREEN}✓${NC} Non-interactive mode enabled (SSH-safe)"
echo ""

if [[ "$AUTO_UPGRADE" == "true" ]]; then
    echo -e "${YELLOW}AUTO-UPGRADE COMPLETED - NEXT STEPS:${NC}"
    echo -e "1. ${RED}REBOOT the system${NC}: ${YELLOW}reboot${NC}"
    echo -e "2. Clear browser cache (Ctrl+Shift+R) before using Web UI"
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
        echo -e "3. ${RED}If clustered: Run this script on OTHER nodes ONE AT A TIME${NC}"
    fi
else
    echo -e "${YELLOW}CRITICAL NEXT STEPS (DO THESE MANUALLY):${NC}"
    if [[ "$PVE_MAJOR" == "8" ]]; then
        echo -e "1. Review changes above carefully"
        echo -e "2. Run: ${RED}apt update${NC}"
        echo -e "3. Run: ${RED}apt dist-upgrade${NC}"
        echo -e "   ${YELLOW}→ Review package changes BEFORE confirming!${NC}"
        echo -e "   ${YELLOW}→ Choose 'Keep Current Version' for Proxmox configs${NC}"
        echo -e "   ${BLUE}OR run with AUTO_UPGRADE=true for unattended upgrade${NC}"
        echo -e "4. ${RED}REBOOT after successful upgrade${NC}"
    else
        echo -e "1. Run: ${RED}apt update${NC}"
        echo -e "2. Run: ${RED}apt upgrade${NC} (or dist-upgrade if needed)"
        echo -e "3. ${RED}REBOOT${NC}"
    fi
    echo -e "4. Clear browser cache (Ctrl+Shift+R) before using Web UI"
    if command -v pvecm &>/dev/null && pvecm status &>/dev/null; then
        echo -e "5. ${RED}If clustered: Run this script on OTHER nodes ONE AT A TIME${NC}"
    fi
fi
echo ""
echo -e "Backup location: ${BLUE}$BACKUP_DIR${NC}"
echo ""
if [[ "$AUTO_UPGRADE" != "true" ]]; then
    echo -e "${BLUE}TIP:${NC} For fully automated upgrade, run: ${YELLOW}AUTO_UPGRADE=true ./$(basename "$0")${NC}"
    echo ""
fi

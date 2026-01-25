#!/bin/bash
set -e

# --- CONFIGURATION ---
TARGET_CODENAME="trixie"
CURRENT_CODENAME="bookworm"
BACKUP_DIR="/root/apt_backup_$(date +%F_%H-%M)"
# ---------------------

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${GREEN}=== Proxmox 8 to 9 Upgrade Preparation (Debian 12→13) ===${NC}"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then err "Must run as root."; exit 1; fi

# 2. Product Detection & Status
log "Detecting Installed Proxmox Products..."
HAS_PVE=$(command -v pveversion > /dev/null && echo "yes" || echo "no")
HAS_PBS=$(dpkg -l | grep -q "proxmox-backup-server" && echo "yes" || echo "no")
HAS_PDM=$(dpkg -l | grep -q "proxmox-datacenter-manager" && echo "yes" || echo "no")

echo -e " - PVE (Hypervisor): \t${HAS_PVE}"
echo -e " - PBS (Backup Server): \t${HAS_PBS}"
echo -e " - PDM (Manager): \t\t${HAS_PDM}"

# 3. SAFETY CHECKS (The "Don't Leave Anything Behind" Phase)
log "Running Safety & Pre-flight Checks..."

# 3a. PVE Check (Official Tool)
if [[ "$HAS_PVE" == "yes" ]]; then
    if command -v pve8to9 > /dev/null; then
        log "Running official pve8to9 checklist..."
        if ! pve8to9 --full; then
            err "PVE pre-check failed. You must fix these errors before touching repositories."
            exit 1
        fi
    else
        err "pve8to9 tool missing. Please update your current system first:"
        err "  apt update && apt dist-upgrade"
        exit 1
    fi
fi

# 3b. PBS Active Task Check
if [[ "$HAS_PBS" == "yes" ]]; then
    log "Checking PBS for running tasks..."
    # Check for active tasks using proxmox-backup-manager
    if command -v proxmox-backup-manager > /dev/null; then
        # Get running tasks, skip header line, count results
        ACTIVE_JOBS=$(proxmox-backup-manager task list --all 2>/dev/null | grep -i "running" | wc -l || echo "0")

        if [[ $ACTIVE_JOBS -gt 0 ]]; then
            warn "PBS has $ACTIVE_JOBS running tasks!"
            warn "Upgrading PBS while tasks are running can corrupt the backup index."
            echo -e "Please stop all Datastores or enable Maintenance Mode."
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Aborting as requested."
                exit 1
            fi
        else
            log "PBS is clear (No active tasks)."
        fi
    else
        warn "proxmox-backup-manager not found, skipping PBS task check."
    fi
fi

# 3c. Cluster Health Check (if PVE is clustered)
if [[ "$HAS_PVE" == "yes" ]] && command -v pvecm > /dev/null; then
    if pvecm status &>/dev/null; then
        warn "This node is part of a Proxmox cluster!"
        warn "CRITICAL: Upgrade ONE NODE AT A TIME and verify cluster health between nodes."
        read -p "Have you verified this is safe to upgrade now? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Aborting. Please plan your cluster upgrade carefully."
            exit 1
        fi
    fi
fi

# 4. Backup Existing Sources
log "Backing up APT configuration..."
mkdir -p "$BACKUP_DIR"
cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/apt/sources.list.d/ "$BACKUP_DIR/" 2>/dev/null || true
log "Backup saved to $BACKUP_DIR"

# 5. Universal Repository Updater (Handles .list AND .sources)
update_repo_file() {
    local file=$1
    [ -e "$file" ] || return

    # Check if this file actually targets the old version
    if grep -q "$CURRENT_CODENAME" "$file"; then
        log "Updating ($CURRENT_CODENAME -> $TARGET_CODENAME): $file"
        # Safe replacement for both "deb ... bookworm" AND "Suites: bookworm"
        sed -i "s/$CURRENT_CODENAME/$TARGET_CODENAME/g" "$file"
    fi
}

log "Updating Repositories (PVE, PBS, PDM, Ceph)..."

# Main list
update_repo_file "/etc/apt/sources.list"

# Enable nullglob to handle cases where no files match
shopt -s nullglob

# All files in sources.list.d (covers both old .list and new .sources)
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    update_repo_file "$f"
done

shopt -u nullglob

# 6. Post-Update Verification
log "Verifying Repository Consistency..."

# Check for leftover "bookworm" references
if grep -r "$CURRENT_CODENAME" /etc/apt/sources.list* 2>/dev/null | grep -v "^#" | grep -v ".save" | grep -v "$BACKUP_DIR"; then
    warn "Some active repositories still point to '$CURRENT_CODENAME'. Please review output above."
else
    log "All active repositories successfully switched to '$TARGET_CODENAME'."
fi

# Check for Enterprise/No-Sub mismatches (Common production killer)
HAS_ENT=$(grep -r "enterprise.proxmox.com" /etc/apt/sources.list* 2>/dev/null | grep -v "^#" || true)
HAS_NOSUB=$(grep -r "no-subscription" /etc/apt/sources.list* 2>/dev/null | grep -v "^#" || true)

if [[ -n "$HAS_ENT" && -n "$HAS_NOSUB" ]]; then
    warn "Mixed Enterprise and No-Subscription repositories detected."
    warn "This can cause package dependency hell. Choose one track for production."
fi

echo ""
echo -e "${GREEN}=== Preparation Complete ===${NC}"
echo -e "${YELLOW}IMPORTANT REMINDERS:${NC}"
echo -e " • This upgrades Proxmox VE 8 → 9 (Debian 12 → 13)"
echo -e " • Take VM/CT backups BEFORE proceeding"
echo -e " • If clustered: upgrade ONE node at a time"
echo -e " • Test in non-production first if possible"
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo -e "1. Run: ${YELLOW}apt update${NC}"
echo -e "2. Run: ${YELLOW}apt dist-upgrade${NC}"
echo -e "   ${RED}NOTE:${NC} During upgrade, when asked about config files:"
echo -e "   → Choose 'Keep Current Version' for Proxmox configs (unless you know otherwise)"
echo -e "   → Review differences carefully for system files"
echo -e "3. Reboot after successful upgrade"
echo -e "4. Run: ${YELLOW}pveversion${NC} to verify PVE 9.x"
echo ""
echo -e "Backup location: ${YELLOW}$BACKUP_DIR${NC}"

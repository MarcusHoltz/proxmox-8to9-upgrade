#!/bin/bash
#
# Proxmox 9 (Debian 13 Trixie) Security Manager
# Menu-driven script for SSH hardening and Fail2ban management
#
# Author: Generated for Proxmox 9 / Debian 13
# Date: January 2026
#

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Banner
show_banner() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}Proxmox 9 Security Manager${NC} ${CYAN}v1.0${NC}                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     Debian 13 Trixie - Fail2ban & SSH Hardening          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}This script must be run as root${NC}" 
       exit 1
    fi
}

# Function: Install Fail2ban
install_fail2ban() {
    echo -e "${GREEN}[Installing Fail2ban]${NC}"
    echo ""
    
    if command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}Fail2ban is already installed.${NC}"
        read -p "Reinstall? (y/N): " reinstall
        [[ ! "$reinstall" =~ ^[Yy]$ ]] && return
    fi
    
    echo "Updating package list..."
    apt update
    echo "Installing fail2ban and python3-systemd..."
    apt install -y fail2ban python3-systemd
    
    echo -e "${GREEN}✓ Fail2ban installed successfully${NC}"
    sleep 2
}

# Function: Configure Fail2ban
configure_fail2ban() {
    echo -e "${GREEN}[Configuring Fail2ban]${NC}"
    echo ""
    
    # 1. Set Defaults for variables used in summary
    SSH_MAXRETRY="3"
    SSH_FINDTIME="1h"
    SSH_BANTIME="3h"
    PROXMOX_MAXRETRY="3"
    PROXMOX_FINDTIME="1h"
    PROXMOX_BANTIME="3h"
    FINDTIME="1h"
    MAXRETRY="3"
    OVERALL_JAILS="true"
    USE_MULTIPLIERS="false"

    # 2. Prompt for trusted IP
    echo -e "${YELLOW}Enter your trusted IP address or network:${NC}"
    echo "Examples: 192.168.1.100, 192.168.1.0/24, or leave blank for localhost only"
    read -p "Trusted IP: " TRUSTED_IP_INPUT
    
    if [[ -z "$TRUSTED_IP_INPUT" ]]; then
        TRUSTED_IP="127.0.0.1/8 ::1"
    else
        TRUSTED_IP="127.0.0.1/8 ::1 ${TRUSTED_IP_INPUT}"
    fi
    
    # 3. Ban time settings
    echo ""
    echo -e "${YELLOW}Ban time configuration:${NC}"
    echo "1) Conservative (1h initial, max 7d)"
    echo "2) Moderate (1h initial, max 30d) [Recommended]"
    echo "3) Aggressive (3h initial, max 90d)"
    echo "4) Custom"
    read -p "Select option [1-4]: " ban_option
    
    case $ban_option in
        1)
            INITIAL_BAN="1h"
            MAX_BAN="7d"
            BAN_FACTOR="12"
            ;;
        3)
            INITIAL_BAN="3h"
            MAX_BAN="90d"
            BAN_FACTOR="48"
            ;;
        4)
            read -p "Initial ban time (e.g., 1h, 30m): " INITIAL_BAN
            read -p "Maximum ban time (e.g., 30d, 1w): " MAX_BAN
            read -p "Ban factor (multiplier, e.g., 24): " BAN_FACTOR
            ;;
        *)
            INITIAL_BAN="1h"
            MAX_BAN="30d"
            BAN_FACTOR="24"
            ;;
    esac

    # ==========================================
    # CONFIGURATION SUMMARY (Fixed Location)
    # ==========================================
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Configuration Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Global Settings:${NC}"
    echo "  • Trusted IPs: ${TRUSTED_IP}"
    echo "  • Find time: ${FINDTIME}"
    echo "  • Default max retries: ${MAXRETRY}"
    echo "  • Initial ban time: ${INITIAL_BAN}"
    if [[ "$USE_MULTIPLIERS" == "true" ]]; then
        echo "  • Ban multipliers: ${BAN_MULTIPLIERS}"
    else
        echo "  • Ban factor: ${BAN_FACTOR}x"
        echo "  • Maximum ban time: ${MAX_BAN}"
    fi
    echo "  • Ban across all jails: ${OVERALL_JAILS}"
    echo ""
    echo -e "${YELLOW}SSH Jail:${NC}"
    echo "  • Max retries: ${SSH_MAXRETRY}"
    echo "  • Find time: ${SSH_FINDTIME}"
    echo "  • Ban time: ${SSH_BANTIME}"
    echo ""
    echo -e "${YELLOW}Proxmox Jail:${NC}"
    echo "  • Max retries: ${PROXMOX_MAXRETRY}"
    echo "  • Find time: ${PROXMOX_FINDTIME}"
    echo "  • Ban time: ${PROXMOX_BANTIME}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Apply this configuration? (Y/n): " apply_config
    
    if [[ "$apply_config" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Configuration cancelled${NC}"
        sleep 2
        return
    fi
    
    echo ""
    echo "Applying configuration..."
    echo ""
    
    # Backup existing config
    if [[ -f /etc/fail2ban/jail.local ]]; then
        echo "Backing up existing jail.local..."
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Create jail.local
    cat > /etc/fail2ban/jail.local <<EOF
#
# Fail2ban Configuration for Proxmox 9 / Debian 13
# Generated: $(date)
# Backend: systemd (Debian 13 uses journald, not rsyslog)
#

[DEFAULT]
# Use systemd journal backend (CRITICAL for Debian 13)
backend = systemd

# IP addresses to never ban
ignoreself = true
ignoreip = ${TRUSTED_IP}

# Ban settings with incremental increases
bantime = ${INITIAL_BAN}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}

# Incremental banning - multiplies ban time after each offense
bantime.increment = true
EOF

    if [[ "$USE_MULTIPLIERS" == "true" ]]; then
        cat >> /etc/fail2ban/jail.local <<EOF
# Ban time multipliers - each subsequent ban uses the next multiplier
bantime.multipliers = ${BAN_MULTIPLIERS}
EOF
    else
        cat >> /etc/fail2ban/jail.local <<EOF
# Ban factor - multiplies ban time exponentially
bantime.factor = ${BAN_FACTOR}
bantime.maxtime = ${MAX_BAN}
EOF
    fi

    cat >> /etc/fail2ban/jail.local <<EOF

# Search IP across all jails - if banned in one jail, counts toward all
bantime.overalljails = ${OVERALL_JAILS}

# Enable IPv6
allowipv6 = auto

#
# SSH Jail
#
[sshd]
enabled = true
port = ssh
backend = systemd
filter = sshd[mode=aggressive]
maxretry = ${SSH_MAXRETRY}
findtime = ${SSH_FINDTIME}
bantime = ${SSH_BANTIME}

#
# Proxmox Web Interface Jail
#
[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
backend = systemd
maxretry = ${PROXMOX_MAXRETRY}
findtime = ${PROXMOX_FINDTIME}
bantime = ${PROXMOX_BANTIME}

EOF
    
    # Create Proxmox filter
    cat > /etc/fail2ban/filter.d/proxmox.conf <<EOF
#
# Fail2ban filter for Proxmox VE
# Generated: $(date)
#

[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =

# Use systemd journal matching
journalmatch = _SYSTEMD_UNIT=pvedaemon.service

EOF
    
    # Restart fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    sleep 2
    echo -e "${GREEN}✓ Fail2ban configured successfully${NC}"
    sleep 3
}

# Function: Harden SSH
harden_ssh() {
    echo -e "${GREEN}[Hardening SSH Configuration]${NC}"
    echo ""
    
    # Backup original SSH config
    if [[ ! -f /etc/ssh/sshd_config.backup ]]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        echo -e "${YELLOW}Original sshd_config backed up${NC}"
    fi
    
    echo -e "${YELLOW}SSH Hardening Options:${NC}"
    echo "1) Full hardening (recommended - requires SSH keys)"
    echo "2) Moderate hardening (allows password auth)"
    echo "3) Custom configuration"
    echo "4) Cancel"
    read -p "Select option [1-4]: " ssh_option
    
    case $ssh_option in
        1)
            PERMIT_ROOT="prohibit-password"
            PERMIT_PASS="no"
            ;;
        2)
            PERMIT_ROOT="yes"
            PERMIT_PASS="yes"
            ;;
        3)
            echo ""
            echo "Permit root login?"
            echo "  yes = Allow root with password"
            echo "  prohibit-password = Allow root with keys only"
            echo "  no = Disable root login completely"
            read -p "PermitRootLogin [prohibit-password]: " PERMIT_ROOT
            PERMIT_ROOT=${PERMIT_ROOT:-prohibit-password}
            
            read -p "Allow password authentication? (yes/no) [no]: " PERMIT_PASS
            PERMIT_PASS=${PERMIT_PASS:-no}
            ;;
        *)
            echo "Cancelled."
            return
            ;;
    esac
    
    # Apply configurations
    grep -qi ^PermitEmptyPasswords /etc/ssh/sshd_config && \
      sed -i "s/PermitEmptyPasswords.*/PermitEmptyPasswords no/gI" /etc/ssh/sshd_config || \
      echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
    
    grep -qi ^PermitUserEnvironment /etc/ssh/sshd_config && \
      sed -i "s/PermitUserEnvironment.*/PermitUserEnvironment no/gI" /etc/ssh/sshd_config || \
      echo "PermitUserEnvironment no" >> /etc/ssh/sshd_config
    
    grep -qi ^Ciphers /etc/ssh/sshd_config && \
      sed -i "s/Ciphers.*/Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr/gI" /etc/ssh/sshd_config || \
      echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" >> /etc/ssh/sshd_config
    
    grep -qi ^PermitRootLogin /etc/ssh/sshd_config && \
      sed -i "s/PermitRootLogin.*/PermitRootLogin ${PERMIT_ROOT}/gI" /etc/ssh/sshd_config || \
      echo "PermitRootLogin ${PERMIT_ROOT}" >> /etc/ssh/sshd_config
    
    grep -qi ^PasswordAuthentication /etc/ssh/sshd_config && \
      sed -i "s/PasswordAuthentication.*/PasswordAuthentication ${PERMIT_PASS}/gI" /etc/ssh/sshd_config || \
      echo "PasswordAuthentication ${PERMIT_PASS}" >> /etc/ssh/sshd_config
    
    # Test configuration
    if sshd -t; then
        systemctl reload sshd.service
        echo ""
        echo -e "${GREEN}✓ SSH configuration updated and applied${NC}"
        echo -e "  PermitRootLogin: ${YELLOW}${PERMIT_ROOT}${NC}"
        echo -e "  PasswordAuthentication: ${YELLOW}${PERMIT_PASS}${NC}"
    else
        echo -e "${RED}✗ SSH configuration test failed!${NC}"
        echo "Restoring backup..."
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl reload sshd.service
    fi
    
    sleep 3
}

# Function: Check Jail Status
check_jail_status() {
    echo -e "${GREEN}[Fail2ban Jail Status]${NC}"
    echo ""
    
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}Fail2ban is not installed${NC}"
        sleep 2
        return
    fi
    
    if ! systemctl is-active --quiet fail2ban; then
        echo -e "${RED}Fail2ban service is not running${NC}"
        read -p "Start it now? (y/N): " start_f2b
        if [[ "$start_f2b" =~ ^[Yy]$ ]]; then
            systemctl start fail2ban
            sleep 2
        else
            return
        fi
    fi
    
    echo -e "${CYAN}Active Jails:${NC}"
    fail2ban-client status
    echo ""
    
    JAILS=$(fail2ban-client status | grep "Jail list" | sed -E 's/^[^:]+:[ \t]+//' | sed 's/,//g')
    
    for JAIL in $JAILS; do
        echo -e "${YELLOW}━━━ Jail: ${JAIL} ━━━${NC}"
        fail2ban-client status $JAIL
        echo ""
    done
    
    read -p "Press Enter to continue..."
}

# Function: Unban IP
unban_ip() {
    echo -e "${GREEN}[Unban IP Address]${NC}"
    echo ""
    
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}Fail2ban is not installed${NC}"
        sleep 2
        return
    fi
    
    JAILS=$(fail2ban-client status | grep "Jail list" | sed -E 's/^[^:]+:[ \t]+//' | sed 's/,//g')
    
    if [[ -z "$JAILS" ]]; then
        echo -e "${YELLOW}No active jails found${NC}"
        sleep 2
        return
    fi
    
    echo -e "${CYAN}Active Jails:${NC}"
    echo "$JAILS" | tr ' ' '\n' | nl
    echo ""
    
    read -p "Enter IP address to unban: " IP_TO_UNBAN
    
    if [[ -z "$IP_TO_UNBAN" ]]; then
        echo -e "${RED}No IP provided${NC}"
        sleep 2
        return
    fi
    
    echo ""
    echo "Unbanning $IP_TO_UNBAN from all jails..."
    for JAIL in $JAILS; do
        fail2ban-client set $JAIL unbanip $IP_TO_UNBAN 2>/dev/null && \
            echo -e "  ${GREEN}✓${NC} Unbanned from $JAIL" || \
            echo -e "  ${YELLOW}○${NC} Not banned in $JAIL"
    done
    
    echo ""
    read -p "Press Enter to continue..."
}

# Function: Test Filters
test_filters() {
    echo -e "${GREEN}[Test Fail2ban Filters]${NC}"
    echo ""
    
    if [[ ! -f /etc/fail2ban/filter.d/proxmox.conf ]]; then
        echo -e "${RED}Proxmox filter not found${NC}"
        sleep 2
        return
    fi
    
    echo -e "${CYAN}Testing Proxmox filter against systemd journal:${NC}"
    echo ""
    fail2ban-regex systemd-journal /etc/fail2ban/filter.d/proxmox.conf
    echo ""
    
    echo -e "${CYAN}Testing SSH filter against systemd journal:${NC}"
    echo ""
    fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf
    echo ""
    
    read -p "Press Enter to continue..."
}

# Function: View Fail2ban Logs
view_logs() {
    echo -e "${GREEN}[Fail2ban Logs]${NC}"
    echo ""
    echo "Press Ctrl+C to exit log view"
    sleep 2
    journalctl -u fail2ban -f
}

# Function: Configure bash history
configure_bash_history() {
    echo -e "${GREEN}[Configure Bash History]${NC}"
    echo ""
    echo "This will preserve bash history across multiple terminal windows."
    read -p "Configure bash history? (y/N): " config_hist
    
    if [[ ! "$config_hist" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Backup .bashrc
    if [[ -f /root/.bashrc ]]; then
        cp /root/.bashrc /root/.bashrc.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Add history configuration to .bashrc
    if ! grep -q "HISTCONTROL=ignoredups:erasedups" /root/.bashrc; then
        cat >> /root/.bashrc <<'BASHRC'

# Preserve bash history in multiple terminal windows
# Avoid duplicates
HISTCONTROL=ignoredups:erasedups
# When the shell exits, append to the history file instead of overwriting it
shopt -s histappend

# After each command, append to the history file and reread it
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}history -a; history -c; history -r"
BASHRC
        echo -e "${GREEN}✓ Bash history configuration added to /root/.bashrc${NC}"
    else
        echo -e "${YELLOW}Bash history already configured${NC}"
    fi
    
    sleep 2
}

# Function: Create Monitoring Script
create_monitoring_script() {
    cat > /usr/local/bin/fail2ban-monitor.sh <<'SCRIPT'
#!/bin/bash
#
# Fail2ban Monitoring Script
#

echo "========================================="
echo "Fail2ban Jail Status"
echo "Date: $(date)"
echo "========================================="
echo ""

if ! systemctl is-active --quiet fail2ban; then
    echo "ERROR: Fail2ban service is not running"
    exit 1
fi

JAILS=$(fail2ban-client status | grep "Jail list" | sed -E 's/^[^:]+:[ \t]+//' | sed 's/,//g')

for JAIL in $JAILS; do
    echo "━━━ $JAIL ━━━"
    fail2ban-client status $JAIL
    echo ""
done

echo "========================================="
echo "Testing Proxmox Filter"
echo "========================================="
fail2ban-regex systemd-journal /etc/fail2ban/filter.d/proxmox.conf | head -n 30
SCRIPT

    chmod +x /usr/local/bin/fail2ban-monitor.sh
    echo -e "${GREEN}✓ Monitoring script created: /usr/local/bin/fail2ban-monitor.sh${NC}"
    sleep 2
}

# Function: Show system info
show_info() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                     System Information                     ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${YELLOW}OS:${NC} $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "${YELLOW}Kernel:${NC} $(uname -r)"
    echo ""
    
    if command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}Fail2ban:${NC} ${GREEN}Installed${NC} ($(fail2ban-client version))"
        if systemctl is-active --quiet fail2ban; then
            echo -e "${YELLOW}Status:${NC} ${GREEN}Running${NC}"
        else
            echo -e "${YELLOW}Status:${NC} ${RED}Stopped${NC}"
        fi
    else
        echo -e "${YELLOW}Fail2ban:${NC} ${RED}Not Installed${NC}"
    fi
    echo ""
    
    if [[ -f /etc/ssh/sshd_config.backup ]]; then
        echo -e "${YELLOW}SSH Config Backup:${NC} ${GREEN}Available${NC}"
    else
        echo -e "${YELLOW}SSH Config Backup:${NC} ${RED}None${NC}"
    fi
    echo ""
    
    read -p "Press Enter to continue..."
}

# Main Menu
main_menu() {
    while true; do
        show_banner
        echo -e "${YELLOW}┌─ Main Menu${NC}"
        echo -e "${YELLOW}├─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│${NC}  1) Install Fail2ban                                        ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  2) Configure Fail2ban                                      ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  3) Harden SSH                                              ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  4) Check Jail Status                                       ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  5) Unban IP Address                                        ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  6) Test Filters                                            ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  7) View Live Logs                                          ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  8) Create Monitoring Script                                ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  9) Configure Bash History                                  ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  10) System Information                                     ${YELLOW}│${NC}"
        echo -e "${YELLOW}│${NC}  0) Exit                                                    ${YELLOW}│${NC}"
        echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -p "Select option [0-10]: " choice
        
        case $choice in
            1) clear; install_fail2ban ;;
            2) clear; configure_fail2ban ;;
            3) clear; harden_ssh ;;
            4) clear; check_jail_status ;;
            5) clear; unban_ip ;;
            6) clear; test_filters ;;
            7) clear; view_logs ;;
            8) clear; create_monitoring_script ;;
            9) clear; configure_bash_history ;;
            10) show_info ;;
            0) clear; echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# Start script
check_root
main_menu

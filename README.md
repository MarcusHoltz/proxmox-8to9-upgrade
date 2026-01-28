# Proxmox 8→9 Upgrade Script

Upgrades Proxmox VE/PBS/PDM from version 8 to 9 (Debian 12→13).

## Quick Start


### Update PVE 8 first

```bash
apt update
apt dist-upgrade
```

### Run proxmox-8to9-upgrade.sh

**Script is idempotent** - safe to run and re-run.

```bash
chmod +x proxmox-8to9-upgrade.sh
./proxmox-8to9-upgrade
apt update
apt dist-upgrade
```
*answer some questions in terminal* **no longer** script runs unattended
```bash
reboot
```

## Step 2: Secure It (After Reboot)

Run this additional script if this is a fresh Proxmox install, it will lock down SSH and the Proxmox https port.

### Run add_fail2ban.sh

```bash
chmod +x add_fail2ban.sh
./add_fail2ban.sh
```

## Proxmox update Gotchas

- BACKUP YOUR VMS/CONTAINERS FIRST
- **Clustered?** Upgrade ONE node at a time, verify cluster health between nodes
- **PBS running backups?** Stop them first or risk corruption
- **Mixed repos?** Script will warn - fix enterprise vs no-subscription conflicts
- **Config file prompts?** Choose "Keep Current Version" for Proxmox configs
- **Enterprise repo enabled?** Script removes it (causes 401 errors without subscription)

## What It Does

### Run in PVE8

1. Runs pre-flight checks (pve8to9)
2. Backs up your APT sources to `/root/apt_backup_*`
3. Updates all repos from bookworm→trixie
4. Configures no-subscription repos
5. Tells you what to do next

* * *

### Run in PVE9 (Post-Install)

1. Removes enterprise repos (prevents 401 errors)
2. Migrates to modern deb822 `.sources` format
3. Disables legacy `.list` files

* * *

### Both PVE8 and PVE9 modes

- Removes subscription nag (web + mobile UI)
- Disables HA services on single nodes

> Does NOT auto-run `apt dist-upgrade` (you do this manually)

## If Something Breaks

Your old sources are in `/root/apt_backup_[DATE]` - restore with:
```bash
cp /root/apt_backup_*/sources.list /etc/apt/
cp -r /root/apt_backup_*/sources.list.d/* /etc/apt/sources.list.d/
```

## Support

- Official docs: https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
- Forum: https://forum.proxmox.com

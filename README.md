# Proxmox 8→9 Upgrade Script

Upgrades Proxmox VE/PBS/PDM from version 8 to 9 (Debian 12→13).

## Quick Start

```bash
chmod +x proxmox-8to9-upgrade.sh
./proxmox-8to9-upgrade
apt update
apt dist-upgrade
```
*answer some questions in terminal*
```bash
reboot
```

## Proxmox update Gotchas

- **BACKUP YOUR VMS/CONTAINERS FIRST**
- **Clustered?** Upgrade ONE node at a time, verify cluster health between nodes
- **PBS running backups?** Stop them first or risk corruption
- **Mixed repos?** Script will warn - fix enterprise vs no-subscription conflicts
- **Config file prompts?** Choose "Keep Current Version" for Proxmox configs
- **Enterprise repo enabled?** Script removes it (causes 401 errors without subscription)

## What It Does

1. Runs pre-flight checks (pve8to9)
2. Backs up your APT sources to `/root/apt_backup_*`
3. Updates all repos from bookworm→trixie
4. Configures no-subscription repos
5. Tells you what to do next

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

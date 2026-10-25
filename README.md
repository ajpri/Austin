# linux-scripts

Shell scripts for setting up Linux machines.

## fedorasetup.sh

Provisions a Fedora machine: installs Docker CE, schedules a weekly Docker image prune, installs XCP-ng guest utilities, neofetch, nano, and mailx, configures ssmtp as a mail relay, and spins up Portainer and Watchtower.

```bash
wget -O - https://raw.githubusercontent.com/ajpri/linux-scripts/main/fedorasetup.sh | bash
```

## foginstall.sh

Installs a FOG imaging server on Debian/Ubuntu: installs git, clones FOGProject, and runs the FOG installer.

```bash
curl -sSL https://raw.githubusercontent.com/ajpri/linux-scripts/main/foginstall.sh | bash
```

## download-iso.sh

One self-contained ISO downloader. No arguments shows examples; pick a product and a folder and it downloads, verifies, and publishes atomically.

Products: Windows 11, Windows Server Evaluation, Ubuntu, Debian, Fedora, XCP-ng, Proxmox VE, TrueNAS SCALE, pfSense (Netgate Installer), OPNsense, Hiren's BootCD PE, Clonezilla Live, Memtest86+, Linux Mint, Pop!_OS, Arch Linux.

```bash
./download-iso.sh ubuntu /mnt/isos --edition server
```

Published SHA256 is verified (except Windows Server Evaluation, which uses size/ETag plus ISO structure). Requires Bash 4+, curl, Python 3, flock, and CA certificates.

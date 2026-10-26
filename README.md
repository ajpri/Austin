# linux-scripts

Shell scripts for setting up Linux machines and downloading installation ISOs.

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

One self-contained Linux command for downloading and verifying installation ISOs.
It runs without prompts and supports unattended cron jobs. Run it without arguments
for ready-to-use examples showing the defaults configured in the script.

### Quick start

```bash
curl -fL -o download-iso.sh https://raw.githubusercontent.com/ajpri/linux-scripts/main/download-iso.sh
chmod +x download-iso.sh
./download-iso.sh
```

Choose a product to start a download. The folder is optional, defaults to the
current directory, and **must already exist**. The script never creates it.

```bash
# Download using the product's defaults into the current directory
./download-iso.sh qubes
./download-iso.sh gparted

# Choose a folder and edition
./download-iso.sh ubuntu /mnt/isos --edition server
./download-iso.sh LinuxMint --edition xfce
./download-iso.sh popos --edition nvidia

# Preserve existing ISO files, or suppress routine output
./download-iso.sh qubes /mnt/isos --keep-existing
./download-iso.sh gparted --silent

# Redirect progress and messages to a log
./download-iso.sh ubuntu > ubuntu.log 2>&1

# See version choices, defaults, filenames, and cleanup rules for a product
./download-iso.sh qubes --help
```

### Supported products

All images target x86-64/amd64. Product names are case-insensitive.

| Product argument | Download selection |
| --- | --- |
| `win11` | Current Windows 11 English (US) multi-edition ISO |
| `winserver` | Windows Server Evaluation; version 2022 or 2025 |
| `ubuntu` | Configured release family, newest point ISO; Desktop or Server |
| `debian` | Configured major release, newest point release; netinst ISO |
| `fedora` | Configured final release; Workstation Live or Server DVD |
| `xcpng` | Configured XCP-ng family; exact versions/previews also supported |
| `proxmox` | Configured Proxmox VE family; exact builds/previews also supported |
| `truenas` | Configured Linux-based TrueNAS SCALE/Community Edition family |
| `pfsense` | Current Netgate online installer; not an offline pfSense CE ISO |
| `opnsense` | Configured OPNsense Community family; newest published DVD installer |
| `hbcdpe` | Current Hiren's BootCD PE |
| `clonezilla` | Current stable Debian-based Clonezilla Live |
| `memtest86plus` | Current open-source Memtest86+ standard 64-bit ISO |
| `LinuxMint` | Current stable Linux Mint; Cinnamon, MATE, or Xfce |
| `popos` | Current Pop!_OS; generic or NVIDIA image |
| `arch` | Current dated Arch Linux installation ISO |
| `gparted` | Current stable GParted Live |
| `qubes` | Configured Qubes OS family; newest stable point ISO |

Aliases: `memtest86+` for `memtest86plus`, and `pop` for `popos`.

Default versions and editions are grouped near the top of `download-iso.sh`.
Changing those settings automatically updates the no-argument help examples.
Use that help as the source of current defaults; this README does not duplicate
release numbers that would need updating separately.

### Options and file handling

```text
download-iso.sh PRODUCT [EXISTING_FOLDER] [OPTIONS]
```

| Option | Behavior |
| --- | --- |
| `--version VALUE` | Overrides the configured version for products supporting version selection; see product help for accepted formats |
| `--edition VALUE` | Selects an available edition for Ubuntu, Fedora, Linux Mint, or Pop!_OS |
| `--keep-existing` | Preserves all history and an existing exact output filename, after downloading and verifying a fresh copy |
| `--silent`, `-s` | Suppresses routine messages and progress; errors remain on stderr and failures return nonzero |
| `--help`, `-h` | Shows general or product-specific help without downloading |

Options can appear before or after the folder. Quote paths with spaces, and use
`--` before a folder name beginning with a dash. `--version=VALUE` and
`--edition=VALUE` are also accepted where supported.

Every download invocation fetches a fresh copy, including with `--keep-existing`.
There is no version check that skips a transfer. The selected source filename is
logged. Output names include the local run-start date as `YYMMDD`; versioned
products also include their release or family, such as
`Qubes_<family>_<YYMMDD>.iso`. GParted uses `gparted_<YYMMDD>.iso`.

Without `--keep-existing`, a verified download replaces today's exact filename
and prunes managed history according to that product's cleanup rules. Product
help describes the scope. Other products and unrelated files are preserved.
Downloads stage in the destination and publish atomically after verification;
failures before publication preserve existing ISOs. Per-product locks prevent
concurrent downloads of the same product into the same folder.

### Requirements and verification

Requires Linux, Bash 4+, curl, Python 3 (standard library), `flock`, and CA certificates.
Qubes additionally requires `gpg`.

```bash
# Debian/Ubuntu dependencies
sudo apt-get install bash curl python3 util-linux ca-certificates

# Additional dependency for Qubes downloads
sudo apt-get install gnupg
```

HTTPS certificate validation stays enabled. Published SHA256 checksums and ISO
structure are verified. For compressed downloads, the archive checksum is checked
before extraction. Windows Server Evaluation is the exception: it checks Microsoft
source URLs, expected size, strong ETag when available, and ISO structure; its
calculated SHA256 is logged without an official checksum comparison.

**Qubes also requires a valid detached PGP signature on the ISO.** Its release key
must be certified by the Qubes master key whose fingerprint is pinned in the
script. Verification uses a temporary keyring without changing personal GPG keys
or trust settings. Invalid or missing verification data causes failure; there is
no option to bypass it. Other products do not verify detached signatures.

pfSense uses the FileEagle mirror for Netgate Installer and requires its archive
to match Netgate's official checksum. Windows Server downloads Evaluation media.
See each product's help for its sources and specific selection behavior.

### Monthly cron example

Use absolute paths and an existing download folder:

```cron
0 3 1 * * /bin/bash /path/to/download-iso.sh qubes /mnt/isos >> /path/to/qubes.log 2>&1
```

The script creates no log automatically; shell redirection controls logging.
Allow room for the fresh download alongside existing files, plus extraction space
for compressed images. Normal exits remove staging files; forced termination or
power loss can leave hidden staging directories. Monitor job logs for failures or
upstream source changes.

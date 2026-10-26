# linux-scripts

Shell scripts for setting up Linux machines and downloading installation images.

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

One self-contained Linux command for downloading and verifying installation images.
Downloads run without prompts and support unattended cron jobs; interactive runs
can offer to install missing dependencies first. Run it without arguments
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
./download-iso.sh chromeosflex
./download-iso.sh omv
./download-iso.sh netbootxyz

# Choose a folder and edition
./download-iso.sh ubuntu /mnt/isos --edition server
./download-iso.sh LinuxMint --edition xfce
./download-iso.sh popos --edition nvidia
./download-iso.sh win11 --edition pro

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
| `win11` | Current Windows 11 English (US); untouched multi-edition or an `ei.cfg` edition selector |
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
| `chromeosflex` | Current stable Google ChromeOS Flex recovery disk image, saved as `.img` |
| `openmediavault` / `omv` | Configured major, newest numerically named amd64 ISO from the project's SourceForge directory |
| `netbootxyz` / `netboot.xyz` | Current rolling netboot.xyz BIOS/UEFI network-boot ISO |

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
| `--edition VALUE` | Selects an available edition for Windows 11, Ubuntu, Fedora, Linux Mint, or Pop!_OS |
| `--keep-existing` | Preserves all history and an existing exact output filename, after downloading and verifying a fresh copy |
| `--silent`, `-s` | Suppresses routine messages and progress; errors remain on stderr and failures return nonzero |
| `--check-deps` | Checks tools only; never prompts, installs, or downloads. Exit 0 if available, nonzero if missing |
| `--help`, `-h` | Shows general or product-specific help without downloading |

Options can appear before or after the folder. Quote paths with spaces, and use
`--` before a folder name beginning with a dash. `--version=VALUE` and
`--edition=VALUE` are also accepted where supported.

Every download invocation fetches a fresh copy, including with `--keep-existing`.
There is no version check that skips a transfer. The selected source filename is
logged. Output names include the local run-start date as `YYMMDD`; versioned
products also include their release or family, such as
`Qubes_<family>_<YYMMDD>.iso`. GParted uses `gparted_<YYMMDD>.iso`.
ChromeOS Flex uses `ChromeOSFlex_<YYMMDD>.img`, with no version selector.
OpenMediaVault uses `OpenMediaVault_<major.minor>_<YYMMDD>.iso`; its default major is
configured near the top of the script, or overridden with `omv --version 8`.
Releases are selected numerically; an 8.3.1 download produces
`OpenMediaVault_8.3_<YYMMDD>.iso`, with the full source version logged. Cleanup
covers the same major, including legacy major-only names, and preserves other majors.
netboot.xyz uses `netboot.xyz_<YYMMDD>.iso` and has no version selector.

Without `--keep-existing`, a verified download replaces today's exact filename
and prunes managed history according to that product's cleanup rules. Product
help describes the scope. Other products and unrelated files are preserved.
Downloads stage in the destination and publish atomically after verification;
failures before publication preserve existing images. Per-product locks prevent
concurrent downloads of the same product into the same folder. Locking uses
Python’s standard-library `fcntl.flock`; no `flock` command/package is required.

### Requirements and verification

Requires Linux, Bash 4+, curl, Python 3 (standard library), and CA certificates.
Qubes additionally requires `gpg`.

```bash
# Check all products, including Qubes and Windows edition customization tools
./download-iso.sh --check-deps

# Check only the selected product and edition
./download-iso.sh win11 --edition pro --check-deps
./download-iso.sh fedora --check-deps
```

Dependency-only checks do not require or touch a download folder. Missing tools
are listed with an installation command for supported OS families. Add `--silent`
to hide a successful check's message; errors still appear.

The script checks dependencies needed by the selected product and edition. On
Fedora and Debian/Ubuntu families (including derivatives identified through
`/etc/os-release`), it shows the appropriate package command and offers to install
missing tools. Installation requires an explicit **yes**; `sudo` may request your
password. After installation it checks the tools again and continues the download.

The offer appears only when standard input, standard output, and standard error are terminals.
Cron, redirected logs, piped input, and `--silent` never prompt or install packages;
they exit nonzero with the missing tools and the manual installation command.
Other Linux distributions can run the downloader with dependencies preinstalled,
but automatic installation is limited to the families above with `apt-get`/`dnf`
available. Fedora Atomic desktops require their own package-management workflow.

```bash
# Debian/Ubuntu dependencies
sudo apt install bash curl python3 ca-certificates

# Additional dependency for Qubes downloads
sudo apt install gnupg

# Additional dependencies for Windows 11 edition customization
sudo apt install p7zip-full genisoimage

# Fedora dependencies
sudo dnf install bash curl python3 ca-certificates

# Additional dependency for Qubes downloads
sudo dnf install gnupg2

# Additional dependencies for Windows 11 edition customization
sudo dnf install 7zip genisoimage
```

These manual examples use `apt`; the script uses `apt-get` for its stable scripting
interface, as [recommended by Debian](https://www.debian.org/doc/manuals/debian-reference/ch02).
The full 7-Zip executable may be named `7z` or `7zz`; reduced `7za`/`7zr` builds
are not used for Windows UDF extraction. Fedora package mappings follow its
official [7zip](https://packages.fedoraproject.org/pkgs/7zip/7zip/) and
[genisoimage](https://packages.fedoraproject.org/pkgs/cdrkit/genisoimage/) listings.

HTTPS certificate validation stays enabled. Published SHA256 checksums and ISO
structure are verified. For compressed downloads, the archive checksum is checked
before extraction. Windows Server Evaluation is the exception: it checks Microsoft
source URLs, expected size, strong ETag when available, and ISO structure; its
calculated SHA256 is logged without an official checksum comparison.
ChromeOS Flex is the other checksum exception: Google's official recovery feed
publishes SHA-1 rather than SHA256. The hash covers the ZIP, as specified in
[Google's recovery format](https://chromium.googlesource.com/chromiumos/user-recovery-tools/+/HEAD/README_formats.txt).
The script checks the stable ZIP's size, exact
member name, ZIP CRC, extracted image size and published ZIP SHA-1. It also verifies
the protective MBR, primary/backup GPT checksums and matching partition tables,
partition bounds, and ChromeOS/EFI partition types. A calculated image SHA256 is
logged for reference. No additional packages are needed.

ChromeOS Flex uses the exact versioned stable image from
[Google's recovery feed](https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json);
beta, development, and LTS channels are excluded. Google's original `.bin` bytes
are extracted unchanged and saved with an `.img` extension. This is a USB disk
image, not an ISO conversion. The script only downloads it; it does not write to
USB devices. Allow room for both the ZIP and the extracted image during staging.
Only `ChromeOSFlex_<YYMMDD>.img` history is pruned; other files are preserved.
See [Google's installation instructions](https://support.google.com/chromeosflex/answer/11541904?hl=en)
for using the image.

**Qubes also requires a valid detached PGP signature on the ISO.** Its release key
must be certified by the Qubes master key whose fingerprint is pinned in the
script. Verification uses a temporary keyring without changing personal GPG keys
or trust settings. Invalid or missing verification data causes failure; there is
no option to bypass it. Other products do not verify detached signatures.

pfSense uses the FileEagle mirror for Netgate Installer and requires its archive
to match Netgate's official checksum. Windows Server downloads Evaluation media.
See each product's help for its sources and specific selection behavior.

OpenMediaVault verifies the chosen ISO against its `.sha256` sidecar on the
[project's SourceForge mirror](https://sourceforge.net/projects/openmediavault/files/iso/).
Its installer requires an Internet connection. netboot.xyz verifies the standard
ISO against the official boot server's SHA256 manifest; this small image loads
a network-boot menu and downloads the selected OS environment when booted.
See [netboot.xyz downloads](https://netboot.xyz/downloads/).

VMware ESXi is currently not supported. Broadcom's official free ISO download
requires account login and acceptance of its terms, so it does not use the
account-free workflow provided here. See
[Broadcom's download instructions](https://knowledge.broadcom.com/external/article/399823/vmware-esxi-80-update-3e-now-available-a.html).

### Windows 11 edition selection

```bash
./download-iso.sh win11 --edition multi          # Original, unchanged Microsoft ISO
./download-iso.sh win11 --edition pro            # Setup selects Windows 11 Pro
./download-iso.sh win11 --edition pro-workstations
./download-iso.sh win11 --edition ProfessionalN  # Microsoft IDs also accepted
```

`multi` is the default. It keeps the existing filename format,
`Win11_<version>_<YYMMDD>.iso`, with no `Multi` label and no customization tools
required. A customized image includes the edition, for example
`Win11_Pro_<version>_<YYMMDD>.iso`. Cleanup histories are separate by edition.

Edition aliases include Home, Home N, Home Single Language, Pro, Pro N,
Education, Education N, Pro Education, Pro Education N, and Pro for Workstations
and its N variant. Names are case-insensitive; use hyphens between words.
Microsoft edition IDs are also recognized. Unknown names fail before downloading.
7-Zip reads edition metadata from the downloaded WIM/ESD; no `wimlib-imagex`
package is needed. Recognized editions must actually exist there or the command
fails with an available-edition list. No edition is silently substituted.

Customization verifies Microsoft's source checksum first, adds `sources/ei.cfg`
with the selected edition (`Retail`, `VL=0`), and rebuilds UDF media. It retains
the other installation images and adds no product key. An installation answer
file takes precedence over `ei.cfg`.

The rebuild checks BIOS/UEFI boot images, every payload file, and the new selector.
Its calculated SHA256 is logged separately; a customized ISO does not match
Microsoft's original checksum. Allow about three ISO sizes of temporary staging
space, in addition to any existing destination files. `--keep-existing` still
downloads, customizes, and verifies a fresh copy before retaining an existing file.

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

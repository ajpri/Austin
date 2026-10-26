#!/bin/bash
# One self-contained ISO downloader for Linux. No arguments shows examples only.
# Usage: ./download-iso.sh PRODUCT [EXISTING_FOLDER] [OPTIONS]
# Products: win11, winserver, ubuntu, debian, fedora, xcpng, proxmox, truenas,
#           pfsense, opnsense, hbcdpe, clonezilla, memtest86plus, LinuxMint, popos,
#           arch, qubes, gparted, chromeosflex, openmediavault (omv), netbootxyz.
# Run PRODUCT --help for version/source details.
# Folder defaults to the current directory; it must already exist.
# --version VALUE and --edition VALUE apply only to products supporting them.
# --keep-existing retains history and existing exact names, but still downloads
# and verifies a fresh copy on every run. Default cleanup follows product scope.
# --silent/-s suppresses routine output/progress; errors stay on stderr/nonzero.
# --check-deps checks tools only; never prompts, installs, or downloads.
# ./download-iso.sh --check-deps checks all products, including optional tools.
# ./download-iso.sh win11 --edition pro --check-deps checks only that selection.
# Options may surround the folder; use -- before a dash-prefixed folder.
# Downloads stage in the destination, then publish atomically after validation.
# Failures before publication preserve existing ISOs. Persistent per-product
# locks prevent concurrent runs of the same product into the same folder.
# Missing tools: offers installation on Fedora/Debian/Ubuntu families when stdin,
# stdout and stderr are terminals. Requires confirmation; sudo may ask for a password.
# Cron, redirected runs and --silent never prompt/install; errors give a command.
# No accounts or separate helper scripts are required. Windows edition
# customization rebuilds its ISO locally; other downloads use ready-made images.
# pfSense downloads Netgate Installer (third-party mirror + Netgate checksum),
# not a standalone offline CE installer. Windows Server uses Evaluation media.
# ChromeOS Flex downloads Google's stable recovery ZIP, saved as an unchanged
# .img disk image. It verifies the ZIP's published SHA-1 and sizes plus GPT structure;
# SHA256 is calculated for reference (Google's feed does not publish SHA256).
# All transfers require HTTPS with certificate checking enabled. Published SHA256
# is verified except Server Eval (size/ETag + ISO structure) and ChromeOS Flex
# (published SHA-1 + sizes + GPT structure). Calculated SHA256 is logged for both.
# Qubes additionally verifies its ISO's PGP signature using a release key certified
# by the pinned Qubes master key. Other products do not check detached signatures.
# Upstream source changes can cause errors.
# Requirements: Bash 4+, curl, Python 3 (standard library), CA certificates.
# Debian/Ubuntu: sudo apt install bash curl python3 ca-certificates
# Fedora: sudo dnf install bash curl python3 ca-certificates
# Qubes additionally requires gpg: Debian/Ubuntu gnupg; Fedora gnupg2.
# Windows edition customization additionally requires 7z/7zz and genisoimage:
# Debian/Ubuntu p7zip-full genisoimage; Fedora 7zip genisoimage.
# Full 7z or 7zz is accepted; it also reads WIM/ESD edition metadata.
# It verifies the original Microsoft ISO first, then rebuilds UDF media with an
# ei.cfg selector. Other editions stay in the WIM/ESD. Only multi remains identical
# to Microsoft's ISO. Allow about three ISO sizes of staging space for rebuilding.
# Allow room for new ISOs alongside existing ones. Temporary directories are
# removed on exit; SIGKILL/power loss can leave hidden *-download.* directories.
# Example: ./download-iso.sh ubuntu /mnt/isos --edition server > ubuntu.log 2>&1
# Cron (monthly; absolute paths):
# 0 3 1 * * /bin/bash /path/to/download-iso.sh debian /mnt/isos >> /path/to/iso.log 2>&1

# Edit these defaults periodically. Help examples use these same values.
DEFAULT_WIN11_EDITION="multi"
DEFAULT_WINSERVER_VERSION="2025"
DEFAULT_UBUNTU_VERSION="26.04"
DEFAULT_UBUNTU_EDITION="desktop"
DEFAULT_DEBIAN_VERSION="13"
DEFAULT_FEDORA_VERSION="44"
DEFAULT_FEDORA_EDITION="workstation"
DEFAULT_XCPNG_VERSION="8.3"
DEFAULT_PROXMOX_VERSION="9.2"
DEFAULT_TRUENAS_VERSION="25.10"
DEFAULT_OPNSENSE_VERSION="26.7"
DEFAULT_QUBES_VERSION="4.3"
DEFAULT_OMV_VERSION="8"
DEFAULT_LINUXMINT_EDITION="cinnamon"
DEFAULT_POPOS_EDITION="generic"

set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077

die() {
    printf 'ERROR: %s\n' "$*" >&2
    if [[ ${product:-} == all ]]; then
        printf 'Help: %s --help\n' "$0" >&2
    else
        printf 'Help: %s %s--help\n' "$0" "${product:+$product }" >&2
    fi
    exit 1
}
show_help() {
    cat <<HELP
ISO Downloader

Usage: $0 PRODUCT [FOLDER] [OPTIONS]
Folder defaults to the current directory and must already exist.

DOWNLOAD USING DEFAULTS

  $0 win11       # Current Windows 11, English x64; edition: $DEFAULT_WIN11_EDITION
  $0 winserver   # Windows Server Evaluation $DEFAULT_WINSERVER_VERSION
  $0 ubuntu      # Ubuntu ${DEFAULT_UBUNTU_EDITION^} $DEFAULT_UBUNTU_VERSION
  $0 debian      # Latest Debian $DEFAULT_DEBIAN_VERSION netinst
  $0 fedora      # Fedora ${DEFAULT_FEDORA_EDITION^} $DEFAULT_FEDORA_VERSION
  $0 xcpng       # XCP-ng $DEFAULT_XCPNG_VERSION
  $0 proxmox     # Proxmox VE $DEFAULT_PROXMOX_VERSION
  $0 truenas     # TrueNAS SCALE $DEFAULT_TRUENAS_VERSION
  $0 pfsense     # Current Netgate Installer
  $0 opnsense    # OPNsense Community $DEFAULT_OPNSENSE_VERSION DVD installer, amd64
  $0 hbcdpe      # Current Hiren's BootCD PE
  $0 clonezilla  # Current stable Clonezilla Live, amd64
  $0 memtest86plus # Current open-source Memtest86+, 64-bit
  $0 LinuxMint   # Current Linux Mint ${DEFAULT_LINUXMINT_EDITION^}, 64-bit
  $0 popos       # Current Pop!_OS ${DEFAULT_POPOS_EDITION^}, amd64
  $0 arch        # Current Arch Linux installation ISO, x86_64
  $0 gparted     # Current stable GParted Live, amd64
  $0 chromeosflex # Current stable ChromeOS Flex, x86-64 .img disk image
  $0 openmediavault # Latest OpenMediaVault $DEFAULT_OMV_VERSION amd64 ISO (alias: omv)
  $0 netbootxyz  # Current netboot.xyz BIOS/UEFI network-boot ISO
  $0 qubes       # Qubes OS $DEFAULT_QUBES_VERSION, newest stable x86_64 ISO in that family

COMMON EXAMPLES

  # Download into another folder
  $0 ubuntu /mnt/isos

  # Choose a version and server edition
  $0 ubuntu --version 24.04 --edition server
  $0 fedora --edition server
  $0 winserver --version 2022
  $0 win11 --edition pro

  # Check tools only; no download or installation
  $0 --check-deps
  $0 win11 --edition pro --check-deps

  # Preserve existing files (still downloads and verifies a fresh copy)
  $0 debian --keep-existing

  # Suppress progress; errors remain visible
  $0 proxmox --silent

  # Save progress and messages to a log
  $0 ubuntu > ubuntu.log 2>&1

MORE HELP

  $0 ubuntu --help

Missing dependencies: interactive terminals offer installation on Fedora and
Debian/Ubuntu families. Cron, redirected runs and --silent never prompt/install;
they exit with an error and an install command instead.
HELP
}
product_help() {
    printf 'Usage: %s %s [FOLDER] [OPTIONS]\n\n' "$0" "$product"
    case $product in
        openmediavault) cat <<HELP
OpenMediaVault amd64 installer. Default major version: $DEFAULT_OMV_VERSION.
--version MAJOR selects the newest numerically named ISO in that major family.
Numeric release directories only; preview-suffixed names are excluded.
Uses the project's SourceForge ISO directory and the selected ISO's SHA256 file.
The filename includes the downloaded major.minor (8.3 for 8.3.1), without the
patch suffix; full source version is logged. Requires Internet during installation.
Source: https://sourceforge.net/projects/openmediavault/files/iso/
Output: OpenMediaVault_<major.minor>_<YYMMDD>.iso. Cleanup: same major only,
including older filenames that contained only the major version.
Examples: $0 openmediavault /mnt/isos
          $0 omv --version 7
HELP
        ;;
        netbootxyz) cat <<HELP
Current rolling netboot.xyz x86 BIOS/UEFI ISO from the official boot server.
No version or edition option. Downloads netboot.xyz.iso and verifies its SHA256
against netboot.xyz-sha256-checksums.txt. No additional dependencies.
This is a small network-boot menu, not an offline OS collection; network access
is required to fetch the selected installer/live environment when booted.
Source: https://boot.netboot.xyz/ipxe/
Output: netboot.xyz_<YYMMDD>.iso. Cleanup: same product's dated ISO history only.
Example: $0 netbootxyz /mnt/isos
HELP
        ;;
        chromeosflex) cat <<HELP
Current stable ChromeOS Flex x86-64 recovery disk image from Google.
No version or edition option. Beta/Dev/LTS channels are not selected.
Downloads the exact ZIP named in Google's recovery feed, checks archive/image
sizes, ZIP CRC, the published ZIP SHA-1, and primary/backup GPT structures.
Google's feed publishes SHA-1, not SHA256; calculated image SHA256 is logged.
Extracts the original .bin bytes unchanged and saves them with an .img extension.
This is a USB disk image, not an ISO; no ISO conversion or USB writing is done.
Uses Python's standard library; no extra dependencies.
Source: https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json
Output: ChromeOSFlex_<YYMMDD>.img. Cleanup: ChromeOSFlex_<YYMMDD>.img history only.
Example: $0 chromeosflex /mnt/isos
HELP
        ;;
        win11) cat <<HELP
Current Windows 11 multi-edition x64 English (US), from Microsoft's dynamic links.
Default edition: $DEFAULT_WIN11_EDITION. No version option.
--edition multi|home|home-n|home-single-language|pro|pro-n|education|education-n|
          pro-education|pro-education-n|pro-workstations|pro-workstations-n
Microsoft IDs (Professional, Core, etc.) are also accepted, case-insensitively.
Enterprise, Enterprise N/LTSC, Home China and IoT Enterprise IDs are recognized,
but customization requires that edition to actually exist in the downloaded ISO.
Typos fail before download; missing image editions fail with an available list.
multi leaves the verified Microsoft ISO untouched. Other selections add
sources/ei.cfg (Retail, VL=0) without removing or changing WIM/ESD images.
An installation answer file takes precedence over ei.cfg. No product key is added.
Verifies Microsoft's SHA256 BEFORE editing. The customized ISO has its own hash.
Customization requires 7z/7zz and genisoimage (Debian/Ubuntu packages:
p7zip-full genisoimage; Fedora: 7zip genisoimage).
BIOS/UEFI boot images and all payload files are
checked after the UDF rebuild. Allow about three ISO sizes of staging space.
Output (multi): Win11_<version>_<YYMMDD>.iso (no Multi label).
Output (custom): Win11_<Edition>_<version>_<YYMMDD>.iso, e.g. Win11_Pro_26H2_261026.iso.
Cleanup: same edition's history across versions; other editions remain untouched.
Examples: $0 win11 --edition pro
          $0 win11 --edition ProfessionalWorkstation
HELP
        ;;
        winserver) cat <<HELP
Windows Server Evaluation x64 English (US). Default: $DEFAULT_WINSERVER_VERSION.
--version 2022|2025. Setup offers Standard/Datacenter and Core/Desktop Experience.
Official Microsoft source; checks size, strong ETag if available, and ISO structure.
SHA256 is calculated for reference; no published checksum comparison is available.
Output: WinServerEval_<year>_<YYMMDD>.iso. Cleanup: same year only.
HELP
        ;;
        ubuntu) cat <<HELP
Ubuntu amd64. Defaults: $DEFAULT_UBUNTU_EDITION $DEFAULT_UBUNTU_VERSION.
--edition desktop|server. Server uses the live-server installer.
--version YY.MM selects the newest point ISO within that release family.
Released LTS/interim families must be within standard support (not Pro/ESM-only).
No release allowlist; support dates come from upstream distro-info data.
Official images/checksums: https://releases.ubuntu.com/
Output: Ubuntu_<Desktop|Server>_<YY.MM>_<YYMMDD>.iso (no point suffix).
Cleanup: same edition and family only.
HELP
        ;;
        debian) cat <<HELP
Debian amd64 netinst. Default major: $DEFAULT_DEBIAN_VERSION.
--version MAJOR selects the newest published numeric point release in that major.
Any positive major is accepted if official images exist; no preview substitution.
Uses https://cdimage.debian.org/debian-cd/ and its official image archive.
Choose desktop environments or a headless setup in the installer; Internet is
needed for additional packages. SHA256 verified against the official manifest.
Output: Debian_<full-point-version>_<YYMMDD>.iso. Cleanup: same major only,
including legacy Debian_Netinst_<version>_<YYMMDD>.iso names.
HELP
        ;;
        fedora) cat <<HELP
Fedora x86_64. Defaults: $DEFAULT_FEDORA_EDITION $DEFAULT_FEDORA_VERSION.
--edition workstation|server. Workstation: Live ISO; Server: full DVD ISO.
--version NUMBER accepts any positive release number, without an allowlist.
Requires a final matching ISO in https://fedoraproject.org/releases.json.
No Beta/RC/Rawhide substitution or archive fallback. Checks official size/SHA256.
Output: Fedora_<Workstation|Server>_<version>_<YYMMDD>.iso.
Cleanup: same edition and version only.
HELP
        ;;
        xcpng) cat <<HELP
XCP-ng x86_64. Default family: $DEFAULT_XCPNG_VERSION.
--version FAMILY selects its newest stable patch/update/refresh (8.3 includes U2).
An exact patch/update/refresh or preview selector is also accepted if published.
Examples: --version 8.3.1; --version 8.3-U2; --version 8.3.0-rc2.
Uses official XCP-ng manifests/mirrors, with SHA256 verification.
Output: XCP-ng_<family>_<YYMMDD>.iso; explicit previews retain their full suffix.
Cleanup: same stable family, or same exact preview, only.
HELP
        ;;
        proxmox) cat <<HELP
Proxmox VE amd64. Default family: $DEFAULT_PROXMOX_VERSION.
--version FAMILY selects its newest numeric patch/build; exact builds and previews
are supported: --version 9.2-1; --version 9.0-BETA-1 (if listed).
Uses https://enterprise.proxmox.com/iso/ with official SHA256 verification.
The public endpoint requires no login/subscription. Downloads VE, not Backup,
Mail Gateway, Datacenter Manager, or ARM images.
Output: Proxmox_VE_<family>_<YYMMDD>.iso; explicit previews retain full suffix.
Cleanup: same stable family, or same exact preview, only.
HELP
        ;;
        truenas) cat <<HELP
Linux-based TrueNAS SCALE / Community Edition. Default family: $DEFAULT_TRUENAS_VERSION.
--version FAMILY selects its newest patch; exact releases/previews also work:
--version 25.10.7; --version 27.0.0-RC.1 (if published).
Uses https://download.sys.truenas.net/ with official SHA256 verification.
Excludes FreeBSD-based CORE and update files.
Output: TrueNAS_SCALE_<family>_<YYMMDD>.iso; previews retain their full suffix.
Cleanup: same stable family, or same exact preview, only.
HELP
        ;;
        pfsense) cat <<HELP
Current Netgate Installer amd64, downloaded fresh; no version or edition option.
Uses FileEagle's mirror and requires a matching official Netgate SHA256 for the
compressed archive. Extracts the ISO locally. This is the online installer;
installation downloads pfSense packages, rather than using an offline CE ISO.
Output: pfsense_<YYMMDD>.iso. Cleanup: all prior managed pfSense installer files,
including legacy Netgate_Installer_<version>_<YYMMDD>.iso names.
HELP
        ;;
        opnsense) cat <<HELP
OPNsense Community Edition amd64 DVD ISO (live system/installer).
Default family: $DEFAULT_OPNSENSE_VERSION. --version FAMILY overrides it.
Selects the newest published numeric installer within that family, without
switching families or substituting preview/business images. Verifies the official
SHA256 of the bzip2 archive, then extracts and validates the ISO locally.
Source: https://pkg.opnsense.org/releases/
Output: OPNsense_<family>_<YYMMDD>.iso. Cleanup: same family only; other versions
and legacy unversioned opnsense_<YYMMDD>.iso files are preserved.
Example: $0 opnsense --version 26.1
HELP
        ;;
        hbcdpe) cat <<HELP
Current Hiren's BootCD PE x64 from https://www.hirensbootcd.org/download/.
No version or edition option. Checks the project's published size and SHA256.
Output: hbcdpe_<YYMMDD>.iso. Cleanup: prior managed HBCD PE files, including
legacy HBCD_PE_<version>_<YYMMDD>.iso names.
HELP
        ;;
        clonezilla) cat <<HELP
Current stable Debian-based Clonezilla Live amd64 (not testing/alternative stable).
No version or edition option. Uses the project's stable SHA256 checksum page
and official SourceForge downloads. Verifies SHA256 and ISO structure.
Source: https://clonezilla.org/downloads.php
Output: clonezilla_<YYMMDD>.iso. Cleanup: prior managed Clonezilla ISO files.
HELP
        ;;
        gparted) cat <<HELP
Current stable GParted Live amd64 ISO. No version or edition option.
Reads the current stable SHA256 manifest from the GParted project and downloads
its exact versioned image from the project's SourceForge stable directory.
Excludes testing releases, ZIP archives, and other CPU architectures.
Source: https://gparted.org/gparted-live/stable/CHECKSUMS.TXT
Output: gparted_<YYMMDD>.iso. Cleanup: prior managed GParted ISO files only.
HELP
        ;;
        memtest86plus) cat <<HELP
Current stable open-source Memtest86+ standard x86_64 ISO (not PassMark MemTest86).
No version or edition option. Downloads the official ZIP, verifies its SHA256,
then extracts and validates the ISO. Excludes nightly builds and other platforms.
Source: https://www.memtest.org/
Output: memtest86plus_<YYMMDD>.iso. Cleanup: prior managed Memtest86+ ISO files.
The product name memtest86+ is also accepted.
HELP
        ;;
        linuxmint) cat <<HELP
Current stable Linux Mint 64-bit. Default edition: $DEFAULT_LINUXMINT_EDITION.
--edition cinnamon|mate|xfce. No version option; discovers the newest numeric
release in the project's stable mirror and verifies its SHA256.
Excludes beta, LMDE, HWE, and other image variants.
Source: https://pub.linuxmint.io/stable/
Output: LinuxMint_<Edition>_<version>_<YYMMDD>.iso.
Cleanup: same edition and release version only. LinuxMint is case-insensitive.
Example: $0 LinuxMint /mnt/isos --edition xfce
HELP
        ;;
        popos) cat <<HELP
Current Pop!_OS amd64. Default edition: $DEFAULT_POPOS_EDITION.
--edition generic|nvidia. No version option. Uses the current release advertised
by System76's download page and the matching official build API metadata.
Verifies the API's SHA256 and exact byte size. Excludes ARM and preview builds.
Sources: https://system76.com/pop/download/ and https://api.pop-os.org/
Output: PopOS_<Generic|Nvidia>_<version>_<YYMMDD>.iso.
Cleanup: same edition and release version only. The name pop is also accepted.
Example: $0 popos --edition nvidia
HELP
        ;;
        arch) cat <<HELP
Current Arch Linux x86_64 installation ISO. No version or edition option.
Resolves the dated ISO from the official geo mirror's latest SHA256 manifest,
then downloads the immutable dated path. Logs the source snapshot date.
Source: https://geo.mirror.pkgbuild.com/iso/
Output: Arch_<YYMMDD>.iso (run date). Cleanup: prior managed Arch ISO files.
HELP
        ;;
        qubes) cat <<HELP
Qubes OS x86_64. Default family: $DEFAULT_QUBES_VERSION.
--version FAMILY selects the newest stable point release within that family.
No automatic switch to another family; release candidates are excluded.
Checks the published SHA256 and the ISO's detached PGP signature. The release
key must be certified by the Qubes master key whose fingerprint is pinned in
this script. Missing/invalid keys or signatures fail; verification is mandatory.
Requires gpg (Debian/Ubuntu: sudo apt install gnupg; Fedora: sudo dnf install gnupg2).
Signature verification runs without prompts,
using a temporary keyring; your personal GPG keyring and trust settings are unused.
Source: https://ftp.qubes-os.org/iso/ and https://keys.qubes-os.org/keys/
Output: Qubes_<family>_<YYMMDD>.iso. Cleanup: same family only.
Example: $0 qubes /mnt/isos --version $DEFAULT_QUBES_VERSION
HELP
        ;;
    esac
    cat <<HELP

Common options:
  --keep-existing  Keep all history and an existing exact filename; always fetch fresh.
  --silent, -s     Hide routine status/progress; preserve errors and nonzero exits.
  --check-deps     Check this selection's tools only; never install or download.
  --help, -h       Show this help without downloading.
Folder defaults to . and must exist. Quote paths containing spaces.
Options accept --version=VALUE / --edition=VALUE where supported.
Without --keep-existing, verified downloads replace today's file and prune the
managed history described above. Other products remain untouched.
Missing dependencies: offers installation on Fedora/Debian/Ubuntu families only
when stdin, stdout and stderr are terminals. Cron, redirected runs and --silent never
prompt/install; missing dependencies produce an error with an install command.

Examples:
  $0 $product
  $0 $product "/mnt/ISO Collection" --keep-existing
  $0 $product --silent > ${product}-errors.log 2>&1
HELP
}

dependency_present() {
    if [[ $1 == 7z ]]; then
        command -v 7z >/dev/null || command -v 7zz >/dev/null
    else
        command -v "$1" >/dev/null
    fi
}

ensure_dependencies() {
    local cmd family='' token package answer
    local ID='' ID_LIKE='' PRETTY_NAME='Linux'
    local -a missing=() packages=() privilege=() install=()
    local -A seen=()
    for cmd in "${dependencies[@]}"; do
        dependency_present "$cmd" || missing+=("$cmd")
    done
    (( ${#missing[@]} )) || return 0

    # os-release is provided by the installed OS, never by downloaded metadata.
    if [[ -r /etc/os-release ]]; then
        source /etc/os-release
    elif [[ -r /usr/lib/os-release ]]; then
        source /usr/lib/os-release
    fi
    for token in $ID $ID_LIKE; do
        case $token in
            debian|ubuntu) family=debian; break ;;
            fedora|rhel|centos) family=fedora; break ;;
        esac
    done
    printf 'Missing dependencies: %s.\n' "${missing[*]}" >&2
    [[ -n $family ]] || die "Automatic dependency installation is unavailable for $PRETTY_NAME. Install the missing tools, then rerun."
    for cmd in "${missing[@]}"; do
        case "$family:$cmd" in
            debian:gpg) package=gnupg ;;
            debian:7z) package=p7zip-full ;;
            fedora:gpg) package=gnupg2 ;;
            fedora:7z) package=7zip ;;
            *) package=$cmd ;;
        esac
        if [[ ! ${seen[$package]+yes} ]]; then
            packages+=("$package")
            seen[$package]=1
        fi
    done
    # Ensure the standard HTTPS trust store when installing any missing tools.
    packages+=(ca-certificates)
    if (( EUID != 0 )); then privilege=(sudo); fi
    if [[ $family == debian ]]; then
        install=(apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y -- "${packages[@]}")
        printf 'Install on %s: ' "$PRETTY_NAME" >&2
        printf '%q ' "${privilege[@]}" apt install -- "${packages[@]}" >&2
    else
        install=(dnf install -y -- "${packages[@]}")
        printf 'Install on %s: ' "$PRETTY_NAME" >&2
        printf '%q ' "${privilege[@]}" dnf install -- "${packages[@]}" >&2
    fi
    printf '\n' >&2
    if (( ${check_only:-0} )); then
        die 'Dependency check failed; no installation or download attempted.'
    fi
    if (( silent )) || [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
        die 'Install the dependencies above, then rerun. No installation attempted in non-interactive/silent mode.'
    fi
    command -v "${install[0]}" >/dev/null || die "Package manager ${install[0]} is unavailable. Install the dependencies using your OS's package manager, then rerun."
    if (( EUID != 0 )); then
        command -v sudo >/dev/null || die 'sudo is unavailable. Have an administrator install the packages above, then rerun.'
    fi
    printf 'Install these packages now? [y/N] ' >&2
    IFS= read -r answer || answer=''
    [[ $answer == [yY] || ${answer,,} == yes ]] || die 'Dependency installation declined; no download started.'
    if [[ $family == debian ]]; then
        "${privilege[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update || die 'Package index refresh failed; no download started.'
        "${privilege[@]}" env DEBIAN_FRONTEND=noninteractive "${install[@]}" || die 'Dependency installation failed; no download started.'
    else
        "${privilege[@]}" "${install[@]}" || die 'Dependency installation failed; no download started.'
    fi
    hash -r
    missing=()
    for cmd in "${dependencies[@]}"; do
        dependency_present "$cmd" || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "Dependencies still unavailable after installation: ${missing[*]}. No download started."
}

product=''
check_only=0
if (( $# == 0 )); then show_help; exit 0; fi
case $1 in --help|-h) show_help; exit 0 ;; esac
if [[ $1 == --check-deps ]]; then
    product=all
    check_only=1
else
    product=${1,,}
fi
[[ $product != memtest86+ ]] || product=memtest86plus
[[ $product != pop ]] || product=popos
[[ $product != omv ]] || product=openmediavault
[[ $product != netboot.xyz ]] || product=netbootxyz
shift
requested=''
edition=''
version_supported=1
edition_supported=0
lock_id=$product
case $product in
    all) (( check_only )) || die 'Use --check-deps to check all products.'; version_supported=0 ;;
    win11) version_supported=0; edition=$DEFAULT_WIN11_EDITION; edition_supported=1 ;;
    pfsense|hbcdpe|clonezilla|memtest86plus|arch|gparted|chromeosflex|netbootxyz) version_supported=0 ;;
    openmediavault) requested=$DEFAULT_OMV_VERSION ;;
    opnsense) requested=$DEFAULT_OPNSENSE_VERSION ;;
    qubes) requested=$DEFAULT_QUBES_VERSION ;;
    linuxmint) version_supported=0; edition=$DEFAULT_LINUXMINT_EDITION; edition_supported=1 ;;
    popos) version_supported=0; edition=$DEFAULT_POPOS_EDITION; edition_supported=1 ;;
    winserver) requested=$DEFAULT_WINSERVER_VERSION; lock_id=winServerEval ;;
    ubuntu) requested=$DEFAULT_UBUNTU_VERSION; edition=$DEFAULT_UBUNTU_EDITION; edition_supported=1 ;;
    debian) requested=$DEFAULT_DEBIAN_VERSION ;;
    fedora) requested=$DEFAULT_FEDORA_VERSION; edition=$DEFAULT_FEDORA_EDITION; edition_supported=1 ;;
    xcpng) requested=$DEFAULT_XCPNG_VERSION ;;
    proxmox) requested=$DEFAULT_PROXMOX_VERSION ;;
    truenas) requested=$DEFAULT_TRUENAS_VERSION; lock_id=truenas-scale ;;
    *) unknown=$product; product=''; die "Unknown product: $unknown. Run without arguments to see supported products." ;;
esac
keep=0
silent=0
destination=.
path_given=0
options=1
while (( $# )); do
    if (( options )); then
        case $1 in
            --help|-h) if [[ $product == all ]]; then show_help; else product_help; fi; exit 0 ;;
            --silent|-s) silent=1; shift; continue ;;
            --check-deps) check_only=1; shift; continue ;;
            --keep-existing|keep-existing) keep=1; shift; continue ;;
            --version|--edition|--version=*|--edition=*)
                key=${1%%=*}
                if [[ $key == --version ]]; then
                    (( version_supported )) || die "$product does not support --version; it downloads the current image."
                else
                    (( edition_supported )) || die "$product does not support --edition."
                fi
                if [[ $1 == *=* ]]; then value=${1#*=}; shift
                else
                    [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "$key requires a value."
                    value=$2; shift 2
                fi
                [[ -n $value && $value != -* ]] || die "$key requires a value."
                if [[ $key == --version ]]; then requested=$value; else edition=${value,,}; fi
                continue ;;
            --) options=0; shift; continue ;;
            -*) die "Unknown option: $1" ;;
        esac
    fi
    (( path_given == 0 )) || die 'Specify only one download folder.'
    destination=$1
    path_given=1
    shift
done
# Validate simple selectors before touching the destination or contacting sources.
case $product in
    win11)
        choice=${edition,,}; choice=${choice//-/}; choice=${choice//_/}; choice=${choice// /}
        case $choice in
            multi) edition=multi ;;
            home|core) edition=Core ;;
            homen|coren) edition=CoreN ;;
            homesinglelanguage|coresinglelanguage) edition=CoreSingleLanguage ;;
            homechina|corecountryspecific) edition=CoreCountrySpecific ;;
            pro|professional) edition=Professional ;;
            pron|professionaln) edition=ProfessionalN ;;
            prosinglelanguage|professionalsinglelanguage) edition=ProfessionalSingleLanguage ;;
            education) edition=Education ;;
            educationn) edition=EducationN ;;
            proeducation|professionaleducation) edition=ProfessionalEducation ;;
            proeducationn|professionaleducationn) edition=ProfessionalEducationN ;;
            proworkstation|proworkstations|professionalworkstation) edition=ProfessionalWorkstation ;;
            proworkstationn|proworkstationsn|professionalworkstationn) edition=ProfessionalWorkstationN ;;
            enterprise) edition=Enterprise ;;
            enterprisen) edition=EnterpriseN ;;
            enterpriseeval) edition=EnterpriseEval ;;
            enterpriseneval) edition=EnterpriseNEval ;;
            enterpriseg) edition=EnterpriseG ;;
            enterprisegn) edition=EnterpriseGN ;;
            cloudedition) edition=CloudEdition ;;
            cloudeditionn) edition=CloudEditionN ;;
            enterprises|enterpriseltsc) edition=EnterpriseS ;;
            enterprisesn|enterpriseltscn) edition=EnterpriseSN ;;
            iotenterprise) edition=IoTEnterprise ;;
            iotenterprises|iotenterpriseltsc) edition=IoTEnterpriseS ;;
            *) die "Unknown Windows edition: $edition. Choose multi, home, pro, education, their N variants, home-single-language, pro-education, or pro-workstations; see win11 --help for details." ;;
        esac ;;
    qubes) [[ $requested =~ ^[1-9][0-9]*\.[0-9]+$ ]] || die 'Use a Qubes release family such as 4.3 (without a point suffix).' ;;
    opnsense) [[ $requested =~ ^[0-9]{2}\.[0-9]+$ ]] || die 'Use an OPNsense release family such as 26.7 or 26.1.' ;;
    linuxmint) [[ $edition == cinnamon || $edition == mate || $edition == xfce ]] || die 'LinuxMint edition must be cinnamon, mate, or xfce.' ;;
    popos) [[ $edition == generic || $edition == nvidia ]] || die 'Pop!_OS edition must be generic or nvidia.' ;;
    winserver) [[ $requested == 2022 || $requested == 2025 ]] || die 'Choose Server version 2022 or 2025.' ;;
    ubuntu)
        [[ $requested =~ ^[0-9]{2}\.(04|10)$ ]] || die 'Use a release family such as 24.04 or 26.10 (without a point suffix).'
        [[ $edition == desktop || $edition == server ]] || die 'Ubuntu edition must be desktop or server.' ;;
    debian|fedora|openmediavault)
        [[ $requested =~ ^[1-9][0-9]*$ ]] || die 'Version must be a positive whole release number.'
        if [[ $product == fedora ]]; then
            [[ $edition == workstation || $edition == server ]] || die 'Fedora edition must be workstation or server.'
        fi ;;
esac
if (( silent )); then exec >/dev/null; fi
dependencies=(curl python3)
if [[ $product == qubes || $product == all ]]; then dependencies+=(gpg); fi
if [[ $product == all || ( $product == win11 && $edition != multi ) ]]; then
    dependencies+=(7z genisoimage)
fi
if (( check_only )); then
    ensure_dependencies
    printf 'All required dependencies are available for %s. No installation or download attempted.\n' "$product"
    exit 0
fi
[[ -d $destination ]] || die "Download folder does not exist or is not a directory: $destination"
folder=$(cd -- "$destination" && pwd -P)
[[ -w $folder ]] || die "Download folder is not writable: $folder"
run_date=$(date +%y%m%d)
ensure_dependencies
# Only the optional dependency offer above may read input. Downloads and all
# verification tools always see EOF, including runs started in a terminal.
exec </dev/null
trap 'rc=$?; printf "ERROR: ISO download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
exec 9>"$folder/.$lock_id-download.lock"
work=$(mktemp -d "$folder/.$lock_id-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Source resolvers only select a URL and verification metadata. The shared engine
# below handles every transfer, verification, output name, and retention policy.
# Parse the exit with this command so editing the script during a long download
# cannot make Bash resume reading at a stale offset after the engine finishes.
python3 - "$work" "$folder" "$product" "$requested" "$edition" "$run_date" "$keep" "$silent" <<'PY_ENGINE'; exit
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

sys.stdout.reconfigure(line_buffering=True)

def resolve_win11(work, requested, edition):
    import json
    import re
    import subprocess
    import sys
    import time
    import uuid
    from html.parser import HTMLParser
    from pathlib import Path
    from urllib.parse import urlencode, urlsplit, unquote


    page_url = 'https://www.microsoft.com/en-us/software-download/windows11'
    # Public website connector identifiers, not credentials. API flow documented by
    # Fido / MSDL. Microsoft may change these or reject unattended clients.
    profile = '606624d44113'
    instance = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
    session = str(uuid.uuid4())
    user_agent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'

    def fetch(url, params=None):
        if params:
            url += '?' + urlencode(params)
        # Use curl's platform TLS/proxy support, finite retries, and one cookie jar.
        result = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120',
            '--user-agent', user_agent, '--referer', page_url,
            '--cookie', str(work / 'cookies'), '--cookie-jar', str(work / 'cookies'),
            url,
        ], check=True, stdout=subprocess.PIPE)
        return result.stdout.decode('utf-8-sig')

    class Page(HTMLParser):
        def __init__(self):
            super().__init__()
            self.in_select = False
            self.option = None
            self.options = []
            self.in_cell = False
            self.cell = ''
            self.cells = []
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == 'select':
                self.in_select = attrs.get('id') == 'product-edition'
            if tag == 'option' and self.in_select:
                self.option = [attrs.get('value', ''), '']
            if tag == 'td':
                self.in_cell, self.cell = True, ''
        def handle_data(self, data):
            if self.option is not None:
                self.option[1] += data
            if self.in_cell:
                self.cell += data
        def handle_endtag(self, tag):
            if tag == 'option' and self.option is not None:
                self.options.append(self.option)
                self.option = None
            if tag == 'select':
                self.in_select = False
            if tag == 'td' and self.in_cell:
                self.cells.append(self.cell.strip())
                self.in_cell = False

    try:
        html = fetch(page_url)
        page = Page()
        page.feed(html)
        products = [(pid, title) for pid, title in page.options
                    if pid.isdigit() and re.search(r'Windows\s+11', title, re.I)
                    and re.search(r'multi.edition', title, re.I)
                    and re.search(r'\bx64\b', title, re.I)]
        if len(products) != 1:
            raise RuntimeError('Cannot uniquely identify the current x64 multi-edition ISO on Microsoft\'s page.')
        product_id, _ = products[0]
        release = re.search(r'Current release:[^<]{0,200}?\bVersion\s+(\d{2}H[12])\b', html, re.I)
        if not release:
            raise RuntimeError('Cannot identify the current release version on Microsoft\'s page.')
        version = release[1].upper()
        # Require the page's English x64 hash; it binds the bytes to today's product.
        hashes = [page.cells[i + 1] for i, label in enumerate(page.cells[:-1])
                  if label == 'English 64-bit' and re.fullmatch(r'[A-Fa-f0-9]{64}', page.cells[i + 1])]
        if len(hashes) != 1:
            raise RuntimeError('Cannot identify Microsoft\'s English x64 SHA-256 checksum.')
        fetch('https://vlscppe.microsoft.com/tags', dict(org_id='y6jn8c31', session_id=session))
        mdt = fetch('https://ov-df.microsoft.com/mdt.js',
                    dict(instanceId=instance, PageId='si', session_id=session))
        w = re.search(r'[?&]w=([A-Fa-f0-9]+)', mdt)
        ticks = re.search(r'rticks=\"\+?(\d+)', mdt)
        if not w or not ticks:
            raise RuntimeError('Microsoft session registration format changed (MDT parameters unavailable).')
        fetch('https://ov-df.microsoft.com/', dict(session_id=session, CustomerId=instance,
              PageId='si', w=w[1], mdt=int(time.time() * 1000), rticks=ticks[1]))
        sku_url = 'https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition'
        sku_data = json.loads(fetch(sku_url, dict(profile=profile, productEditionId=product_id,
            SKU='undefined', friendlyFileName='undefined', Locale='en-US', sessionID=session)))
        if sku_data.get('Errors'):
            raise RuntimeError('Microsoft refused language lookup: ' + str(sku_data['Errors']))
        skus = [s for s in sku_data.get('Skus', []) if s.get('Language', '').casefold() in ('english', 'en-us')]
        if len(skus) != 1:
            raise RuntimeError('Cannot uniquely identify English (United States) in the Microsoft SKU list.')
        links_url = 'https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku'
        links_data = json.loads(fetch(links_url, dict(profile=profile, productEditionId='undefined',
            SKU=skus[0]['Id'], friendlyFileName='undefined', Locale='en-US', sessionID=session)))
        if links_data.get('Errors'):
            raise RuntimeError('Microsoft refused ISO link generation: ' + str(links_data['Errors']))
        links = [link['Uri'] for link in links_data.get('ProductDownloadOptions', [])
                 if str(link.get('DownloadType')) == '1' or link.get('Architecture', '').lower() == 'x64']
        if len(links) != 1:
            raise RuntimeError('Microsoft did not return exactly one x64 ISO link.')
        url = links[0]
        parsed = urlsplit(url)
        host = parsed.hostname or ''
        if parsed.scheme != 'https' or not host.endswith('.microsoft.com') or parsed.username or parsed.password:
            raise RuntimeError('Unexpected ISO download host; refusing download.')
        filename = unquote(parsed.path.rsplit('/', 1)[-1])
        match = re.fullmatch(r'Win11_(\d{2}H[12])(?:_[A-Za-z0-9.-]+)*_English_x64\.iso', filename, re.I)
        generic = re.fullmatch(r'Windows11_Client_x64_en-us_\d+_\d+\.iso', filename, re.I)
        if not match and not generic:
            raise RuntimeError('Unexpected Microsoft ISO filename: ' + filename)
        if match and match[1].upper() != version:
            raise RuntimeError('Microsoft ISO filename version disagrees with the current release page.')
        (work / 'url').write_text(url)
        (work / 'version').write_text(version)
        (work / 'sha256').write_text(hashes[0].lower())
        print('Selected Microsoft ISO: ' + filename + ' (version ' + version + ')')
    except (Exception, KeyboardInterrupt) as exc:
        sys.exit('ERROR: Could not obtain the current Microsoft ISO link: ' + str(exc))

def resolve_winserver(work, requested, edition):
    import re
    import subprocess
    import sys
    from pathlib import Path
    from urllib.parse import unquote, urlsplit

    url = ('https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
           if requested == '2022' else 'https://aka.ms/WinServ2025iso-enus')
    try:
        start = urlsplit(url)
        if (start.scheme != 'https' or start.username or start.password
            or not ((start.hostname or '').endswith('.microsoft.com') or start.hostname in ('microsoft.com', 'aka.ms'))):
            raise RuntimeError('Configured URL must use an HTTPS Microsoft or aka.ms host.')
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--head', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '--retry-delay', '3',
            '--connect-timeout', '20', '--max-time', '120', '--dump-header', str(work / 'headers'),
            '--output', '/dev/null', '--write-out', '%{url_effective}', url,
        ], check=True, stdout=subprocess.PIPE)
        resolved = response.stdout.decode().strip()
        parsed = urlsplit(resolved)
        if (parsed.scheme != 'https' or parsed.username or parsed.password
            or not (parsed.hostname or '').endswith('.microsoft.com')):
            raise RuntimeError('Microsoft redirect did not resolve to an HTTPS Microsoft download host.')
        name = unquote(parsed.path.rsplit('/', 1)[-1])
        if not re.fullmatch(r'(?:[A-Za-z0-9_.-]+_)?SERVER_EVAL_x64FRE_en-us\.iso', name, re.I):
            raise RuntimeError('Unexpected ISO filename (expected x64 English Server Evaluation): ' + name)
        # curl can dump several header blocks while following redirects. Use the last.
        headers = (work / 'headers').read_text().replace('\r\n', '\n')
        blocks = [b for b in headers.split('\n\n') if b.startswith('HTTP/')]
        if not blocks or blocks[-1].splitlines()[0].split()[1] != '200':
            raise RuntimeError('ISO metadata request did not return HTTP 200.')
        final = blocks[-1]
        sizes = re.findall(r'^Content-Length:[ \t]*(\d+)[ \t]*$', final, re.I | re.M)
        if len(sizes) != 1 or int(sizes[0]) < 32774:
            raise RuntimeError('Microsoft did not return a usable Content-Length; refusing an unvalidated transfer.')
        tags = re.findall(r'^ETag:[ \t]*([^\n]+)$', final, re.I | re.M)
        etag = tags[0].strip() if len(tags) == 1 else ''
        # Weak ETags cannot be used with If-Match's strong comparison.
        if etag.startswith('W/'):
            etag = ''
        if etag and not re.fullmatch(r'"[^"\x00-\x20\x7f]+"', etag):
            raise RuntimeError('Unexpected Microsoft ETag format.')
        (work / 'url').write_text(resolved)
        (work / 'size').write_text(sizes[0])
        (work / 'etag').write_text(etag)
        print('Selected Microsoft ISO: ' + name)
        print('Expected download size: ' + sizes[0] + ' bytes')
    except Exception as exc:
        sys.exit('ERROR: Could not resolve Windows Server Evaluation ISO: ' + str(exc))

def resolve_ubuntu(work, requested, edition):
    import csv
    import datetime
    import io
    import re
    import subprocess
    import sys
    from pathlib import Path

    version = requested
    base = 'https://releases.ubuntu.com/'
    lifecycle_url = 'https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv'

    def fetch(url):
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
        ], check=True, stdout=subprocess.PIPE)
        return response.stdout.decode('utf-8-sig')

    try:
        reader = csv.DictReader(io.StringIO(fetch(lifecycle_url)))
        if not {'version', 'release', 'eol'}.issubset(reader.fieldnames or []):
            raise RuntimeError('Unexpected upstream lifecycle data format.')
        rows = [row for row in reader if row.get('version', '').split()[:1] == [version]]
        if len(rows) != 1:
            raise RuntimeError('Release family not uniquely listed in lifecycle data: ' + version)
        row = rows[0]
        release = datetime.date.fromisoformat(row['release'])
        eol_field = 'eol-server' if edition == 'server' and row.get('eol-server') else 'eol'
        end = datetime.date.fromisoformat(row[eol_field])
        today = datetime.date.today()
        if not release <= today < end:
            raise RuntimeError(f'Ubuntu {version} {edition} is not within standard support '
                               f'(release {release}, support ends {end}); no substitute was selected.')
        image_type = 'desktop' if edition == 'desktop' else 'live-server'
        pattern = re.compile(r'ubuntu-(' + re.escape(version) + r'(?:\.[0-9]+)?)-' + image_type + r'-amd64\.iso')
        candidates = {}
        for line in fetch(base + version + '/SHA256SUMS').splitlines():
            entry = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(\S+)', line.strip())
            if not entry:
                continue
            digest, name = entry.groups()
            image = pattern.fullmatch(name)
            if not image:
                continue
            if name in candidates and candidates[name][1] != digest.lower():
                raise RuntimeError('Conflicting official checksums for ' + name)
            # Base release and .0 compare identically; reject an ambiguous tie below.
            point = int(image[1].split('.')[2]) if image[1].count('.') == 2 else 0
            candidates[name] = (point, digest.lower())
        if not candidates:
            raise RuntimeError('No checksummed released amd64 ' + image_type + ' ISO for ' + version)
        latest = max(row[0] for row in candidates.values())
        names = [name for name, row in candidates.items() if row[0] == latest]
        if len(names) != 1:
            raise RuntimeError('Ambiguous latest point release; no ISO was substituted.')
        name = names[0]
        for key, value in [('url', base + version + '/' + name), ('sha256', candidates[name][1])]:
            (work / key).write_text(value)
        print('Selected official ISO: ' + name)
        print(f'Standard support ends: {end}')
    except Exception as exc:
        sys.exit('ERROR: Could not resolve Ubuntu ISO: ' + str(exc))

def resolve_debian(work, requested, edition):
    import re
    import subprocess
    import sys
    from html.parser import HTMLParser
    from pathlib import Path

    major = requested
    current_base = 'https://cdimage.debian.org/debian-cd/'
    archive_base = 'https://cdimage.debian.org/cdimage/archive/'

    def fetch(url):
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
        ], check=True, stdout=subprocess.PIPE)
        return response.stdout.decode('utf-8-sig')

    class Index(HTMLParser):
        def __init__(self):
            super().__init__()
            self.versions = set()
        def handle_starttag(self, tag, attrs):
            if tag != 'a':
                return
            href = dict(attrs).get('href', '')
            match = re.fullmatch(r'([1-9][0-9]*(?:\.[0-9]+)+)/', href)
            if match and match[1].split('.')[0] == major:
                self.versions.add(match[1])

    def versions_at(base):
        parser = Index()
        parser.feed(fetch(base))
        return parser.versions

    try:
        base = current_base
        versions = versions_at(base)
        if not versions:
            base = archive_base
            versions = versions_at(base)
        if not versions:
            raise RuntimeError('No official numeric point release found for Debian ' + major)
        version = max(versions, key=lambda v: tuple(map(int, v.split('.'))))
        base = base + version + '/amd64/iso-cd/'
        name = f'debian-{version}-amd64-netinst.iso'
        hashes = set()
        for line in fetch(base + 'SHA256SUMS').splitlines():
            entry = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(\S+)', line.strip())
            if entry and entry[2] == name:
                hashes.add(entry[1].lower())
        if len(hashes) != 1:
            raise RuntimeError('Expected one official SHA256 for ' + name +
                               '; no other image or point release was substituted.')
        for key, value in [('url', base + name), ('sha256', hashes.pop()), ('version', version)]:
            (work / key).write_text(value)
        print('Selected official ISO: ' + name)
    except Exception as exc:
        sys.exit('ERROR: Could not resolve Debian netinst ISO: ' + str(exc))

def resolve_fedora(work, requested, edition):
    import json
    import re
    import subprocess
    import sys
    from pathlib import Path
    from urllib.parse import urlsplit

    version = requested
    edition = edition.title()
    metadata_url = 'https://fedoraproject.org/releases.json'
    try:
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120',
            metadata_url,
        ], check=True, stdout=subprocess.PIPE)
        data = json.loads(response.stdout)
        if not isinstance(data, list):
            raise RuntimeError('Unexpected official release metadata format.')
        number = re.escape(version)
        pattern = (rf'Fedora-Workstation-Live-{number}-[0-9]+(?:\.[0-9]+)*\.x86_64\.iso'
                   if edition == 'Workstation' else
                   rf'Fedora-Server-dvd-x86_64-{number}-[0-9]+(?:\.[0-9]+)*\.iso')
        matches = set()
        for row in data:
            if not isinstance(row, dict):
                continue
            if (row.get('version') != version or row.get('arch') != 'x86_64'
                    or row.get('variant') != edition or row.get('subvariant') != edition):
                continue
            url = row.get('link', '')
            if not isinstance(url, str):
                continue
            parsed = urlsplit(url)
            name = parsed.path.rsplit('/', 1)[-1]
            expected_path = f'/pub/fedora/linux/releases/{version}/{edition}/x86_64/iso/{name}'
            if (parsed.scheme != 'https' or parsed.netloc != 'download.fedoraproject.org'
                    or parsed.path != expected_path or parsed.query or parsed.fragment
                    or not re.fullmatch(pattern, name)):
                continue
            sha = row.get('sha256', '')
            size = str(row.get('size', ''))
            if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', sha):
                raise RuntimeError('Missing or invalid official SHA256 for ' + name)
            if not re.fullmatch(r'[1-9][0-9]*', size):
                raise RuntimeError('Missing or invalid official size for ' + name)
            matches.add((url, sha.lower(), size))
        if len(matches) != 1:
            raise RuntimeError(f'Expected one released {edition} x86_64 ISO for Fedora {version}; '
                               f'found {len(matches)}. No other version or preview was substituted.')
        url, sha, size = matches.pop()
        for key, value in [('url', url), ('sha256', sha), ('size', size)]:
            (work / key).write_text(value)
        print('Selected official ISO: ' + url.rsplit('/', 1)[-1])
    except Exception as exc:
        sys.exit('ERROR: Could not resolve Fedora ISO: ' + str(exc))

def resolve_xcpng(work, requested, edition):
    import re
    import subprocess
    import sys
    from pathlib import Path


    # Known public stable/preview names only. Unknown suffixes never become stable.
    release_pattern = r'(?P<major>\d+)\.(?P<minor>\d+)(?:\.(?P<patch>\d+))?(?:-U(?P<update>\d+))?'
    refresh_pattern = r'(?:-(?P<date>\d{8})(?:\.(?P<revision>\d+))?)?'
    stable_pattern = re.compile(r'xcp-ng-' + release_pattern + refresh_pattern + r'\.iso', re.I)
    preview_pattern = re.compile(r'xcp-ng-' + release_pattern + r'-(?P<preview>(?:alpha|beta|rc|preview|demo|demonstrator)\d*)\.iso', re.I)
    request_pattern = re.compile(release_pattern + refresh_pattern, re.I)
    preview_request_pattern = re.compile(release_pattern + r'-(?P<preview>(?:alpha|beta|rc|preview|demo|demonstrator)\d*)', re.I)

    def fetch(url, optional=False):
        result = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120',
            '--write-out', '\n%{http_code}', url,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        body, _, status = result.stdout.rpartition(b'\n')
        if optional and status == b'404':
            return None
        if result.returncode:
            raise RuntimeError('Could not retrieve ' + url + ': ' + result.stderr.decode(errors='replace').strip())
        if not status.startswith(b'2'):
            raise RuntimeError('Unexpected HTTP status for ' + url + ': ' + status.decode(errors='replace'))
        return body.decode('utf-8-sig')

    def family_of(match):
        return str(int(match['major'])) + '.' + str(int(match['minor']))

    def entries(series, old=False):
        relative = series + ('/old/' if old else '/')
        text = fetch('https://updates.xcp-ng.org/isos/' + relative + 'SHA256SUMS', optional=old)
        if text is None:
            return []
        result = []
        hashes = {}
        for line in text.splitlines():
            match = re.fullmatch(r'([a-fA-F0-9]{64})[ \t]+\*?(\S+)', line.strip())
            if not match:
                continue
            sha, name = match.groups()
            stable = stable_pattern.fullmatch(name)
            preview = preview_pattern.fullmatch(name)
            if not stable and not preview:
                continue
            image = stable or preview
            if family_of(image) != series:
                continue
            if name in hashes and hashes[name] != sha.lower():
                raise RuntimeError('Conflicting official checksums for ' + name)
            hashes[name] = sha.lower()
            result.append(dict(name=name, sha=sha.lower(), stable=bool(stable),
                family=series, patch=int(image['patch'] or 0), update=int(image['update'] or 0),
                date=int(stable['date'] or 0) if stable else 0,
                revision=int(stable['revision'] or 0) if stable else 0, relative=relative))
        return result

    try:
        request = request_pattern.fullmatch(requested)
        preview_request = preview_request_pattern.fullmatch(requested)
        if not request and not preview_request:
            raise RuntimeError('Specify a version with --version, e.g. 8.3, 8.3.1, 8.3-U2, or 8.3.0-rc2. Automatic latest/stable selection is not supported.')
        selector = request or preview_request
        series = family_of(selector)
        def matches(row):
            if preview_request or (request and request['date']):
                return row['name'].casefold() == ('xcp-ng-' + requested + '.iso').casefold()
            if not row['stable']:
                return False
            if request['patch'] is not None and row['patch'] != int(request['patch']):
                return False
            if request['update'] is not None and row['update'] != int(request['update']):
                return False
            # A patch selector without -U pins the patch's non-U images.
            if request['patch'] is not None and request['update'] is None and row['update']:
                return False
            # An update selector without a patch pins the family's .0 update.
            if request['update'] is not None and request['patch'] is None and row['patch']:
                return False
            return True
        candidates = [row for row in entries(series) if matches(row)]
        if not candidates:
            candidates = [row for row in entries(series, old=True) if matches(row)]
        if not candidates:
            raise RuntimeError('No published full installer with an official checksum matches ' + requested + '. No other version was substituted.')
        row = max(candidates, key=lambda x: (x['patch'], x['update'], x['date'], x['revision']))
        label = row['family'] if row['stable'] else row['name'][len('xcp-ng-'):-len('.iso')]
        url = 'https://mirrors.xcp-ng.org/isos/' + row['relative'] + row['name'] + '?https=1'
        print('Selected release family: ' + row['family'])
        (work / 'url').write_text(url)
        (work / 'version').write_text(label)
        (work / 'sha256').write_text(row['sha'])
        print('Selected full installer: ' + row['name'])
        if not row['stable']:
            print('Explicit preview release selected: ' + label)
    except Exception as exc:
        sys.exit('ERROR: Could not resolve XCP-ng installer: ' + str(exc))

def resolve_proxmox(work, requested, edition):
    import re
    import subprocess
    import sys
    from pathlib import Path
    base_url = 'https://enterprise.proxmox.com/iso/'

    def fetch(url):
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
        ], check=True, stdout=subprocess.PIPE)
        return response.stdout.decode('utf-8-sig')

    request_pattern = re.compile(r'(\d+\.\d+(?:\.\d+)?)(?:-(?:(\d+)|((?:ALPHA|BETA|RC))-(\d+)))?', re.I)
    stable_pattern = re.compile(r'proxmox-ve_(\d+\.\d+(?:\.\d+)?)-(\d+)\.iso', re.I)
    preview_pattern = re.compile(r'proxmox-ve_(\d+\.\d+(?:\.\d+)?)-(ALPHA|BETA|RC)-(\d+)\.iso', re.I)
    try:
        request = request_pattern.fullmatch(requested)
        if not request:
            raise RuntimeError('Specify a VE family such as 9.2, an exact ISO such as 9.2-1, or an exact preview such as 9.0-BETA-1. Automatic latest/stable selection is not supported.')
        wanted = tuple(map(int, request[1].split('.')))
        rows = []
        hashes = {}
        for line in fetch(base_url + 'SHA256SUMS').splitlines():
            entry = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(\S+)', line.strip())
            if not entry:
                continue
            sha, name = entry.groups()
            stable = stable_pattern.fullmatch(name)
            preview = preview_pattern.fullmatch(name)
            image = stable or preview
            # Excludes ARM64, Backup Server, Mail Gateway, and Datacenter Manager.
            if not image:
                continue
            numeric = tuple(map(int, image[1].split('.')))
            if numeric[:2] != wanted[:2]:
                continue
            if request[3]:
                if not preview or name.casefold() != ('proxmox-ve_' + requested + '.iso').casefold():
                    continue
            else:
                if not stable:
                    continue
                if len(wanted) == 3 and numeric != wanted:
                    continue
                if request[2] and (numeric != wanted or int(stable[2]) != int(request[2])):
                    continue
            if name in hashes and hashes[name] != sha.lower():
                raise RuntimeError('Conflicting official SHA-256 values for ' + name)
            hashes[name] = sha.lower()
            revision = int(stable[2]) if stable else int(preview[3])
            rows.append((numeric, revision, name, sha.lower(), bool(preview)))
        if not rows:
            raise RuntimeError('No checksummed AMD64 VE installer matches ' + requested + '; no other family, preview, architecture, or product was substituted.')
        numeric, revision, name, sha, preview = max(rows, key=lambda row: (row[0], row[1]))
        family = '.'.join(map(str, numeric[:2]))
        label = name[len('proxmox-ve_'):-len('.iso')] if preview else family
        (work / 'url').write_text(base_url + name)
        (work / 'version').write_text(label)
        (work / 'sha256').write_text(sha)
        print('Selected release family: ' + family)
        print('Selected full installer: ' + name)
        if preview:
            print('Explicit preview release selected: ' + label)
    except Exception as exc:
        sys.exit('ERROR: Could not resolve Proxmox VE installer: ' + str(exc))

def resolve_truenas(work, requested, edition):
    import re
    import subprocess
    import sys
    from html.parser import HTMLParser
    from pathlib import Path
    from urllib.parse import unquote, urljoin, urlsplit
    base_url = 'https://download.sys.truenas.net/'

    def fetch(url):
        response = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
        ], check=True, stdout=subprocess.PIPE)
        return response.stdout.decode('utf-8-sig')

    version_pattern = re.compile(r'(\d{2}\.\d{1,2}(?:\.\d+)*)(?:-(ALPHA|BETA|RC)\.(\d+))?', re.I)
    image_pattern = re.compile(r'TrueNAS-(?:SCALE-)?(\d{2}\.\d{1,2}(?:\.\d+)*(?:-(?:ALPHA|BETA|RC)\.\d+)?)\.iso', re.I)

    def numbers(version):
        return tuple(map(int, version.split('.')))

    class Index(HTMLParser):
        def __init__(self):
            super().__init__()
            self.urls = set()
        def handle_starttag(self, tag, attrs):
            if tag != 'a':
                return
            url = urljoin(base_url, dict(attrs).get('href', ''))
            parsed = urlsplit(url)
            if (parsed.scheme == 'https' and not parsed.username and not parsed.password
                and parsed.netloc in ('download.sys.truenas.net', 'download.truenas.com', 'iso.sys.truenas.net')
                and not parsed.query and not parsed.fragment
                and image_pattern.fullmatch(unquote(parsed.path.rsplit('/', 1)[-1]))):
                self.urls.add(url)

    try:
        request = version_pattern.fullmatch(requested)
        if not request or numbers(request[1])[0] < 22:
            raise RuntimeError('Specify a SCALE/Community Edition family such as 25.10, an exact release such as 25.10.7, or an exact preview such as 27.0.0-RC.1. latest/stable and CORE versions are not supported.')
        wanted = numbers(request[1])
        family_only = len(wanted) == 2 and not request[2]
        index = Index()
        index.feed(fetch(base_url))
        candidates = []
        for url in index.urls:
            name = unquote(urlsplit(url).path.rsplit('/', 1)[-1])
            version = image_pattern.fullmatch(name)[1]
            parsed = version_pattern.fullmatch(version)
            numeric = numbers(parsed[1])
            if numeric[:2] != wanted[:2]:
                continue
            if family_only:
                if parsed[2]:
                    continue
            elif (numeric != wanted or (parsed[2] or '').upper() != (request[2] or '').upper()
                  or parsed[3] != request[3]):
                continue
            candidates.append((numeric, version, url, name, bool(parsed[2])))
        if not candidates:
            raise RuntimeError('No published ISO matches ' + requested + '; no other family or preview was substituted.')
        newest = max(row[0] for row in candidates)
        selected = [row for row in candidates if row[0] == newest]
        if len(selected) != 1:
            raise RuntimeError('Multiple distinct ISO links match the selected release; refusing to guess.')
        _, version, url, name, preview = selected[0]
        checksum = fetch(url + '.sha256').strip()
        if re.fullmatch(r'[0-9a-fA-F]{64}', checksum):
            sha = checksum.lower()
        else:
            hashes = set()
            for line in checksum.splitlines():
                gnu = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(.+)', line.strip())
                bsd = re.fullmatch(r'SHA256\s*\((.+)\)\s*=\s*([0-9a-fA-F]{64})', line.strip(), re.I)
                if gnu and gnu[2] == name:
                    hashes.add(gnu[1].lower())
                if bsd and bsd[1] == name:
                    hashes.add(bsd[2].lower())
            if len(hashes) != 1:
                raise RuntimeError('No unique SHA-256 for the selected ISO in its official checksum sidecar.')
            sha = hashes.pop()
        family = '.'.join(version.split('.')[:2])
        label = version if preview else family
        (work / 'url').write_text(url)
        (work / 'version').write_text(label)
        (work / 'sha256').write_text(sha)
        print('Selected release family: ' + family)
        print('Selected full installer: ' + name)
        if preview:
            print('Explicit preview release selected: ' + version)
    except Exception as exc:
        sys.exit('ERROR: Could not resolve TrueNAS SCALE installer: ' + str(exc))

def resolve_pfsense(work, requested, edition):
    import re
    import subprocess
    import sys
    from html.parser import HTMLParser
    from pathlib import Path
    from urllib.parse import urljoin, urlsplit, unquote


    catalog = 'https://www.fileeagle.com/software/3453/pfSense-Community-Edition'
    checksums = 'https://www.netgate.com/hubfs/pfSense-plus-installer-checksums.txt'

    def fetch(url):
        result = subprocess.run([
            'curl', '--disable', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
        ], check=True, stdout=subprocess.PIPE)
        return result.stdout.decode('utf-8-sig')

    class Links(HTMLParser):
        def __init__(self):
            super().__init__()
            self.links = []
            self.current = None
        def handle_starttag(self, tag, attrs):
            if tag == 'a':
                self.current = [dict(attrs).get('href', ''), '']
        def handle_data(self, data):
            if self.current is not None:
                self.current[1] += data
        def handle_endtag(self, tag):
            if tag == 'a' and self.current is not None:
                self.links.append(self.current)
                self.current = None

    def links(html):
        parser = Links()
        parser.feed(html)
        return parser.links

    try:
        entries = re.findall(
            r'^SHA256\s*\((netgate-installer-v(\d+(?:\.\d+)+)-RELEASE-amd64\.iso\.gz)\)\s*=\s*([0-9a-fA-F]{64})\s*$',
            fetch(checksums), re.M)
        if not entries:
            raise RuntimeError('No stable AMD64 ISO checksum found in Netgate\'s official list.')
        name, version, sha = max(entries, key=lambda item: tuple(map(int, item[1].split('.'))))
        if len({item[2].lower() for item in entries if item[0] == name}) != 1:
            raise RuntimeError('Conflicting official checksums for ' + name)
        pages = {urljoin(catalog, href) for href, text in links(fetch(catalog))
                 if text.strip() == name}
        pages = {url for url in pages if urlsplit(url).scheme == 'https'
                 and urlsplit(url).netloc == 'www.fileeagle.com'
                 and urlsplit(url).path.startswith('/software/download/')}
        if len(pages) != 1:
            raise RuntimeError('FileEagle does not list Netgate\'s current installer ' + name
                               + '; refusing an older release. The mirror may be stale or its page changed.')
        page = pages.pop()
        downloads = set()
        for href, _ in links(fetch(page)):
            url = urljoin(page, href)
            parsed = urlsplit(url)
            if (parsed.scheme == 'https' and not parsed.username and not parsed.password
                and re.fullmatch(r'download\d*\.fileeagle\.com', parsed.netloc)
                and unquote(parsed.path.rsplit('/', 1)[-1]) == name):
                downloads.add(url)
        if len(downloads) != 1:
            raise RuntimeError('Cannot identify a unique direct FileEagle download link for ' + name)
        (work / 'url').write_text(downloads.pop())
        (work / 'version').write_text(version)
        (work / 'sha256').write_text(sha.lower())
        print('Selected: ' + name + ' (Netgate official checksum required)')
    except Exception as exc:
        sys.exit('ERROR: Could not resolve the current pfSense installer: ' + str(exc))

def resolve_hbcdpe(work, requested, edition):
    import re
    import subprocess
    import sys
    from html.parser import HTMLParser
    from pathlib import Path
    from urllib.parse import urljoin, urlsplit
    page_url = 'https://www.hirensbootcd.org/download/'
    class Page(HTMLParser):
        def __init__(self):
            super().__init__()
            self.text = []
            self.rows = []
            self.row = None
            self.cell = None
            self.links = set()
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == 'tr':
                self.row = []
            elif tag in ('td', 'th') and self.row is not None:
                self.cell = []
            if tag == 'a':
                url = urljoin(page_url, attrs.get('href', ''))
                parsed = urlsplit(url)
                if (parsed.scheme == 'https' and parsed.netloc in ('www.hirensbootcd.org', 'hirensbootcd.org')
                    and parsed.path == '/files/HBCD_PE_x64.iso' and not parsed.query and not parsed.fragment):
                    self.links.add(url)
        def handle_data(self, data):
            self.text.append(data)
            if self.cell is not None:
                self.cell.append(data)
        def handle_endtag(self, tag):
            if tag in ('td','th') and self.cell is not None:
                self.row.append(' '.join(''.join(self.cell).split()))
                self.cell = None
            if tag == 'tr' and self.row is not None:
                self.rows.append(self.row)
                self.row = None
    try:
        response = subprocess.run([
            'curl','--disable','--fail','--silent','--show-error','--location',
            '--proto','=https','--proto-redir','=https','--retry','2','--retry-delay','3',
            '--connect-timeout','20','--max-time','120',page_url,
        ], check=True, stdout=subprocess.PIPE)
        page = Page()
        page.feed(response.stdout.decode('utf-8-sig'))
        text = ' '.join(' '.join(page.text).split())
        versions = set(re.findall(r"Hiren[’']s BootCD PE x64\s*\(v(\d+\.\d+\.\d+)\)",text))
        advertised = next(iter(versions)) if len(versions) == 1 else None
        hashes = {row[1].lower() for row in page.rows if len(row)==2 and row[0]=='ISO SHA-256'
                  and re.fullmatch(r'[0-9a-fA-F]{64}',row[1])}
        sizes = set()
        for row in page.rows:
            if len(row)==2 and row[0]=='Filesize':
                match = re.search(r'\(([\d,]+)\s+bytes\)',row[1],re.I)
                if match:
                    sizes.add(int(match[1].replace(',','')))
        if len(page.links)!=1 or len(hashes)!=1 or len(sizes)!=1:
            raise RuntimeError('Cannot identify one project ISO URL, SHA-256, and byte size; refusing to guess.')
        size = sizes.pop()
        if size < 32774:
            raise RuntimeError('Project ISO byte size is too small.')
        (work/'url').write_text(page.links.pop())
        (work/'sha256').write_text(hashes.pop())
        (work/'size').write_text(str(size))
        print('Selected Hiren\'s BootCD PE x64 release: ' + advertised if advertised else 'Selected the current project HBCD PE x64 ISO.')
        print('Expected size: ' + str(size) + ' bytes; project SHA-256 required.')
    except Exception as exc:
        sys.exit('ERROR: Could not resolve HBCD PE ISO: ' + str(exc))


def fetch_metadata(url):
    response = subprocess.run([
        'curl', '--disable', '--fail', '--silent', '--show-error', '--location', '--compressed',
        '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
        '--retry-delay', '3', '--connect-timeout', '20', '--max-time', '120', url,
    ], check=True, stdout=subprocess.PIPE)
    return response.stdout.decode('utf-8-sig')


def download_page(url):
    from html.parser import HTMLParser
    from urllib.parse import urljoin

    class Page(HTMLParser):
        def __init__(self):
            super().__init__()
            self.text = []
            self.links = set()

        def handle_data(self, data):
            self.text.append(data)

        def handle_starttag(self, tag, attrs):
            href = dict(attrs).get('href')
            if tag == 'a' and href:
                self.links.add(urljoin(url, href))

    page = Page()
    page.feed(fetch_metadata(url))
    return page


def resolve_openmediavault(work, requested, edition):
    base = 'https://sourceforge.net/projects/openmediavault/files/iso/'
    page = download_page(base)
    versions = set()
    for url in page.links:
        if url.startswith(base):
            match = re.fullmatch(r'([0-9]+(?:\.[0-9]+)+)/', url[len(base):])
            if match and match[1].split('.')[0] == requested:
                versions.add(match[1])
    if not versions:
        raise RuntimeError('No numeric OpenMediaVault ISO release found for major ' + requested)
    version = max(versions, key=lambda value: tuple(map(int, value.split('.'))))
    name = f'openmediavault_{version}-amd64.iso'
    url = f'https://downloads.sourceforge.net/project/openmediavault/iso/{version}/{name}'
    sha = published_sha256(fetch_metadata(url + '.sha256'), name)
    (work / 'url').write_text(url)
    (work / 'sha256').write_text(sha)
    (work / 'version').write_text('.'.join(version.split('.')[:2]))
    print('Selected OpenMediaVault installer: ' + name)


def resolve_netbootxyz(work, requested, edition):
    base = 'https://boot.netboot.xyz/ipxe/'
    name = 'netboot.xyz.iso'
    sha = published_sha256(fetch_metadata(base + 'netboot.xyz-sha256-checksums.txt'), name)
    (work / 'url').write_text(base + name)
    (work / 'sha256').write_text(sha)
    print('Selected current netboot.xyz BIOS/UEFI network-boot ISO: ' + name)


def resolve_chromeosflex(work, requested, edition):
    import json
    feed = 'https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json'
    records = json.loads(fetch_metadata(feed))
    if not isinstance(records, list):
        raise RuntimeError('Expected a list in the official ChromeOS Flex recovery feed.')
    stable = [row for row in records if isinstance(row, dict) and row.get('channel') == 'STABLE'
              and row.get('manufacturer') == 'Google ChromeOS Flex' and row.get('model') == 'ChromeOS Flex']
    if len(stable) != 1:
        raise RuntimeError('Expected exactly one stable ChromeOS Flex recovery image; refusing to guess.')
    row = stable[0]
    name, version = row.get('file', ''), row.get('version', '')
    if (not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
            or not isinstance(name, str) or not re.fullmatch(
                r'chromeos_' + re.escape(version) + r'_reven_recovery_stable-channel_RevenMPKeys-v[0-9]+\.bin', name)):
        raise RuntimeError('Unexpected stable ChromeOS Flex image name or version.')
    url = 'https://dl.google.com/dl/edgedl/chromeos/recovery/' + name + '.zip'
    if row.get('url') != url or not re.fullmatch(r'[0-9a-fA-F]{40}', str(row.get('sha1', ''))):
        raise RuntimeError('Unexpected ChromeOS Flex download URL or missing published SHA-1.')
    for key in ('filesize', 'zipfilesize'):
        if type(row.get(key)) is not int or row[key] < 32774:
            raise RuntimeError('Invalid ChromeOS Flex byte size in recovery metadata.')
    (work / 'url').write_text(url)
    (work / 'size').write_text(str(row['zipfilesize']))
    (work / 'zip-member').write_text(name)
    (work / 'image-size').write_text(str(row['filesize']))
    # Google's recovery format defines sha1 over the ZIP, not the .bin member.
    (work / 'zip-sha1').write_text(row['sha1'].lower())
    print('Selected stable ChromeOS Flex recovery image: ' + name)


def verify_chromeosflex_image(path):
    """Check the protective MBR, both GPT copies, and ChromeOS partition types."""
    import struct
    import uuid
    import zlib
    size = path.stat().st_size
    if size % 512 or size < 68 * 512:
        raise RuntimeError('ChromeOS Flex disk image has an invalid sector-aligned size.')
    last_lba = size // 512 - 1
    with path.open('rb') as inp:
        mbr = inp.read(512)
        if mbr[510:512] != b'\x55\xaa' or not any(mbr[446 + n * 16 + 4] == 0xee for n in range(4)):
            raise RuntimeError('ChromeOS Flex image has no protective GPT MBR.')

        def read_gpt(lba, alternate):
            inp.seek(lba * 512)
            header = bytearray(inp.read(512))
            if header[:8] != b'EFI PART':
                raise RuntimeError('ChromeOS Flex GPT signature is missing.')
            revision, length, checksum, reserved = struct.unpack_from('<4I', header, 8)
            if revision != 0x10000 or not 92 <= length <= 512 or reserved:
                raise RuntimeError('Unsupported ChromeOS Flex GPT header.')
            struct.pack_into('<I', header, 16, 0)
            if zlib.crc32(header[:length]) != checksum:
                raise RuntimeError('ChromeOS Flex GPT header checksum mismatch.')
            current, backup, first, last = struct.unpack_from('<4Q', header, 24)
            table_lba, count, entry_size, table_crc = struct.unpack_from('<Q3I', header, 72)
            table_bytes = count * entry_size
            table_end = table_lba + (table_bytes + 511) // 512
            if (current != lba or backup != alternate or not 2 <= first <= last < last_lba
                    or not count or entry_size < 128 or entry_size % 128
                    or table_bytes > 4 * 1024 * 1024 or table_lba < 2 or table_end > last_lba
                    or not (table_end <= first or table_lba > last)):
                raise RuntimeError('Invalid ChromeOS Flex GPT bounds.')
            inp.seek(table_lba * 512)
            table = inp.read(table_bytes)
            if len(table) != table_bytes or zlib.crc32(table) != table_crc:
                raise RuntimeError('ChromeOS Flex GPT partition table checksum mismatch.')
            return bytes(header[40:72]), first, last, entry_size, table

        primary = read_gpt(1, last_lba)
        backup = read_gpt(last_lba, 1)
        if primary != backup:
            raise RuntimeError('ChromeOS Flex primary and backup GPT tables disagree.')
        _, first, last, entry_size, table = primary
        types, ranges = set(), []
        for offset in range(0, len(table), entry_size):
            record = table[offset:offset + entry_size]
            if record[:16] == bytes(16):
                continue
            start, end = struct.unpack_from('<2Q', record, 32)
            if not first <= start <= end <= last:
                raise RuntimeError('ChromeOS Flex partition lies outside usable disk space.')
            ranges.append((start, end))
            types.add(str(uuid.UUID(bytes_le=record[:16])))
        ranges.sort()
        if any(a[1] >= b[0] for a, b in zip(ranges, ranges[1:])):
            raise RuntimeError('ChromeOS Flex disk image has overlapping partitions.')
        expected = {'fe3a2a5d-4f32-41a7-b725-accc3285a309',  # ChromeOS kernel
                    '3cb8e202-3b7e-47dd-8a3c-7ff2a13cfcec',  # ChromeOS rootfs
                    'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'}  # EFI system
        if not expected <= types:
            raise RuntimeError('Disk image is missing expected ChromeOS/EFI partition types.')
        os.fsync(inp.fileno())


def resolve_clonezilla(work, requested, edition):
    page = download_page('https://clonezilla.org/downloads/stable/checksums.php')
    # BLAKE3 also uses 64 hex digits. Read only the explicitly labelled SHA256
    # section rather than matching hashes indiscriminately across the page.
    sections = re.findall(r'^###\s+SHA256SUMS:\s*\n(.*?)(?=^###|\Z)',
                          '\n'.join(page.text), re.I | re.M | re.S)
    if len(sections) != 1:
        raise RuntimeError('Expected one official Clonezilla SHA256SUMS section.')
    matches = set()
    for line in sections[0].splitlines():
        row = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?'
                           r'(clonezilla-live-(\d+(?:\.\d+)+-\d+)-amd64\.iso)', line.strip())
        if row:
            matches.add((row[2], row[3], row[1].lower()))
    if len(matches) != 1:
        raise RuntimeError('Expected one checksummed stable Clonezilla Live amd64 ISO; no substitute selected.')
    name, version, sha = matches.pop()
    (work / 'url').write_text('https://downloads.sourceforge.net/clonezilla/' + name)
    (work / 'version').write_text(version)
    (work / 'sha256').write_text(sha)
    print('Selected stable Clonezilla Live ISO: ' + name)


def resolve_gparted(work, requested, edition):
    manifest = fetch_metadata('https://gparted.org/gparted-live/stable/CHECKSUMS.TXT')
    # BLAKE3 also has 64 hex digits: only accept the explicitly labelled SHA256
    # section of the project's CURRENT STABLE manifest, never a testing listing.
    sections = re.findall(r'^###\s+SHA256SUMS:\s*\n(.*?)(?=^###|\Z)',
                          manifest, re.I | re.M | re.S)
    if len(sections) != 1:
        raise RuntimeError('Expected one official GParted stable SHA256SUMS section.')
    matches = set()
    for line in sections[0].splitlines():
        row = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?'
                           r'(gparted-live-([0-9]+(?:\.[0-9]+)+-[0-9]+)-amd64\.iso)', line.strip())
        if row:
            matches.add((row[2], row[3], row[1].lower()))
    if len(matches) != 1:
        raise RuntimeError('Expected one checksummed current stable GParted Live amd64 ISO; no substitute selected.')
    name, version, sha = matches.pop()
    url = f'https://downloads.sourceforge.net/project/gparted/gparted-live-stable/{version}/{name}'
    (work / 'url').write_text(url)
    (work / 'version').write_text(version)
    (work / 'sha256').write_text(sha)
    print('Selected stable GParted Live ISO: ' + name)


def resolve_memtest86plus(work, requested, edition):
    page = download_page('https://www.memtest.org/')
    images = set()
    for url in page.links:
        parsed = urlsplit(url)
        match = re.fullmatch(r'/download/v(\d+(?:\.\d+)+)/mt86plus_\1_x86_64\.iso\.zip', parsed.path)
        if (match and parsed.scheme == 'https' and parsed.netloc == 'www.memtest.org'
                and not parsed.query and not parsed.fragment):
            images.add((url, match[1]))
    if len(images) != 1:
        raise RuntimeError('Expected one current stable Memtest86+ x86_64 ISO archive; no nightly or alternate image selected.')
    url, version = images.pop()
    base = 'https://www.memtest.org/download/v' + version + '/'
    if base + 'sha256sum.txt' not in page.links:
        raise RuntimeError('Current Memtest86+ download has no matching official SHA256 manifest link.')
    name = url.rsplit('/', 1)[-1]
    hashes = set()
    for line in fetch_metadata(base + 'sha256sum.txt').splitlines():
        row = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(\S+)', line.strip())
        if row and row[2] in (name, 'v' + version + '/' + name):
            hashes.add(row[1].lower())
    if len(hashes) != 1:
        raise RuntimeError('Missing or conflicting official SHA256 for ' + name)
    (work / 'url').write_text(url)
    (work / 'version').write_text(version)
    (work / 'sha256').write_text(hashes.pop())
    (work / 'zip-member').write_text('memtest.iso')
    print('Selected stable Memtest86+ archive: ' + name)


def published_sha256(text, name):
    hashes = set()
    for line in text.splitlines():
        row = re.fullmatch(r'([0-9a-fA-F]{64})[ \t]+\*?(\S+)', line.strip())
        if row and row[2] == name:
            hashes.add(row[1].lower())
        bsd = re.fullmatch(r'SHA256 \(([^)]+)\) = ([0-9a-fA-F]{64})', line.strip())
        if bsd and bsd[1] == name:
            hashes.add(bsd[2].lower())
    if len(hashes) != 1:
        raise RuntimeError('Missing or conflicting official SHA256 for ' + name)
    return hashes.pop()


def resolve_linuxmint(work, requested, edition):
    base = 'https://pub.linuxmint.io/stable/'
    page = download_page(base)
    versions = set()
    for url in page.links:
        if url.startswith(base):
            match = re.fullmatch(r'([1-9][0-9]*(?:\.[0-9]+)*)/', url[len(base):])
            if match:
                versions.add(match[1])
    if not versions:
        raise RuntimeError('No numeric stable Linux Mint release directories found.')
    version = max(versions, key=lambda v: tuple(map(int, v.split('.'))))
    name = f'linuxmint-{version}-{edition}-64bit.iso'
    base += version + '/'
    sha = published_sha256(fetch_metadata(base + 'sha256sum.txt'), name)
    (work / 'url').write_text(base + name)
    (work / 'sha256').write_text(sha)
    (work / 'version').write_text(version)
    print('Selected stable Linux Mint ISO: ' + name)


def resolve_popos(work, requested, edition):
    import json
    # Use the same advertised release/channel/architecture tuple as System76's
    # download page, then obtain its exact build URL and checksum from their API.
    page = fetch_metadata('https://system76.com/pop/download/')
    releases = set(re.findall(
        r"fetchRelease\(\s*['\"]([0-9]{2}\.[0-9]{2})['\"]\s*,\s*['\"]"
        + re.escape(edition) + r"['\"]\s*,\s*['\"]amd64['\"]\s*\)", page))
    if len(releases) != 1:
        raise RuntimeError('Expected one current Pop!_OS amd64 release for ' + edition)
    version = releases.pop()
    api = f'https://api.pop-os.org/builds/{version}/{edition}?arch=amd64'
    data = json.loads(fetch_metadata(api))
    if not isinstance(data, dict) or data.get('version') != version or data.get('channel') != edition:
        raise RuntimeError('Pop!_OS build API returned a different release or edition.')
    sha = data.get('sha_sum', '')
    size = str(data.get('size', ''))
    build = str(data.get('build', ''))
    if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', sha):
        raise RuntimeError('Pop!_OS API returned no valid SHA256.')
    if not re.fullmatch(r'[1-9][0-9]*', size) or int(size) < 32774 or not re.fullmatch(r'[0-9]+', build):
        raise RuntimeError('Pop!_OS API returned an invalid size or build number.')
    name = f'pop-os_{version}_amd64_{edition}_{build}.iso'
    url = data.get('url', '')
    expected = f'https://iso.pop-os.org/{version}/amd64/{edition}/{build}/{name}'
    if url != expected:
        raise RuntimeError('Pop!_OS API returned an unexpected ISO host, path, or filename.')
    for key, value in [('url', url), ('sha256', sha.lower()), ('size', size), ('version', version)]:
        (work / key).write_text(value)
    print('Selected current Pop!_OS ISO: ' + name)


def resolve_arch(work, requested, edition):
    import datetime
    base = 'https://geo.mirror.pkgbuild.com/iso/'
    manifest = fetch_metadata(base + 'latest/sha256sums.txt')
    names = set()
    for line in manifest.splitlines():
        row = re.fullmatch(r'[0-9a-fA-F]{64}[ \t]+\*?'
                           r'(archlinux-([0-9]{4}\.[0-9]{2}\.[0-9]{2})-x86_64\.iso)', line.strip())
        if row:
            names.add((row[1], row[2]))
    if len(names) != 1:
        raise RuntimeError('Expected one dated current Arch Linux x86_64 ISO in the official manifest.')
    name, snapshot = names.pop()
    datetime.date.fromisoformat(snapshot.replace('.', '-'))
    sha = published_sha256(manifest, name)
    (work / 'url').write_text(base + snapshot + '/' + name)
    (work / 'sha256').write_text(sha)
    (work / 'version').write_text(snapshot)
    print('Selected Arch Linux snapshot: ' + name)


def resolve_opnsense(work, requested, edition):
    base = 'https://pkg.opnsense.org/releases/'
    page = download_page(base)
    versions = set()
    for url in page.links:
        if url.startswith(base):
            match = re.fullmatch(r'([0-9]{2}\.[0-9]+(?:\.[0-9]+)*)/', url[len(base):])
            if match and match[1].split('.')[:2] == requested.split('.'):
                versions.add(match[1])
    if not versions:
        raise RuntimeError('No published stable OPNsense installer found for family ' + requested)
    version = max(versions, key=lambda v: tuple(map(int, v.split('.'))))
    base += version + '/'
    name = f'OPNsense-{version}-dvd-amd64.iso.bz2'
    sha = published_sha256(fetch_metadata(base + f'OPNsense-{version}-checksums-amd64.sha256'), name)
    (work / 'url').write_text(base + name)
    (work / 'version').write_text(requested)
    (work / 'sha256').write_text(sha)
    print('Selected stable OPNsense Community installer: ' + name)


def qubes_gpg(work, *arguments, input_bytes=None):
    command = [
        'gpg', '--no-options', '--batch', '--no-tty', '--no-autostart',
        '--no-auto-key-retrieve', '--auto-key-locate', 'clear',
        '--homedir', str(work / 'qubes-keyring'), *arguments,
    ]
    response = subprocess.run(command, input=input_bytes, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=3600)
    if response.returncode:
        raise RuntimeError('Qubes PGP verification failed: ' + response.stderr.decode(errors='replace').strip())
    return response.stdout.decode('utf-8')


def qubes_primary_fingerprint(work, path):
    listing = qubes_gpg(work, '--with-colons', '--import-options', 'show-only', '--import', str(path))
    fingerprints = []
    primary = False
    for line in listing.splitlines():
        fields = line.split(':')
        if fields[0] == 'pub':
            primary = True
        elif fields[0] == 'sub':
            primary = False
        elif fields[0] == 'fpr' and primary:
            fingerprints.append(fields[9])
            primary = False
    if len(fingerprints) != 1 or not re.fullmatch(r'[0-9A-F]{40}', fingerprints[0]):
        raise RuntimeError('Expected exactly one primary public key in ' + path.name)
    return fingerprints[0]


def prepare_qubes_keyring(work, family):
    # Root of trust published by the Qubes project; do not derive the trusted
    # fingerprint from the key server response being authenticated.
    master = '427F11FD0FAA4B080123F01CDDFA1A3E36879494'
    keybase = 'https://keys.qubes-os.org/keys/'
    home = work / 'qubes-keyring'
    home.mkdir(mode=0o700)
    master_file, release_file = work / 'qubes-master.asc', work / 'qubes-release.asc'
    master_file.write_text(fetch_metadata(keybase + 'qubes-master-signing-key.asc'))
    release_file.write_text(fetch_metadata(keybase + f'qubes-release-{family}-signing-key.asc'))
    if qubes_primary_fingerprint(work, master_file) != master:
        raise RuntimeError('Downloaded Qubes master key does not match the pinned fingerprint.')
    release = qubes_primary_fingerprint(work, release_file)
    if release == master:
        raise RuntimeError('Expected a separate Qubes release signing key.')
    qubes_gpg(work, '--import', str(master_file), str(release_file))
    # Trust only the pinned master, only in this run's private temporary keyring.
    # GPG checks its certifications, expiration and revocation when establishing
    # full validity for the release key and its expected release identity.
    qubes_gpg(work, '--import-ownertrust', input_bytes=(master + ':6:\n').encode())
    qubes_gpg(work, '--check-trustdb')
    master_rows = [line.split(':') for line in qubes_gpg(work, '--with-colons', '--list-keys', master).splitlines()]
    if not any(row[0] == 'pub' and row[1] == 'u' for row in master_rows):
        raise RuntimeError('Qubes master key is expired, revoked, or invalid.')
    rows = [line.split(':') for line in qubes_gpg(work, '--with-colons', '--list-keys', release).splitlines()]
    expected_uid = f'Qubes OS Release {family} Signing Key'
    if (not any(row[0] == 'pub' and row[1] == 'f' for row in rows)
            or not any(row[0] == 'uid' and row[1] == 'f' and row[9] == expected_uid for row in rows)):
        raise RuntimeError('Qubes release key is not validly certified by the pinned master for family ' + family)
    (work / 'qubes-signer').write_text(release)
    print('Authenticated Qubes release key through the pinned master: ' + release)


def verify_qubes_signature(work, signature, payload):
    status = qubes_gpg(work, '--status-fd', '1', '--verify', str(signature), str(payload))
    rows = [line.split() for line in status.splitlines() if line.startswith('[GNUPG:] ')]
    bad = {'BADSIG', 'ERRSIG', 'NO_PUBKEY', 'EXPSIG', 'EXPKEYSIG', 'REVKEYSIG'}
    if any(row[1] in bad for row in rows):
        raise RuntimeError('Invalid or expired Qubes PGP signature.')
    valid = [row for row in rows if row[1] == 'VALIDSIG']
    expected = (work / 'qubes-signer').read_text()
    if (len(valid) != 1 or len(valid[0]) < 12 or valid[0][11] != expected
            or valid[0][9] not in {'8', '9', '10', '11'}):
        raise RuntimeError('Qubes signature does not use the authenticated release key and a SHA2 digest.')
    print('Verified Qubes PGP signature with authenticated release key.')


def resolve_qubes(work, requested, edition):
    base = 'https://ftp.qubes-os.org/iso/'
    page = download_page(base)
    images = set()
    for url in page.links:
        if url.startswith(base):
            match = re.fullmatch(r'Qubes-R([0-9]+\.[0-9]+(?:\.[0-9]+)?)-x86_64\.iso', url[len(base):])
            if match and match[1].split('.')[:2] == requested.split('.'):
                images.add((tuple(map(int, match[1].split('.'))), url[len(base):]))
    if not images:
        raise RuntimeError('No stable Qubes x86_64 ISO found for family ' + requested)
    _, name = max(images)
    url = base + name
    sha = published_sha256(fetch_metadata(url + '.DIGESTS'), name)
    (work / 'qubes-iso.asc').write_text(fetch_metadata(url + '.asc'))
    prepare_qubes_keyring(work, requested)
    (work / 'url').write_text(url)
    (work / 'version').write_text(requested)
    (work / 'sha256').write_text(sha)
    print('Selected stable Qubes ISO: ' + name)


def digest_file(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def win11_edition_label(edition):
    return {
        'Core': 'Home', 'CoreN': 'HomeN', 'CoreSingleLanguage': 'HomeSingleLanguage',
        'CoreCountrySpecific': 'HomeChina', 'Professional': 'Pro', 'ProfessionalN': 'ProN',
        'ProfessionalSingleLanguage': 'ProSingleLanguage',
        'ProfessionalEducation': 'ProEducation', 'ProfessionalEducationN': 'ProEducationN',
        'ProfessionalWorkstation': 'ProWorkstations', 'ProfessionalWorkstationN': 'ProWorkstationsN',
    }.get(edition, edition)


def windows_boot_layout(path):
    """Read and validate the BIOS/UEFI El Torito entries without mounting an ISO."""
    import struct
    catalog_lba = None
    label = None
    with path.open('rb') as inp:
        for sector in range(16, 256):
            inp.seek(sector * 2048)
            descriptor = inp.read(2048)
            if len(descriptor) != 2048 or descriptor[1:6] != b'CD001':
                break
            if descriptor[0] == 1:
                label = descriptor[40:72].decode('ascii').strip()
            if descriptor[0] == 0 and descriptor[7:39].rstrip(b'\0 ') == b'EL TORITO SPECIFICATION':
                catalog_lba = struct.unpack_from('<I', descriptor, 71)[0]
            if descriptor[0] == 255:
                break
        if not catalog_lba or not label:
            raise RuntimeError('Windows ISO has no recognizable volume label or El Torito boot catalog.')
        inp.seek(catalog_lba * 2048)
        catalog = inp.read(8192)
    if (len(catalog) < 64 or catalog[0] != 1 or catalog[30:32] != b'\x55\xaa'
            or sum(struct.unpack('<16H', catalog[:32])) & 0xffff):
        raise RuntimeError('Invalid Windows ISO boot catalog.')
    entries = {}

    def entry(platform, record):
        if record[0] != 0x88:
            return
        if platform in entries or record[1] != 0:
            raise RuntimeError('Unsupported duplicate or emulated Windows boot entry.')
        segment, count, lba = struct.unpack_from('<H2xHI', record, 2)
        entries[platform] = (segment, count, lba)

    entry(catalog[1], catalog[32:64])
    offset = 64
    while offset + 32 <= len(catalog) and catalog[offset] in (0x90, 0x91):
        last, platform = catalog[offset], catalog[offset + 1]
        count = struct.unpack_from('<H', catalog, offset + 2)[0]
        offset += 32
        if not count or offset + count * 32 > len(catalog):
            raise RuntimeError('Unsupported Windows boot catalog section length.')
        for index in range(count):
            entry(platform, catalog[offset + index * 32:offset + (index + 1) * 32])
        offset += count * 32
        if last == 0x91:
            break
    if set(entries) != {0, 0xef}:
        raise RuntimeError('Windows customization requires both BIOS and UEFI boot entries.')
    return label, entries


def windows_boot_hash(path, lba, size):
    sha = hashlib.sha256()
    with path.open('rb') as inp:
        inp.seek(lba * 2048)
        while size:
            chunk = inp.read(min(size, 8 * 1024 * 1024))
            if not chunk:
                raise RuntimeError('Truncated Windows ISO boot image.')
            sha.update(chunk)
            size -= len(chunk)
    return sha.hexdigest()


def customize_win11(work, source, edition):
    import xml.etree.ElementTree as ET

    def run(arguments):
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=21600, env=dict(os.environ, GENISOIMAGERC='/dev/null', MKISOFSRC='/dev/null'))
        if result.returncode:
            raise RuntimeError('Windows ISO tool failed (' + arguments[0] + '): '
                               + result.stderr.decode(errors='replace')[-4000:])
        return result.stdout

    def extract(iso, destination):
        destination.mkdir()
        run([shutil.which('7z') or shutil.which('7zz'), 'x', '-tUdf', '-y', '-bd', '-bso0', '-bsp0', '-o' + str(destination), str(iso)])

    def inventory(directory):
        result = {}
        for file in directory.rglob('*'):
            if file.is_symlink():
                raise RuntimeError('Unexpected symbolic link in Windows installation media.')
            if file.is_file():
                relative = file.relative_to(directory).as_posix()
                result[relative] = (file.stat().st_size, digest_file(file))
        return result

    label, boot = windows_boot_layout(source)
    media = work / 'windows-media'
    print('Extracting verified Windows UDF media...')
    extract(source, media)
    lookup = {}
    for path in media.rglob('*'):
        if path.is_file():
            relative = path.relative_to(media).as_posix()
            if relative.casefold() in lookup:
                raise RuntimeError('Windows ISO contains ambiguous case-insensitive paths.')
            lookup[relative.casefold()] = relative
    images = [lookup[p] for p in ('sources/install.wim', 'sources/install.esd') if p in lookup]
    if len(images) != 1:
        raise RuntimeError('Expected exactly one sources/install.wim or install.esd in the Microsoft ISO.')
    for name in ('autounattend.xml', 'unattend.xml', 'sources/autounattend.xml', 'sources/unattend.xml', 'sources/pid.txt'):
        if name in lookup:
            raise RuntimeError('Source answer/product-key file can conflict with ei.cfg: ' + name)
    # Force image-number display so 7-Zip exposes the XML auxiliary entry even
    # for single-image WIM/ESD files. Extract only this exact entry to stdout;
    # installation image contents are never unpacked or modified.
    xml = run([shutil.which('7z') or shutil.which('7zz'), 'x', '-tWIM', '-mis=on',
               '-so', '-spd', '-y', '-bd', '-bso0', '-bsp0', str(media / images[0]), '[1].xml'])
    try:
        metadata = ET.fromstring(xml)
    except ET.ParseError as exc:
        raise RuntimeError('7-Zip did not return valid Windows WIM/ESD edition metadata XML.') from exc
    editions = {node.text.strip() for node in metadata.findall('./IMAGE/WINDOWS/EDITIONID')
                if node.text and node.text.strip()}
    available = {value.casefold(): value for value in editions}
    if not editions:
        raise RuntimeError('Installation image has no readable Windows edition IDs; refusing customization.')
    if edition.casefold() not in available:
        raise RuntimeError('Requested Windows edition ' + edition + ' is absent. Available: '
                           + ', '.join(sorted(editions)) + '. Existing ISOs preserved.')
    actual = available[edition.casefold()]
    print('Confirmed Windows edition in installation image: ' + actual)
    sources = (media / images[0]).parent
    cfg = media / lookup['sources/ei.cfg'] if 'sources/ei.cfg' in lookup else sources / 'ei.cfg'
    cfg.write_bytes(('[EditionID]\r\n' + actual + '\r\n[Channel]\r\nRetail\r\n[VL]\r\n0\r\n').encode('ascii'))

    chosen = {}
    for platform, candidates in [(0, ['boot/etfsboot.com']),
                                  (0xef, ['efi/microsoft/boot/efisys.bin', 'efi/microsoft/boot/efisys_noprompt.bin'])]:
        for candidate in candidates:
            if candidate not in lookup:
                continue
            relative = lookup[candidate]
            file = media / relative
            size, sha = file.stat().st_size, digest_file(file)
            if sha == windows_boot_hash(source, boot[platform][2], size):
                chosen[platform] = (relative, size, sha)
                break
        if platform not in chosen:
            raise RuntimeError('Cannot preserve the source Windows BIOS/UEFI boot image.')
    catalog = '.edition-boot.catalog'
    if catalog.casefold() in lookup:
        raise RuntimeError('Source conflicts with the customization boot catalog path.')
    print('Recording payload hashes; installation images remain unchanged...')
    expected = inventory(media)
    output = work / 'windows-custom.iso'
    command = ['genisoimage', '-quiet', '-iso-level', '3', '-udf', '-allow-limited-size',
               '-J', '-joliet-long', '-V', label, '-c', catalog]
    for platform in (0, 0xef):
        segment, count, _ = boot[platform]
        if not count:
            raise RuntimeError('Unsupported Windows boot entry load size.')
        if platform == 0xef:
            command += ['-eltorito-alt-boot']
        command += ['-b' if platform == 0 else '-e', chosen[platform][0], '-no-emul-boot',
                    '-boot-load-size', str(count), '-boot-load-seg', str(segment)]
    command += ['-o', str(output), str(media)]
    print('Rebuilding Windows ISO with ' + actual + ' ei.cfg (BIOS + UEFI, UDF)...')
    run(command)
    rebuilt_label, rebuilt_boot = windows_boot_layout(output)
    if rebuilt_label != label:
        raise RuntimeError('Rebuilt Windows ISO volume label changed unexpectedly.')
    for platform, (_, size, sha) in chosen.items():
        if (rebuilt_boot[platform][:2] != boot[platform][:2]
                or windows_boot_hash(output, rebuilt_boot[platform][2], size) != sha):
            raise RuntimeError('Rebuilt Windows ISO did not preserve BIOS/UEFI boot data.')
    # Re-use the extracted tree's space to check every rebuilt UDF file, including
    # large WIM/ESD files. The peak staging footprint is about three ISO sizes.
    shutil.rmtree(media)
    print('Verifying rebuilt UDF payloads and ei.cfg...')
    extract(output, media)
    observed = inventory(media)
    observed.pop(catalog, None)  # New El Torito catalog is ISO boot metadata.
    if observed != expected:
        raise RuntimeError('Rebuilt Windows payload verification failed; existing ISOs preserved.')
    with output.open('rb') as inp:
        os.fsync(inp.fileno())
    print('Verified all rebuilt payloads, edition selector, and BIOS/UEFI boot images.')
    print('Customized ISO SHA-256 (not Microsoft\'s original ISO checksum): ' + digest_file(output))
    return output


def managed_history(product, version, edition, name):
    """Only recognize names owned by this product and selected retention group."""
    if product == 'chromeosflex':
        return bool(re.fullmatch(r'ChromeOSFlex_\d{6}\.img', name))
    if product == 'openmediavault':
        major = re.escape(version.split('.')[0])
        return bool(re.fullmatch(r'OpenMediaVault_' + major + r'(?:\.[0-9]+)?_\d{6}\.iso', name))
    if product == 'netbootxyz':
        return bool(re.fullmatch(r'netboot\.xyz_\d{6}\.iso', name))
    if product == 'win11':
        prefix = 'Win11' if edition == 'multi' else 'Win11_' + win11_edition_label(edition)
        return bool(re.fullmatch(re.escape(prefix) + r'_\d{2}H[12]_\d{6}\.iso', name))
    if product == 'pfsense':
        return bool(re.fullmatch(r'(?:pfsense|Netgate_Installer_\d+(?:\.\d+)+)_\d{6}\.iso', name))
    if product == 'hbcdpe':
        return bool(re.fullmatch(r'(?:hbcdpe|HBCD_PE_\d+\.\d+\.\d+)_\d{6}\.iso', name))
    if product in ('clonezilla', 'memtest86plus', 'gparted'):
        return bool(re.fullmatch(re.escape(product) + r'_\d{6}\.iso', name))
    if product == 'opnsense':
        return bool(re.fullmatch(r'OPNsense_' + re.escape(version) + r'_\d{6}\.iso', name))
    if product == 'qubes':
        return bool(re.fullmatch(r'Qubes_' + re.escape(version) + r'_\d{6}\.iso', name))
    if product == 'arch':
        return bool(re.fullmatch(r'Arch_\d{6}\.iso', name))
    if product == 'debian':
        major = re.escape(version.split('.')[0])
        return bool(re.fullmatch(rf'Debian_(?:Netinst_)?{major}(?:\.[0-9]+)+_\d{{6}}\.iso', name))
    if product in ('winserver', 'ubuntu', 'fedora', 'linuxmint', 'popos'):
        prefix = {'winserver': 'WinServerEval', 'ubuntu': 'Ubuntu_' + edition.title(),
                  'fedora': 'Fedora_' + edition.title(), 'linuxmint': 'LinuxMint_' + edition.title(),
                  'popos': 'PopOS_' + edition.title()}[product]
        return bool(re.fullmatch(re.escape(prefix + '_' + version) + r'_\d{6}\.iso', name))
    prefix = {'xcpng': 'XCP-ng', 'proxmox': 'Proxmox_VE', 'truenas': 'TrueNAS_SCALE'}[product]
    pattern = re.escape(prefix) + r'_(\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9.-]+)?)_\d{6}\.iso'
    match = re.fullmatch(pattern, name, re.I)
    if not match:
        return False
    previous = match[1]
    if product == 'xcpng':
        stable = r'\d+\.\d+(?:\.\d+)?(?:-U\d+)?(?:-\d{8}(?:\.\d+)?)?'
    else:
        stable = r'\d+\.\d+(?:\.\d+)*(?:-\d+)?'
    if not re.fullmatch(stable, version, re.I):
        return previous.casefold() == version.casefold()
    return (bool(re.fullmatch(stable, previous, re.I))
            and tuple(map(int, previous.split('-')[0].split('.')[:2]))
            == tuple(map(int, version.split('-')[0].split('.')[:2])))


def run_download(work, folder, product, requested, edition, stamp, keep, silent):
    print(f'Resolving {product} {edition.title()} {requested}...'.replace('  ', ' '))
    resolvers = {
        'win11': resolve_win11, 'winserver': resolve_winserver,
        'ubuntu': resolve_ubuntu, 'debian': resolve_debian, 'fedora': resolve_fedora,
        'xcpng': resolve_xcpng, 'proxmox': resolve_proxmox, 'truenas': resolve_truenas,
        'pfsense': resolve_pfsense, 'hbcdpe': resolve_hbcdpe,
        'clonezilla': resolve_clonezilla, 'memtest86plus': resolve_memtest86plus,
        'gparted': resolve_gparted, 'chromeosflex': resolve_chromeosflex,
        'openmediavault': resolve_openmediavault, 'netbootxyz': resolve_netbootxyz,
        'linuxmint': resolve_linuxmint, 'popos': resolve_popos, 'arch': resolve_arch,
        'opnsense': resolve_opnsense,
        'qubes': resolve_qubes,
    }
    resolvers[product](work, requested, edition)
    url = (work / 'url').read_text().strip()
    if urlsplit(url).scheme != 'https':
        raise RuntimeError('Resolved download URL must use HTTPS.')
    version = ((work / 'version').read_text().strip()
               if (work / 'version').exists() else requested)
    if version and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', version):
        raise RuntimeError('Unsafe resolved version label.')
    archive = product == 'pfsense'
    bzip2_archive = product == 'opnsense'
    zip_archive = product in ('memtest86plus', 'chromeosflex')
    source = work / ('download.iso.gz' if archive else 'download.iso.bz2' if bzip2_archive
                     else 'download.iso.zip' if zip_archive else 'download.iso')
    command = [
        'curl', '--disable', '--fail', '--show-error', '--location',
        '--proto', '=https', '--proto-redir', '=https', '--retry', '3',
        '--retry-delay', '10', '--connect-timeout', '30',
        '--max-time', '64800' if product in ('win11', 'winserver') else '21600',
        '--speed-limit', '1024', '--speed-time', '300',
    ]
    if silent:
        command.append('--silent')
    if product == 'winserver':
        etag = (work / 'etag').read_text()
        if etag:
            command += ['--header', 'If-Match: ' + etag]
        command += ['--write-out', '%{url_effective}']
    command += ['--output', str(source), url]
    print('Downloading a fresh copy (every run)...')
    response = subprocess.run(command, check=True, stdout=subprocess.PIPE if product == 'winserver' else None)
    print('Verifying download...')
    if product == 'winserver':
        final = urlsplit(response.stdout.decode().strip())
        if (final.scheme != 'https' or not (final.hostname or '').endswith('.microsoft.com')
                or final.username or final.password):
            raise RuntimeError('Transfer ended at an unexpected Microsoft download host.')
    if (work / 'size').exists() and source.stat().st_size != int((work / 'size').read_text()):
        raise RuntimeError('ISO size does not match expected metadata; existing ISOs preserved.')
    sha = digest_file(source)
    if product in ('winserver', 'chromeosflex'):
        print('SHA-256 (calculated; no official checksum comparison): ' + sha)
    elif sha != (work / 'sha256').read_text().strip().lower():
        raise RuntimeError('Download SHA-256 does not match the published checksum; existing ISOs preserved.')
    else:
        print('Verified SHA-256: ' + sha)
    if product == 'chromeosflex':
        zip_sha1 = hashlib.sha1()
        with source.open('rb') as inp:
            for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
                zip_sha1.update(chunk)
        if zip_sha1.hexdigest() != (work / 'zip-sha1').read_text():
            raise RuntimeError('ChromeOS Flex ZIP SHA-1 does not match Google\'s recovery metadata.')
        print('Verified published ZIP SHA-1: ' + zip_sha1.hexdigest())
    if product == 'qubes':
        verify_qubes_signature(work, work / 'qubes-iso.asc', source)
    if archive or bzip2_archive:
        import bz2
        print('Decompressing verified archive...')
        extracted = work / 'installer.iso'
        opener = bz2.open if bzip2_archive else gzip.open
        with opener(source, 'rb') as inp, extracted.open('wb') as out:
            shutil.copyfileobj(inp, out, length=8 * 1024 * 1024)
            out.flush()
            os.fsync(out.fileno())
        source = extracted
    if zip_archive:
        import zipfile
        print('Extracting recovery disk image...' if product == 'chromeosflex' else 'Extracting verified ISO archive...')
        extracted = work / ('installer.img' if product == 'chromeosflex' else 'installer.iso')
        expected = (work / 'zip-member').read_text()
        with zipfile.ZipFile(source) as bundle:
            members = [member for member in bundle.infolist() if not member.is_dir()]
            if len(members) != 1 or members[0].filename != expected:
                raise RuntimeError('Expected one exactly named installer image in the archive.')
            if product == 'chromeosflex' and members[0].file_size != int((work / 'image-size').read_text()):
                raise RuntimeError('ChromeOS Flex ZIP member size does not match recovery metadata.')
            # Copy the expected member to a fixed path, never extract ZIP paths.
            # Reading through EOF also validates ZIP CRC integrity.
            with bundle.open(members[0]) as inp, extracted.open('wb') as out:
                shutil.copyfileobj(inp, out, length=8 * 1024 * 1024)
                out.flush()
                os.fsync(out.fileno())
        source = extracted
    if product == 'chromeosflex':
        if source.stat().st_size != int((work / 'image-size').read_text()):
            raise RuntimeError('Extracted ChromeOS Flex image size does not match recovery metadata.')
        verify_chromeosflex_image(source)
        print('Image SHA-256 (calculated): ' + digest_file(source))
    else:
        with source.open('rb') as inp:
            inp.seek(32769)
            if inp.read(5) != b'CD001':
                raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
            os.fsync(inp.fileno())
    if product == 'win11' and edition != 'multi':
        source = customize_win11(work, source, edition)
    prefixes = {'win11': 'Win11', 'winserver': 'WinServerEval',
                'ubuntu': 'Ubuntu_' + edition.title(), 'debian': 'Debian',
                'fedora': 'Fedora_' + edition.title(), 'xcpng': 'XCP-ng',
                'proxmox': 'Proxmox_VE', 'truenas': 'TrueNAS_SCALE',
                'linuxmint': 'LinuxMint_' + edition.title(), 'popos': 'PopOS_' + edition.title(),
                'opnsense': 'OPNsense', 'qubes': 'Qubes', 'openmediavault': 'OpenMediaVault'}
    if product == 'win11' and edition != 'multi':
        prefixes['win11'] += '_' + win11_edition_label(edition)
    date_prefix = {'arch': 'Arch', 'netbootxyz': 'netboot.xyz'}.get(product, product)
    name = (f'{date_prefix}_{stamp}.iso' if product in ('pfsense', 'hbcdpe', 'clonezilla', 'memtest86plus', 'arch', 'gparted', 'netbootxyz')
            else f'ChromeOSFlex_{stamp}.img' if product == 'chromeosflex'
            else f'{prefixes[product]}_{version}_{stamp}.iso')
    target = folder / name
    if keep and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        return
    os.replace(source, target)
    if not keep:
        for old in folder.iterdir():
            if (old != target and managed_history(product, version, edition, old.name)
                    and (old.is_file() or old.is_symlink())):
                old.unlink()
    print(('Verified disk image structure. Saved: ' if product == 'chromeosflex' else 'Verified ISO structure. Saved: ') + str(target))


try:
    work, folder, product, requested, edition, stamp, keep, silent = sys.argv[1:]
    import fcntl
    try:
        # FD 9 is inherited from Bash. The shared open file description keeps
        # the lock held through Bash's staging cleanup after Python exits.
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Another ' + product + ' download is running in: ' + folder)
    run_download(Path(work), Path(folder), product, requested, edition, stamp, keep == '1', silent == '1')
except Exception as exc:
    sys.exit('ERROR: Could not download, verify, or publish image: ' + str(exc))
PY_ENGINE

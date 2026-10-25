#!/bin/bash
# Download a ready-made Proxmox Virtual Environment (VE) AMD64 installer ISO.
DEFAULT_VERSION="9.2"  # Edit this release family periodically; --version overrides it.
DOWNLOAD_BASE_URL="https://enterprise.proxmox.com/iso/"
#
# Usage:
#   ./download-proxmox.sh [EXISTING_FOLDER] [--version VERSION] [--keep-existing] [--silent]
#
# Examples:
#   ./download-proxmox.sh                         # Default family, current folder
#   ./download-proxmox.sh /mnt/isos --version 9.2
#   ./download-proxmox.sh --version 9.2-1          # Exact release/build
#   ./download-proxmox.sh --version 9.0-BETA-1      # Explicit preview, if published
#   ./download-proxmox.sh . --keep-existing
#   ./download-proxmox.sh . > proxmox-download.log 2>&1
#   ./download-proxmox.sh . --silent > proxmox-errors.log 2>&1
#
# The family is manually configured: no automatic latest/stable family discovery,
# no marketing homepage scraping, and no automatic move to another release family.
# Invalid or unavailable versions fail clearly rather than substituting a version.
# This downloads Proxmox VE AMD64, not Backup Server, Mail Gateway, Datacenter
# Manager, or ARM64. The official public enterprise ISO endpoint requires no login
# or subscription. TLS certificate checking is always enabled.
# --version 9.2 selects the newest patch/build in that MAJOR.MINOR family.
# --version 9.2-1 pins that exact ISO revision. Numeric revisions sort numerically
# (9.2-10 > 9.2-2). A three-component patch selector pins that patch and chooses
# its newest revision. ALPHA/BETA/RC images require an exact explicit selection.
# The chosen ISO must be listed in the official combined SHA256SUMS manifest.
#
# Output: Proxmox_VE_<MAJOR.MINOR>_<YYMMDD>.iso, using the local run-start date.
# Patch/build versions remain part of that family; the exact source name is logged.
# Explicit previews retain their full version/suffix in the output filename.
# After successful verification, default behavior replaces today's output and
# removes older stable ISOs only in the same family. Other families, products, and
# previews are preserved. Selecting a preview replaces only that exact preview's
# history. --keep-existing preserves all history; if today's exact filename exists,
# it keeps that file after downloading and verifying the fresh copy.
# Every invocation downloads afresh; no version check skips a download.
#
# The optional folder defaults to the current directory and must already exist.
# Options may precede or follow the folder. Use -- before a folder beginning with
# a dash. --version=VERSION is also accepted. No prompts or local ISO building.
# Progress/status show by default, even when redirected. --silent (or -s) suppresses
# routine output and progress; errors remain on stderr with a nonzero exit status.
# Failures before publication preserve existing ISOs. A failed checksum never
# produces a final ISO filename. HTTPS certificate validation is never disabled.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow space for a new ISO alongside existing files. Downloads are staged in the
# destination and removed on exit; forced kills can leave .proxmox-download.*
# directories. The persistent .proxmox-download.lock coordinates runs; concurrent
# runs targeting the same folder fail. No separate helper files are required.
#
# Cron: 03:00 on the first day of each month (edit paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-proxmox.sh /mnt/isos >> /path/to/proxmox.log 2>&1
#
# Official metadata and binary source: https://enterprise.proxmox.com/iso/
# Monitor logs for upstream layout or checksum changes.
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Proxmox VE download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
keep=0
silent=0
destination=.
path_given=0
options=1
requested=$DEFAULT_VERSION
while (( $# )); do
    if (( options )); then
        case $1 in
            --silent|-s) silent=1; shift; continue ;;
            --keep-existing|keep-existing) keep=1; shift; continue ;;
            --version)
                [[ $# -ge 2 && -n $2 && $2 != -* ]] || die '--version requires a release family or an exact version'
                requested=$2; shift 2; continue ;;
            --version=*) requested=${1#*=}; shift; continue ;;
            --) options=0; shift; continue ;;
            -*) die "Unknown option: $1" ;;
        esac
    fi
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--version VERSION] [--keep-existing] [--silent]"
    destination=$1
    path_given=1
    shift
done
curl_progress=()
if (( silent )); then
    exec >/dev/null
    curl_progress=(--silent)
fi
[[ -d $destination ]] || die "Download folder does not exist or is not a directory: $destination"
folder=$(cd -- "$destination" && pwd -P)
[[ -w $folder ]] || die "Download folder is not writable: $folder"
run_date=$(date +%y%m%d)
for cmd in curl python3 flock; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
exec 9>"$folder/.proxmox-download.lock"
flock -n 9 || die "Another Proxmox VE download is running in: $folder"
work=$(mktemp -d "$folder/.proxmox-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving Proxmox VE version selection: %s...\n' "$requested"
python3 - "$work" "$requested" "$DOWNLOAD_BASE_URL" <<'PY_RESOLVE'
import re
import subprocess
import sys
from pathlib import Path
work, requested, base_url = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading Proxmox VE %s (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'Proxmox VE ISO download failed; existing ISOs preserved.'

printf 'Verifying official SHA-256 and ISO structure...\n'
python3 - "$work" "$folder" "$version" "$run_date" "$keep" <<'PY_PUBLISH'
import hashlib
import os
import re
import sys
from pathlib import Path
work, folder, version, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
source = work / 'download.iso'
try:
    sha = hashlib.sha256()
    with source.open('rb') as inp:
        for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
            sha.update(chunk)
        if sha.hexdigest() != (work / 'sha256').read_text().strip():
            raise RuntimeError('ISO SHA-256 does not match the official checksum; existing ISOs preserved.')
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        os.fsync(inp.fileno())
    target = folder / f'Proxmox_VE_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        def family(v):
            return tuple(map(int, re.match(r'(\d+)\.(\d+)', v).groups()))
        stable = re.compile(r'\d+\.\d+(?:\.\d+)*(?:-\d+)?')
        selected_stable = bool(stable.fullmatch(version))
        managed = re.compile(r'Proxmox_VE_(\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9.-]+)?)_\d{6}\.iso', re.I)
        for old in folder.iterdir():
            match = managed.fullmatch(old.name)
            if old == target or not match or not (old.is_file() or old.is_symlink()):
                continue
            previous = match[1]
            same = (bool(stable.fullmatch(previous)) and family(previous) == family(version)
                    if selected_stable else previous.casefold() == version.casefold())
            if same:
                old.unlink()
    print('Verified SHA-256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish Proxmox VE ISO: ' + str(exc))
PY_PUBLISH

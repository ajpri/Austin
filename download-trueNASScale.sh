#!/bin/bash
# Download a ready-made TrueNAS SCALE / Community Edition AMD64 installer ISO.
DEFAULT_VERSION="25.10"  # Edit this release family periodically; --version overrides it.
DOWNLOAD_BASE_URL="https://download.sys.truenas.net/"
#
# Usage:
#   ./download-trueNASScale.sh [EXISTING_FOLDER] [--version VERSION] [--keep-existing] [--silent]
#
# Examples:
#   ./download-trueNASScale.sh                         # Default family, current folder
#   ./download-trueNASScale.sh /mnt/isos --version 25.10
#   ./download-trueNASScale.sh --version 25.10.7          # Exact release/build
#   ./download-trueNASScale.sh --version 27.0.0-RC.1      # Explicit preview, if published
#   ./download-trueNASScale.sh . --keep-existing
#   ./download-trueNASScale.sh . > trueNASScale-download.log 2>&1
#   ./download-trueNASScale.sh . --silent > trueNASScale-errors.log 2>&1
#
# The family is manually configured: no automatic latest/stable family discovery,
# no marketing homepage scraping, and no automatic move to another release family.
# Invalid or unavailable versions fail clearly rather than substituting a version.
# SCALE is now branded TrueNAS Community Edition; this selects the Linux-based
# AMD64 installer, never the older FreeBSD-based CORE product. The official direct
# download index includes ISO links; only the manually selected family is eligible.
# Numeric patch components are sorted numerically (25.10.10 > 25.10.9).
# --version 25.10 selects the newest numeric release in that family. --version
# 25.10.7 selects that exact release, not 25.10.7.1. Previews require an exact
# ALPHA.N, BETA.N, or RC.N version. Nightly and custom builds are excluded.
# A checksum sidecar for the selected ISO must exist and match its SHA-256.
#
# Output: TrueNAS_SCALE_<MAJOR.MINOR>_<YYMMDD>.iso, using the local run-start date.
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
# destination and removed on exit; forced kills can leave .truenas-scale-download.*
# directories. The persistent .truenas-scale-download.lock coordinates runs; concurrent
# runs targeting the same folder fail. No separate helper files are required.
#
# Cron: 03:00 on the first day of each month (edit paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-trueNASScale.sh /mnt/isos >> /path/to/trueNASScale.log 2>&1
#
# Official metadata and binary source: https://download.sys.truenas.net/
# Monitor logs for upstream layout or checksum changes.
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: TrueNAS SCALE download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
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
exec 9>"$folder/.truenas-scale-download.lock"
flock -n 9 || die "Another TrueNAS SCALE download is running in: $folder"
work=$(mktemp -d "$folder/.truenas-scale-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving TrueNAS SCALE version selection: %s...\n' "$requested"
python3 - "$work" "$requested" "$DOWNLOAD_BASE_URL" <<'PY_RESOLVE'
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit
work, requested, base_url = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading TrueNAS SCALE %s (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'TrueNAS SCALE ISO download failed; existing ISOs preserved.'

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
    target = folder / f'TrueNAS_SCALE_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        def family(v):
            return tuple(map(int, re.match(r'(\d+)\.(\d+)', v).groups()))
        stable = re.compile(r'\d+\.\d+(?:\.\d+)*(?:-\d+)?')
        selected_stable = bool(stable.fullmatch(version))
        managed = re.compile(r'TrueNAS_SCALE_(\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9.-]+)?)_\d{6}\.iso', re.I)
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
    sys.exit('ERROR: Could not verify or publish TrueNAS SCALE ISO: ' + str(exc))
PY_PUBLISH

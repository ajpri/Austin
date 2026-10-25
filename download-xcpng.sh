#!/bin/bash
# Download a ready-made XCP-ng full installer ISO, non-interactively.
DEFAULT_VERSION="8.3"  # Edit this release family periodically; --version overrides it.
#
# Usage:
#   ./download-xcpng.sh [EXISTING_FOLDER] [--version VERSION] [--keep-existing] [--silent]
#
# Examples:
#   ./download-xcpng.sh                         # Newest installer for DEFAULT_VERSION
#   ./download-xcpng.sh /mnt/isos --version 8.3  # Newest stable installer for 8.3
#   ./download-xcpng.sh --version 8.3.0-rc2      # Explicit archived preview release
#   ./download-xcpng.sh . --keep-existing       # Keep previous XCP-ng ISO files
#   ./download-xcpng.sh . > xcpng-download.log 2>&1
#
# VERSION defaults to DEFAULT_VERSION above. The release family is always chosen
# manually, either by editing that variable or passing --version. There is no
# automatic discovery of release families: latest/stable are not accepted values.
# Only the chosen family's official SHA256SUMS is consulted; no homepage, release
# page, or top-level ISO directory is scraped. Previews require an explicit suffix.
#
# --version 8.3 pins the 8.3 family, including 8.3.1 and 8.3-U2. It does not move
# to 8.4 or 9.0. --version 8.3.1 pins that patch; --version 8.3-U2 pins that update.
# Within a family, ordering is numeric patch, U update number, refresh date, then
# refresh revision. Missing patch/update numbers count as zero. Unknown filename
# formats are rejected rather than guessed. Nothing is built locally.
#
# --version 8.3.0-rc2 explicitly selects that exact published preview. Other
# recognized preview suffixes: alpha, beta, preview, demo, demonstrator (with an
# optional number). An exact refresh such as 8.3.0-20260806 is also accepted.
# Explicit releases may be found in the family's current or old/ SHA256SUMS.
# Only full installers with official checksums are accepted; netinstall, special
# upgrade-only, and testing-driver ISOs are excluded. An unavailable explicit
# request fails instead of falling back to a different family or release.
#
# Stable output: XCP-ng_<MAJOR.MINOR>_<YYMMDD>.iso, e.g. XCP-ng_8.3_261025.iso.
# Patch/update/refresh versions stay in the 8.3 family; the exact source filename
# is logged. Previews retain their suffix, e.g. XCP-ng_8.3.0-rc2_261025.iso.
# Dates use the local run-start date.
#
# The folder defaults to the current working directory; it must already exist.
# Options may appear before or after the folder. Use -- before a folder whose
# name starts with a dash: ./download-xcpng.sh -- -isos
# Each run downloads afresh and verifies the official SHA-256 before publishing.
# By default it replaces today's output and removes older stable ISOs only in
# the selected MAJOR.MINOR family, including legacy names such as 8.3.1 or 8.3-U2.
# Other families are retained. Previews are retained separately: downloading one
# replaces only that exact preview's history, never a stable ISO or another preview.
# --keep-existing retains all history;
# if today's exact filename exists, it keeps that file after downloading and
# verifying the fresh copy. Unrelated files are untouched. Failures before
# publication preserve existing ISOs, print errors to stderr, and exit nonzero.
#
# Progress and status messages are shown by default, including when redirected.
# --silent (or -s) suppresses progress and success/status output; errors remain on
# stderr and exit codes are unchanged. Useful for cron or error-only log files:
#   ./download-xcpng.sh . --silent > download-errors.log 2>&1
# Use > logfile 2>&1 without --silent to capture progress and status as well.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow space for a full ISO alongside existing files. Downloads are staged in the
# destination and removed on exit; a forced kill or power failure may leave
# .xcpng-download.* directories. The persistent .xcpng-download.lock coordinates
# concurrent runs; a second run targeting the same folder fails with an error.
#
# Cron: 03:00 on the first day of each month (edit paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-xcpng.sh /mnt/isos >> /path/to/xcpng.log 2>&1
#
# Source: https://updates.xcp-ng.org/isos/
# ISO transfers use https://mirrors.xcp-ng.org/ with HTTPS-only mirror selection.
# Verification reference: https://docs.xcp-ng.org/project/mirrors/
# No account or local ISO building is required. Monitor logs for upstream changes.
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: XCP-ng ISO download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
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
                [[ $# -ge 2 && -n $2 && $2 != -* ]] || die '--version requires a version, e.g. 8.3 or 8.3.0-rc2'
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
# Keep errors on stderr in silent mode; suppress routine status and curl progress.
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
exec 9>"$folder/.xcpng-download.lock"
flock -n 9 || die "Another XCP-ng download is running in: $folder"
work=$(mktemp -d "$folder/.xcpng-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving XCP-ng version selection: %s...\n' "$requested"
python3 - "$work" "$requested" <<'PY_RESOLVE'
import re
import subprocess
import sys
from pathlib import Path

work, requested = Path(sys.argv[1]), sys.argv[2]
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
        raise RuntimeError('Specify a version in DEFAULT_VERSION or --version, e.g. 8.3, 8.3.1, 8.3-U2, or 8.3.0-rc2. Automatic latest/stable selection is not supported.')
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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading XCP-ng %s (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 10 --connect-timeout 30 --max-time 21600 \
    --speed-limit 1024 --speed-time 300 --output "$work/download.iso" "$url" ||
    die 'XCP-ng ISO download failed; existing ISO files were preserved.'

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
    with source.open('rb') as inp:
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        os.fsync(inp.fileno())
    target = folder / f'XCP-ng_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        family = re.match(r'\d+\.\d+', version)[0]
        preview_suffix = r'(?:alpha|beta|rc|preview|demo|demonstrator)\d*'
        selected_preview = bool(re.search(r'-' + preview_suffix + r'$', version, re.I))
        managed = re.compile(r'XCP-ng_(\d+\.\d+(?:\.\d+)?(?:-[A-Za-z0-9.]+)?)_\d{6}\.iso', re.I)
        stable_version = re.compile(r'\d+\.\d+(?:\.\d+)?(?:-U\d+)?(?:-\d{8}(?:\.\d+)?)?', re.I)
        for old in folder.iterdir():
            match = managed.fullmatch(old.name)
            if old == target or not match or not (old.is_file() or old.is_symlink()):
                continue
            previous = match[1]
            if selected_preview:
                same_group = previous.casefold() == version.casefold()
            else:
                same_group = bool(stable_version.fullmatch(previous)) and re.match(r'\d+\.\d+', previous)[0] == family
            if same_group:
                old.unlink()
    print('Verified SHA-256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish XCP-ng ISO: ' + str(exc))
PY_PUBLISH

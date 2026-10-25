#!/bin/bash
# Download an official Ubuntu Desktop or Server amd64 ISO in standard support.
DEFAULT_VERSION="26.04"       # Release family; --version overrides it.
DEFAULT_EDITION="desktop"    # desktop or server; --edition overrides it.
DOWNLOAD_BASE_URL="https://releases.ubuntu.com/"
# Maintained upstream distro-info data: release and end-of-standard-support dates.
LIFECYCLE_URL="https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv"
#
# Usage:
#   ./download-ubuntu.sh [EXISTING_FOLDER] [--edition desktop|server]
#                       [--version YY.MM] [--keep-existing] [--silent]
# Examples:
#   ./download-ubuntu.sh                           # Desktop 26.04, current folder
#   ./download-ubuntu.sh /mnt/isos --edition server --version 24.04
#   ./download-ubuntu.sh --version 26.10            # Released interim version
#   ./download-ubuntu.sh . --keep-existing
#   ./download-ubuntu.sh . > ubuntu-download.log 2>&1
#   ./download-ubuntu.sh . --silent > ubuntu-errors.log 2>&1
#
# Supports released LTS and interim families within STANDARD support. ESM/Ubuntu
# Pro-only, end-of-life, future, beta, and daily releases are excluded. Accepts
# release families without a hardcoded allowlist; uses upstream distro-info dates
# and official Ubuntu image checksums. Requires correct local system date.
# No automatic switch to another release family. For 26.04, selects the highest
# numeric point release listed in that family's SHA256SUMS. Logs the full source
# filename but excludes the point suffix from the saved filename. Desktop uses
# the standard desktop ISO; Server uses live-server. Only amd64 is downloaded.
#
# Output: Ubuntu_Desktop_<YY.MM>_<YYMMDD>.iso or
#         Ubuntu_Server_<YY.MM>_<YYMMDD>.iso (local run-start date).
# Always downloads afresh, including with --keep-existing. Verifies official
# SHA256 and ISO structure before publishing atomically. Checksums travel over
# HTTPS; detached GPG signatures are not checked. TLS validation stays enabled.
# By default, replaces today's exact name and removes older date-named files
# only in the SAME edition and release family. Other editions/families remain.
# --keep-existing (also keep-existing) keeps all history and an existing exact
# filename after downloading and verifying the fresh copy. Failed downloads or
# checks preserve existing ISOs. Metadata/layout errors fail without substitution.
#
# Folder defaults to . and must already exist; it is never created. Options may
# precede/follow the folder. --edition=server and --version=24.04 also work. Use --
# before a dash-prefixed folder. No prompts. Progress/status show even redirected;
# --silent/-s suppresses routine output/progress; errors stay on stderr/nonzero.
# This header contains usage documentation; no output log is created by default.
# Dependencies: Bash, curl, Python 3 (standard library), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow room for a fresh ISO alongside existing files. Staging directories in the
# destination are cleaned on exit; SIGKILL may leave .ubuntu-download.* directories.
# Persistent .ubuntu-download.lock prevents concurrent runs in the same folder.
# Cron, monthly at 03:00 (use absolute paths):
# 0 3 1 * * /bin/bash /path/to/download-ubuntu.sh /mnt/isos >> /path/to/ubuntu.log 2>&1
# Official images/checksums: https://releases.ubuntu.com/
# Lifecycle definitions: https://ubuntu.com/about/release-cycle
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Ubuntu download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
keep=0
silent=0
destination=.
path_given=0
options=1
requested=$DEFAULT_VERSION
edition=$DEFAULT_EDITION
while (( $# )); do
    if (( options )); then
        case $1 in
            --silent|-s) silent=1; shift; continue ;;
            --keep-existing|keep-existing) keep=1; shift; continue ;;
            --version|--edition)
                [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "$1 requires a value"
                if [[ $1 == --version ]]; then requested=$2; else edition=$2; fi
                shift 2; continue ;;
            --version=*) requested=${1#*=}; shift; continue ;;
            --edition=*) edition=${1#*=}; shift; continue ;;
            --) options=0; shift; continue ;;
            -*) die "Unknown option: $1" ;;
        esac
    fi
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--edition desktop|server] [--version VERSION] [--keep-existing] [--silent]"
    destination=$1
    path_given=1
    shift
done
[[ $requested =~ ^[0-9]{2}\.(04|10)$ ]] || die 'Version must be a release family such as 24.04, 26.04, or 26.10 (without a point suffix).'
edition=${edition,,}
case $edition in
    desktop) label=Desktop ;;
    server) label=Server ;;
    *) die 'Edition must be desktop or server.' ;;
esac
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
exec 9>"$folder/.ubuntu-download.lock"
flock -n 9 || die "Another Ubuntu download is running in: $folder"
work=$(mktemp -d "$folder/.ubuntu-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving supported Ubuntu %s %s amd64 ISO...\n' "$label" "$requested"
python3 - "$work" "$requested" "$edition" "$DOWNLOAD_BASE_URL" "$LIFECYCLE_URL" <<'PY_RESOLVE'
import csv
import datetime
import io
import re
import subprocess
import sys
from pathlib import Path

work, version, edition, base, lifecycle_url = Path(sys.argv[1]), *sys.argv[2:]

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
PY_RESOLVE

url=$(<"$work/url")
printf 'Downloading Ubuntu %s %s (fresh download on every run)...\n' "$label" "$requested"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'Ubuntu ISO download failed; existing ISOs preserved.'

printf 'Verifying official SHA256 and ISO structure...\n'
python3 - "$work" "$folder" "$label" "$requested" "$run_date" "$keep" <<'PY_PUBLISH'
import hashlib
import os
import re
import sys
from pathlib import Path

work, folder, edition, version, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
source = work / 'download.iso'
try:
    sha = hashlib.sha256()
    with source.open('rb') as inp:
        for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
            sha.update(chunk)
        if sha.hexdigest() != (work / 'sha256').read_text().strip():
            raise RuntimeError('ISO SHA256 does not match official metadata; existing ISOs preserved.')
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        os.fsync(inp.fileno())
    target = folder / f'Ubuntu_{edition}_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        managed = re.compile(rf'Ubuntu_{re.escape(edition)}_{re.escape(version)}_\d{{6}}\.iso')
        for old in folder.iterdir():
            if old != target and managed.fullmatch(old.name) and (old.is_file() or old.is_symlink()):
                old.unlink()
    print('Verified SHA256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish Ubuntu ISO: ' + str(exc))
PY_PUBLISH

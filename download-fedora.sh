#!/bin/bash
# Download an official, released Fedora x86_64 installer ISO.
DEFAULT_VERSION="44"       # Change to 45 once released; --version overrides this.
DEFAULT_EDITION="workstation"  # workstation or server; --edition overrides this.
RELEASES_URL="https://fedoraproject.org/releases.json"
#
# Usage:
#   ./download-fedora.sh [EXISTING_FOLDER] [--edition workstation|server]
#                       [--version VERSION] [--keep-existing] [--silent]
# Examples:
#   ./download-fedora.sh                          # Workstation 44, current folder
#   ./download-fedora.sh /mnt/isos --edition server --version 43
#   ./download-fedora.sh --version 45             # Requires a published final ISO
#   ./download-fedora.sh . --keep-existing
#   ./download-fedora.sh . > fedora-download.log 2>&1
#   ./download-fedora.sh . --silent > fedora-errors.log 2>&1
#
# Any positive numeric release version is accepted; there is no version allowlist.
# Official release metadata must contain exactly one matching released ISO.
# Workstation uses the Live ISO; Server uses the full DVD ISO (not netinstall).
# Beta, RC, Rawhide, other architectures, and other releases are never substituted.
# Older releases absent from the metadata fail clearly; no archive fallback.
# Downloads are fresh on EVERY invocation, including with --keep-existing.
# HTTPS, official metadata SHA256, expected size, and ISO structure are checked.
# The checksum is obtained through HTTPS; detached GPG signatures are not checked.
#
# Output: Fedora_Workstation_<VERSION>_<YYMMDD>.iso or
#         Fedora_Server_<VERSION>_<YYMMDD>.iso, using the local run-start date.
# After verification, default behavior replaces today's file and deletes older
# date-named ISOs only for the same edition and version. Other versions/editions
# are preserved. --keep-existing (also keep-existing) preserves all history and
# keeps an existing exact output name after verifying the fresh download.
# Failed downloads/checks preserve existing ISOs; publication uses an atomic move.
#
# The folder is optional (defaults to .) and must exist; it is never created.
# Options may precede/follow the folder; --version=44 and --edition=server work.
# Use -- before a folder beginning with a dash. No prompts or local ISO building.
# Progress/status show by default even with redirection; --silent/-s suppresses
# routine output and progress. Errors go to stderr and return nonzero.
# Usage comments are the documentation; the script creates no output log itself.
#
# Dependencies: Bash, curl, Python 3 (standard library), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow room for a new ISO alongside existing files. Temporary downloads stage in
# the destination and are removed on exit (SIGKILL can leave .fedora-download.*).
# A persistent .fedora-download.lock prevents concurrent runs in the same folder.
#
# Cron example, monthly at 03:00 (use absolute paths):
# 0 3 1 * * /bin/bash /path/to/download-fedora.sh /mnt/isos >> /path/to/fedora.log 2>&1
# Official metadata: https://fedoraproject.org/releases.json
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Fedora download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
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
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--edition workstation|server] [--version VERSION] [--keep-existing] [--silent]"
    destination=$1
    path_given=1
    shift
done
[[ $requested =~ ^[1-9][0-9]*$ ]] || die 'Version must be a positive whole release number, such as 43, 44, or 45.'
edition=${edition,,}
case $edition in
    workstation) label=Workstation ;;
    server) label=Server ;;
    *) die 'Edition must be workstation or server.' ;;
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
exec 9>"$folder/.fedora-download.lock"
flock -n 9 || die "Another Fedora download is running in: $folder"
work=$(mktemp -d "$folder/.fedora-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving released Fedora %s %s x86_64 ISO...\n' "$label" "$requested"
python3 - "$work" "$requested" "$label" "$RELEASES_URL" <<'PY_RESOLVE'
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

work, version, edition, metadata_url = Path(sys.argv[1]), *sys.argv[2:]
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
PY_RESOLVE

url=$(<"$work/url")
printf 'Downloading Fedora %s %s (fresh download on every run)...\n' "$label" "$requested"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'Fedora ISO download failed; existing ISOs preserved.'

printf 'Verifying official size, SHA256, and ISO structure...\n'
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
    if source.stat().st_size != int((work / 'size').read_text()):
        raise RuntimeError('ISO size does not match official metadata; existing ISOs preserved.')
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
    target = folder / f'Fedora_{edition}_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        managed = re.compile(rf'Fedora_{re.escape(edition)}_{re.escape(version)}_\d{{6}}\.iso')
        for old in folder.iterdir():
            if old != target and managed.fullmatch(old.name) and (old.is_file() or old.is_symlink()):
                old.unlink()
    print('Verified size and SHA256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish Fedora ISO: ' + str(exc))
PY_PUBLISH

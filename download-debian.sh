#!/bin/bash
# Download the latest official Debian amd64 netinst ISO in a selected major release.
DEFAULT_VERSION="13"  # Edit this major release periodically; --version overrides it.
DOWNLOAD_BASE_URL="https://cdimage.debian.org/debian-cd/"
ARCHIVE_BASE_URL="https://cdimage.debian.org/cdimage/archive/"
#
# Usage:
#   ./download-debian.sh [EXISTING_FOLDER] [--version VERSION] [--keep-existing] [--silent]
# Examples:
#   ./download-debian.sh                         # Latest Debian 13 netinst, cwd
#   ./download-debian.sh /mnt/isos --version 12
#   ./download-debian.sh --version=14            # Once officially published
#   ./download-debian.sh . --keep-existing
#   ./download-debian.sh . > debian-download.log 2>&1
#   ./download-debian.sh . --silent > debian-errors.log 2>&1
#
# VERSION is a positive major release number, not a hardcoded allowlist. Selects
# the newest numeric point release in that major (13 -> 13.7.0, for example).
# Never moves automatically to a different major release or a preview/testing ISO.
# Reads official numeric release directories; consults the official image archive
# when that major is absent from the current image index. Missing releases or
# missing netinst images fail clearly; no older point release is substituted.
# This downloads standard amd64 netinst, excluding Debian Edu/Mac and live/DVD
# images. Choose desktop environments or a headless install inside the installer.
# An Internet connection is needed at installation time for additional packages.
#
# Output: Debian_<FULL_POINT_VERSION>_<YYMMDD>.iso (local run-start date).
# Always downloads afresh, even with --keep-existing. Verifies official SHA256 and
# ISO structure before an atomic move into place. SHA256 is fetched over HTTPS;
# detached GPG signatures are not checked. Failed verification preserves old ISOs.
# By default replaces today's exact filename and deletes older date-named netinst
# ISOs in the SAME MAJOR release, including older point releases and legacy
# Debian_Netinst_<VERSION>_<YYMMDD>.iso names. Other majors
# are preserved. --keep-existing (also keep-existing) preserves all history and
# keeps an existing exact output filename after verifying the fresh download.
#
# Folder is optional, defaults to ., and must already exist; never created.
# Options can precede/follow the folder; use -- before a dash-prefixed folder.
# Progress/status show even when redirected. --silent/-s suppresses routine output
# and progress; errors stay on stderr with a nonzero exit status. No prompts.
# All usage is documented here; no output logs are automatically created.
#
# Dependencies: Bash, curl, Python 3 (standard library), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow room for a fresh download alongside existing ISOs. Staging files in the
# destination are removed on exit; SIGKILL may leave .debian-download.* directories.
# The persistent .debian-download.lock prevents concurrent runs in the same folder.
# Cron, monthly at 03:00 (use absolute paths):
# 0 3 1 * * /bin/bash /path/to/download-debian.sh /mnt/isos >> /path/to/debian.log 2>&1
# Official sources: https://cdimage.debian.org/debian-cd/
#                   https://cdimage.debian.org/cdimage/archive/
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Debian download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
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
                [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "$1 requires a value"
                requested=$2
                shift 2; continue ;;
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
[[ $requested =~ ^[1-9][0-9]*$ ]] || die 'Version must be a positive whole release number, such as 12, 13, or 14.'
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
exec 9>"$folder/.debian-download.lock"
flock -n 9 || die "Another Debian download is running in: $folder"
work=$(mktemp -d "$folder/.debian-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving newest released Debian %s amd64 netinst ISO...\n' "$requested"
python3 - "$work" "$requested" "$DOWNLOAD_BASE_URL" "$ARCHIVE_BASE_URL" <<'PY_RESOLVE'
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

work, major, current_base, archive_base = Path(sys.argv[1]), *sys.argv[2:]

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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading Debian %s amd64 netinst (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'Debian netinst ISO download failed; existing ISOs preserved.'

printf 'Verifying official SHA256 and ISO structure...\n'
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
            raise RuntimeError('ISO SHA256 does not match official metadata; existing ISOs preserved.')
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        os.fsync(inp.fileno())
    target = folder / f'Debian_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        major = re.escape(version.split('.')[0])
        managed = re.compile(rf'Debian_(?:Netinst_)?{major}(?:\.[0-9]+)+_\d{{6}}\.iso')
        for old in folder.iterdir():
            if old != target and managed.fullmatch(old.name) and (old.is_file() or old.is_symlink()):
                old.unlink()
    print('Verified SHA256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish Debian netinst ISO: ' + str(exc))
PY_PUBLISH

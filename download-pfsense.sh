#!/bin/bash
# Download the current Netgate Installer AMD64 ISO for installing pfSense CE.
#
# Usage:
#   ./download-pfsense.sh [EXISTING_FOLDER] [--keep-existing] [--silent]
#
# Examples:
#   ./download-pfsense.sh                     # Download to the current directory
#   ./download-pfsense.sh . --keep-existing    # Retain existing installer ISOs
#   ./download-pfsense.sh /mnt/isos            # Use an existing destination folder
#   ./download-pfsense.sh . > pfsense-download.log 2>&1
#
# The folder defaults to the current working directory; it must already exist.
# Options may appear before or after the folder. Use -- before a folder
# whose name starts with a dash: ./download-pfsense.sh -- -isos
#
# Each run fetches Netgate's current official SHA-256 list, finds the matching
# stable AMD64 ISO.gz on FileEagle, and downloads it without login or prompts.
# Only an archive matching Netgate's current checksum is accepted. A stale mirror,
# changed page layout, download failure, or checksum mismatch causes a nonzero exit
# and a clear error. It never silently falls back to an older installer.
#
# After SHA-256 verification, it decompresses the archive (no ISO building) and
# saves pfsense_<YYMMDD>.iso, using the local run-start date. The installer version
# is reported in the log but omitted from the output filename.
# This is an ONLINE INSTALLER: booting it requires Internet access to download
# pfSense CE. Its installer version (e.g. 1.2) is not a CE release (e.g. 2.9.0).
# Select Community Edition in the installer. This is not an offline CE ISO.
#
# By default, after publishing the verified ISO, the script removes older files
# matching pfsense_<YYMMDD>.iso in the destination (including older files named
# Netgate_Installer_<numeric-version>_<YYMMDD>.iso by previous script versions).
# --keep-existing retains those files; if today's exact name already exists, it
# keeps that file after downloading and verifying the fresh archive. Every run
# downloads, regardless of existing versions. Unrelated files are left alone.
# Failures before publication preserve existing ISOs. Errors go to stderr.
#
# Progress and status messages are shown by default, including when redirected.
# --silent (or -s) suppresses progress and success/status output; errors remain on
# stderr and exit codes are unchanged. Useful for cron or error-only log files:
#   ./download-pfsense.sh . --silent > download-errors.log 2>&1
# Use > logfile 2>&1 without --silent to capture progress and status as well.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow space for the compressed archive and extracted ISO alongside any old ISO.
# Temporary files are stored in the destination and removed on exit. A forced kill
# or power failure can leave .pfsense-download.* directories. The persistent
# .pfsense-download.lock prevents simultaneous runs targeting the same folder.
#
# Cron: 03:00 on the first day of each month (edit all paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-pfsense.sh /mnt/isos >> /path/to/pfsense.log 2>&1
#
# Binary mirror: https://www.fileeagle.com/software/3453/pfSense-Community-Edition
# Official checksum: https://www.netgate.com/hubfs/pfSense-plus-installer-checksums.txt
# Installer docs: https://docs.netgate.com/pfsense/en/latest/install/netinstaller.html
# Mirror availability and page formats may change; monitor the log for failures.
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: pfSense installer download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
keep=0
silent=0
destination=.
path_given=0
options=1
for arg in "$@"; do
    if (( options )); then
        case $arg in
            --silent|-s) silent=1; continue ;;
            --keep-existing|keep-existing) keep=1; continue ;;
            --) options=0; continue ;;
            -*) die "Unknown option: $arg" ;;
        esac
    fi
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--keep-existing] [--silent]"
    destination=$arg
    path_given=1
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
exec 9>"$folder/.pfsense-download.lock"
flock -n 9 || die "Another pfSense installer download is running in: $folder"
work=$(mktemp -d "$folder/.pfsense-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Checking Netgate\047s current installer checksum and FileEagle mirror...\n'
python3 - "$work" <<'PY_RESOLVE'
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit, unquote

work = Path(sys.argv[1])
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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading Netgate Installer %s AMD64 (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 10 --connect-timeout 30 --max-time 21600 \
    --speed-limit 1024 --speed-time 300 --output "$work/download.iso.gz" "$url" ||
    die 'Installer download failed; existing ISO files were preserved.'

python3 - "$work" "$folder" "$run_date" "$keep" <<'PY_PUBLISH'
import gzip
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

work, folder, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
archive = work / 'download.iso.gz'
expected = (work / 'sha256').read_text().strip()
sha = hashlib.sha256()
try:
    with archive.open('rb') as inp:
        for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
            sha.update(chunk)
    if sha.hexdigest() != expected:
        raise RuntimeError('Installer archive SHA-256 does not match Netgate\'s current official checksum; existing ISOs preserved.')
    print('Verified archive SHA-256 against Netgate.', flush=True)
    target = folder / f'pfsense_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    iso = work / 'installer.iso'
    print('Decompressing verified archive...', flush=True)
    # Reading to EOF also validates gzip's CRC and uncompressed-size trailer.
    with gzip.open(archive, 'rb') as inp, iso.open('wb') as out:
        shutil.copyfileobj(inp, out, length=8 * 1024 * 1024)
        out.flush()
        os.fsync(out.fileno())
    with iso.open('rb') as inp:
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Extracted file has no ISO 9660 volume descriptor; existing ISOs preserved.')
    # Same filesystem: incomplete downloads never appear under the final name.
    os.replace(iso, target)
    if keep == '0':
        for old in folder.iterdir():
            if (old != target and re.fullmatch(r'(?:pfsense|Netgate_Installer_\d+(?:\.\d+)+)_\d{6}\.iso', old.name)
                and (old.is_file() or old.is_symlink())):
                old.unlink()
    print('Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish the pfSense installer: ' + str(exc))
PY_PUBLISH

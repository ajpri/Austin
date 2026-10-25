#!/bin/bash
# Download Hiren's BootCD PE x64 as a ready-made ISO.
DOWNLOAD_PAGE="https://www.hirensbootcd.org/download/"
#
# Usage:
#   ./download-hbcdpe.sh [EXISTING_FOLDER] [--keep-existing] [--silent]
#
# Examples:
#   ./download-hbcdpe.sh                       # Current project ISO, current directory
#   ./download-hbcdpe.sh /mnt/isos
#   ./download-hbcdpe.sh . --keep-existing
#   ./download-hbcdpe.sh . > hbcdpe-download.log 2>&1
#   ./download-hbcdpe.sh . --silent > hbcdpe-errors.log 2>&1
#
# Each run uses the project's current download page and unversioned ISO URL.
# There is no version setting or --version argument to maintain. Only the current
# project download is selected, not archived/beta/legacy HBCD. The ISO URL, file
# size, and published SHA-256 must be unambiguous; changed metadata fails clearly.
# Any detected release number is informational log output only.
#
# Every invocation downloads afresh, without prompts or local ISO building. It
# follows the project's HTTPS download/mirror route and requires its published
# SHA-256 and size to match, plus an ISO 9660 volume descriptor, before publication.
# Output: hbcdpe_<YYMMDD>.iso, using the local run-start date.
# Default behavior replaces today's file and removes older hbcdpe_<YYMMDD>.iso
# files after successful verification. This includes legacy files named
# HBCD_PE_<full-version>_<YYMMDD>.iso. Unrelated filenames are preserved.
# --keep-existing retains all history; if today's exact output already exists,
# it keeps that file after downloading and verifying the fresh copy.
#
# The folder defaults to the current working directory and must already exist.
# Options can precede or follow the folder.
# Use -- before a folder starting with a dash. Progress and status show by default,
# including when redirected. --silent (or -s) suppresses routine output/progress;
# errors remain on stderr and return nonzero. Existing ISOs survive failures
# before publication. HTTPS certificate checks are never disabled.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow space for a new ISO alongside existing files. Temporary downloads are
# staged in the destination and removed on exit. Forced kills can leave hidden
# .hbcdpe-download.* directories. The persistent .hbcdpe-download.lock coordinates
# concurrent runs: a second run targeting the same folder fails clearly.
#
# Cron: 03:00 on the first day of each month (edit paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-hbcdpe.sh /mnt/isos >> /path/to/hbcdpe.log 2>&1
#
# ISO, release information, checksum source: https://www.hirensbootcd.org/download/
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: HBCD PE download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
keep=0
silent=0
destination=.
path_given=0
options=1
while (( $# )); do
    if (( options )); then
        case $1 in
            --silent|-s) silent=1; shift; continue ;;
            --keep-existing|keep-existing) keep=1; shift; continue ;;
            --) options=0; shift; continue ;;
            -*) die "Unknown option: $1" ;;
        esac
    fi
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--keep-existing] [--silent]"
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
exec 9>"$folder/.hbcdpe-download.lock"
flock -n 9 || die "Another HBCD PE download is running in: $folder"
work=$(mktemp -d "$folder/.hbcdpe-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Fetching the current HBCD PE ISO and checksum from the project download page...\n'
python3 - "$work" "$DOWNLOAD_PAGE" <<'PY_RESOLVE'
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit
work, page_url = Path(sys.argv[1]), sys.argv[2]
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
PY_RESOLVE

url=$(<"$work/url")
printf 'Downloading the current HBCD PE ISO (fresh download on every run)...\n'
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 21600 --speed-limit 1024 --speed-time 300 \
    --output "$work/download.iso" "$url" || die 'HBCD PE ISO download failed; existing ISOs preserved.'

printf 'Verifying official SHA-256 and ISO structure...\n'
python3 - "$work" "$folder" "$run_date" "$keep" <<'PY_PUBLISH'
import hashlib
import os
import re
import sys
from pathlib import Path
work, folder, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
source = work / 'download.iso'
try:
    if source.stat().st_size != int((work / 'size').read_text()):
        raise RuntimeError('ISO size does not match the project download page; existing ISOs preserved.')
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
    target = folder / f'hbcdpe_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download verified; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        managed = re.compile(r'(?:hbcdpe|HBCD_PE_\d+\.\d+\.\d+)_\d{6}\.iso')
        for old in folder.iterdir():
            if (old != target and managed.fullmatch(old.name)
                and (old.is_file() or old.is_symlink())):
                old.unlink()
    print('Verified SHA-256. Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not verify or publish HBCD PE ISO: ' + str(exc))
PY_PUBLISH

#!/bin/bash
# Download Microsoft's current ready-made Windows 11 x64 English ISO.
#
# Usage:
#   ./download-win11.sh [EXISTING_FOLDER] [--keep-existing] [--silent]
#
# Examples:
#   ./download-win11.sh                       # Download to the current directory
#   ./download-win11.sh . --keep-existing     # Download here and retain prior ISOs
#   ./download-win11.sh /mnt/isos              # Download to an existing folder
#
# The folder defaults to the current working directory and must already exist.
# Options may appear before or after the folder. Use -- before a folder
# whose name starts with a dash (for example: ./download-win11.sh -- -isos).
#
# Each run obtains a fresh link and downloads the complete ISO without prompts.
# It verifies Microsoft's published SHA-256 and saves Win11_<version>_<YYMMDD>.iso
# using the selected release and local run-start date. It does not build an ISO.
# By default, after successful verification, it replaces today's output and removes
# older files matching exactly Win11_XXH[1 or 2]_YYMMDD.iso in the destination.
# --keep-existing retains that history; if today's filename already exists, it
# keeps that file after downloading and verifying the fresh copy. Failures before
# publication preserve existing ISOs, print an error to stderr, and exit nonzero.
#
# Progress and status messages are shown by default, including when redirected.
# --silent (or -s) suppresses progress and success/status output; errors remain on
# stderr and exit codes are unchanged. Useful for cron or error-only log files:
#   ./download-win11.sh . --silent > download-errors.log 2>&1
# Use > logfile 2>&1 without --silent to capture progress and status as well.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Run as a user with write access to the folder. Allow space for a full new ISO
# alongside the existing one. Temporary files are stored in the destination and
# removed on exit; a forced kill or power failure can leave .win11-download.*
# directories. The .win11-download.lock file stays in place to coordinate runs.
# Concurrent runs targeting the same folder fail with an error.
#
# Cron example: 03:00 on the first day of each month (edit all paths).
# Use an absolute destination path in cron so the download location is predictable.
# 0 3 1 * * /bin/bash /path/to/download-win11.sh /mnt/isos >> /path/to/win11.log 2>&1
#
# Microsoft can change or reject its website's unattended session flow. Such
# failures exit nonzero; monitor cron mail or the log. This is not a supported
# Microsoft API. Source page/checksum: https://www.microsoft.com/en-us/software-download/windows11
# Session-flow references: https://github.com/pbatard/Fido
# Third-party Linux CLI alternative: https://github.com/starkSV/windows-iso-downloader
# Neither third-party tool is required by this script.
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Windows ISO download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
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
exec 9>"$folder/.win11-download.lock"
flock -n 9 || die "Another Windows ISO download is running in: $folder"
work=$(mktemp -d "$folder/.win11-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Requesting a fresh Microsoft Windows 11 x64 English ISO link...\n'
python3 - "$work" <<'PY_RESOLVE'
import json
import re
import subprocess
import sys
import time
import uuid
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlencode, urlsplit, unquote

work = Path(sys.argv[1])
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
PY_RESOLVE

url=$(<"$work/url")
version=$(<"$work/version")
printf 'Downloading Windows 11 %s (this runs even if an ISO already exists)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-delay 10 --connect-timeout 30 --max-time 64800 \
    --speed-limit 1024 --speed-time 300 --output "$work/download.iso" "$url" ||
    die 'Microsoft ISO download failed; existing ISO files were preserved.'

python3 - "$work" "$folder" "$version" "$run_date" "$keep" <<'PY_PUBLISH'
import hashlib
import os
import re
import sys
from pathlib import Path
work, folder, version, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
source = work / 'download.iso'
expected = (work / 'sha256').read_text().strip()
sha = hashlib.sha256()
with source.open('rb') as inp:
    for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
        sha.update(chunk)
if sha.hexdigest() != expected:
    sys.exit('ERROR: ISO SHA-256 does not match Microsoft\'s published English x64 checksum; existing ISOs preserved.')
target = folder / f'Win11_{version}_{stamp}.iso'
if keep == '1' and os.path.lexists(target):
    print('Download verified; keeping existing file: ' + str(target))
    sys.exit(0)
# Work directory is on the destination filesystem, allowing atomic publication.
with source.open('rb') as inp:
    os.fsync(inp.fileno())
os.replace(source, target)
if keep == '0':
    for old in folder.iterdir():
        if (old != target and re.fullmatch(r'Win11_\d{2}H[12]_\d{6}\.iso', old.name)
            and (old.is_file() or old.is_symlink())):
            old.unlink()
print('Verified SHA-256. Saved: ' + str(target))
PY_PUBLISH

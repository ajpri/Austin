#!/bin/bash
# One self-contained ISO downloader for Linux. No arguments shows examples only.
# Usage: ./download-iso.sh PRODUCT [EXISTING_FOLDER] [OPTIONS]
# Products: win11, winserver, ubuntu, debian, fedora, xcpng, proxmox, truenas,
#           pfsense, hbcdpe. Run PRODUCT --help for version/source details.
# Folder defaults to the current directory; it must already exist.
# --version VALUE and --edition VALUE apply only to products supporting them.
# --keep-existing retains history and existing exact names, but still downloads
# and verifies a fresh copy on every run. Default cleanup follows product scope.
# --silent/-s suppresses routine output/progress; errors stay on stderr/nonzero.
# Options may surround the folder; use -- before a dash-prefixed folder.
# Downloads stage in the destination, then publish atomically after validation.
# Failures before publication preserve existing ISOs. Persistent per-product
# locks prevent concurrent runs of the same product into the same folder.
# No prompts, accounts, helper files, or local ISO construction are required.
# pfSense downloads Netgate Installer (third-party mirror + Netgate checksum),
# not a standalone offline CE installer. Windows Server uses Evaluation media.
# All transfers require HTTPS with certificate checking enabled. Published SHA256
# is verified except Server Eval (Microsoft size/ETag + ISO structure, hash logged).
# Detached GPG signatures are not checked. Upstream source changes can cause errors.
# Requirements: Bash 4+, curl, Python 3 (standard library), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow room for new ISOs alongside existing ones. Temporary directories are
# removed on exit; SIGKILL/power loss can leave hidden *-download.* directories.
# Example: ./download-iso.sh ubuntu /mnt/isos --edition server > ubuntu.log 2>&1
# Cron (monthly; absolute paths):
# 0 3 1 * * /bin/bash /path/to/download-iso.sh debian /mnt/isos >> /path/to/iso.log 2>&1

# Edit these defaults periodically. Help examples use these same values.
DEFAULT_WINSERVER_VERSION="2025"
DEFAULT_UBUNTU_VERSION="26.04"
DEFAULT_UBUNTU_EDITION="desktop"
DEFAULT_DEBIAN_VERSION="13"
DEFAULT_FEDORA_VERSION="44"
DEFAULT_FEDORA_EDITION="workstation"
DEFAULT_XCPNG_VERSION="8.3"
DEFAULT_PROXMOX_VERSION="9.2"
DEFAULT_TRUENAS_VERSION="25.10"

set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() {
    printf 'ERROR: %s\n' "$*" >&2
    printf 'Help: %s %s--help\n' "$0" "${product:+$product }" >&2
    exit 1
}
show_help() {
    cat <<HELP
ISO Downloader

Usage: $0 PRODUCT [FOLDER] [OPTIONS]
Folder defaults to the current directory and must already exist.

DOWNLOAD USING DEFAULTS

  $0 win11       # Current Windows 11, English x64
  $0 winserver   # Windows Server Evaluation $DEFAULT_WINSERVER_VERSION
  $0 ubuntu      # Ubuntu ${DEFAULT_UBUNTU_EDITION^} $DEFAULT_UBUNTU_VERSION
  $0 debian      # Latest Debian $DEFAULT_DEBIAN_VERSION netinst
  $0 fedora      # Fedora ${DEFAULT_FEDORA_EDITION^} $DEFAULT_FEDORA_VERSION
  $0 xcpng       # XCP-ng $DEFAULT_XCPNG_VERSION
  $0 proxmox     # Proxmox VE $DEFAULT_PROXMOX_VERSION
  $0 truenas     # TrueNAS SCALE $DEFAULT_TRUENAS_VERSION
  $0 pfsense     # Current Netgate Installer
  $0 hbcdpe      # Current Hiren's BootCD PE

COMMON EXAMPLES

  # Download into another folder
  $0 ubuntu /mnt/isos

  # Choose a version and server edition
  $0 ubuntu --version 24.04 --edition server
  $0 fedora --edition server
  $0 winserver --version 2022

  # Preserve existing files (still downloads and verifies a fresh copy)
  $0 debian --keep-existing

  # Suppress progress; errors remain visible
  $0 proxmox --silent

  # Save progress and messages to a log
  $0 ubuntu > ubuntu.log 2>&1

MORE HELP

  $0 ubuntu --help
HELP
}
product_help() {
    printf 'Usage: %s %s [FOLDER] [OPTIONS]\n\n' "$0" "$product"
    case $product in
        win11) cat <<HELP
Current Windows 11 multi-edition x64 English (US), from Microsoft's dynamic links.
No version or edition option. Verifies Microsoft's published SHA256.
Output: Win11_<version>_<YYMMDD>.iso
Default cleanup: all prior managed Windows 11 versions.
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
        hbcdpe) cat <<HELP
Current Hiren's BootCD PE x64 from https://www.hirensbootcd.org/download/.
No version or edition option. Checks the project's published size and SHA256.
Output: hbcdpe_<YYMMDD>.iso. Cleanup: prior managed HBCD PE files, including
legacy HBCD_PE_<version>_<YYMMDD>.iso names.
HELP
        ;;
    esac
    cat <<HELP

Common options:
  --keep-existing  Keep all history and an existing exact filename; always fetch fresh.
  --silent, -s     Hide routine status/progress; preserve errors and nonzero exits.
  --help, -h       Show this help without downloading.
Folder defaults to . and must exist. Quote paths containing spaces.
Options accept --version=VALUE / --edition=VALUE where supported.
Without --keep-existing, verified downloads replace today's file and prune the
managed history described above. Other products remain untouched.

Examples:
  $0 $product
  $0 $product "/mnt/ISO Collection" --keep-existing
  $0 $product --silent > ${product}-errors.log 2>&1
HELP
}

product=''
if (( $# == 0 )); then show_help; exit 0; fi
case $1 in --help|-h) show_help; exit 0 ;; esac
product=${1,,}
shift
requested=''
edition=''
version_supported=1
edition_supported=0
lock_id=$product
case $product in
    win11|pfsense|hbcdpe) version_supported=0 ;;
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
            --help|-h) product_help; exit 0 ;;
            --silent|-s) silent=1; shift; continue ;;
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
    winserver) [[ $requested == 2022 || $requested == 2025 ]] || die 'Choose Server version 2022 or 2025.' ;;
    ubuntu)
        [[ $requested =~ ^[0-9]{2}\.(04|10)$ ]] || die 'Use a release family such as 24.04 or 26.10 (without a point suffix).'
        [[ $edition == desktop || $edition == server ]] || die 'Ubuntu edition must be desktop or server.' ;;
    debian|fedora)
        [[ $requested =~ ^[1-9][0-9]*$ ]] || die 'Version must be a positive whole release number.'
        if [[ $product == fedora ]]; then
            [[ $edition == workstation || $edition == server ]] || die 'Fedora edition must be workstation or server.'
        fi ;;
esac
if (( silent )); then exec >/dev/null; fi
[[ -d $destination ]] || die "Download folder does not exist or is not a directory: $destination"
folder=$(cd -- "$destination" && pwd -P)
[[ -w $folder ]] || die "Download folder is not writable: $folder"
run_date=$(date +%y%m%d)
for cmd in curl python3 flock; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
trap 'rc=$?; printf "ERROR: ISO download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
exec 9>"$folder/.$lock_id-download.lock"
flock -n 9 || die "Another $product download is running in: $folder"
work=$(mktemp -d "$folder/.$lock_id-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Source resolvers only select a URL and verification metadata. The shared engine
# below handles every transfer, verification, output name, and retention policy.
python3 - "$work" "$folder" "$product" "$requested" "$edition" "$run_date" "$keep" "$silent" <<'PY_ENGINE'
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


def digest_file(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def managed_history(product, version, edition, name):
    """Only recognize names owned by this product and selected retention group."""
    if product == 'win11':
        return bool(re.fullmatch(r'Win11_\d{2}H[12]_\d{6}\.iso', name))
    if product == 'pfsense':
        return bool(re.fullmatch(r'(?:pfsense|Netgate_Installer_\d+(?:\.\d+)+)_\d{6}\.iso', name))
    if product == 'hbcdpe':
        return bool(re.fullmatch(r'(?:hbcdpe|HBCD_PE_\d+\.\d+\.\d+)_\d{6}\.iso', name))
    if product == 'debian':
        major = re.escape(version.split('.')[0])
        return bool(re.fullmatch(rf'Debian_(?:Netinst_)?{major}(?:\.[0-9]+)+_\d{{6}}\.iso', name))
    if product in ('winserver', 'ubuntu', 'fedora'):
        prefix = {'winserver': 'WinServerEval', 'ubuntu': 'Ubuntu_' + edition.title(),
                  'fedora': 'Fedora_' + edition.title()}[product]
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
    source = work / ('download.iso.gz' if archive else 'download.iso')
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
    if product == 'winserver':
        print('SHA-256 (calculated; no official checksum comparison): ' + sha)
    elif sha != (work / 'sha256').read_text().strip().lower():
        raise RuntimeError('Download SHA-256 does not match the published checksum; existing ISOs preserved.')
    else:
        print('Verified SHA-256: ' + sha)
    if archive:
        print('Decompressing verified archive...')
        extracted = work / 'installer.iso'
        with gzip.open(source, 'rb') as inp, extracted.open('wb') as out:
            shutil.copyfileobj(inp, out, length=8 * 1024 * 1024)
            out.flush()
            os.fsync(out.fileno())
        source = extracted
    with source.open('rb') as inp:
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        os.fsync(inp.fileno())
    prefixes = {'win11': 'Win11', 'winserver': 'WinServerEval',
                'ubuntu': 'Ubuntu_' + edition.title(), 'debian': 'Debian',
                'fedora': 'Fedora_' + edition.title(), 'xcpng': 'XCP-ng',
                'proxmox': 'Proxmox_VE', 'truenas': 'TrueNAS_SCALE'}
    name = (f'{product}_{stamp}.iso' if product in ('pfsense', 'hbcdpe')
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
    print('Verified ISO structure. Saved: ' + str(target))


try:
    work, folder, product, requested, edition, stamp, keep, silent = sys.argv[1:]
    run_download(Path(work), Path(folder), product, requested, edition, stamp, keep == '1', silent == '1')
except Exception as exc:
    sys.exit('ERROR: Could not download, verify, or publish ISO: ' + str(exc))
PY_ENGINE

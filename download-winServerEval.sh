#!/bin/bash
# Download a ready-made Windows Server Evaluation x64 English (US) ISO.
DEFAULT_VERSION="2025"  # Supported: 2022 or 2025. --version overrides this value.
# Official Microsoft redirect URLs; update if Microsoft changes these routes.
SERVER_2022_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US"
SERVER_2025_URL="https://aka.ms/WinServ2025iso-enus"
#
# Usage:
#   ./download-winServerEval.sh [EXISTING_FOLDER] [--version 2022|2025] [--keep-existing] [--silent]
#
# Examples:
#   ./download-winServerEval.sh                        # Default year, current folder
#   ./download-winServerEval.sh /mnt/isos --version 2022
#   ./download-winServerEval.sh --version 2025 --keep-existing
#   ./download-winServerEval.sh . > winServerEval-download.log 2>&1
#   ./download-winServerEval.sh . --silent > winServerEval-errors.log 2>&1
#
# The folder defaults to the current working directory and must already exist.
# Options can appear before or after the folder. Use -- before a folder whose
# name starts with a dash: ./download-winServerEval.sh -- -isos
# --version=2022 is also supported. Other years are rejected without downloading.
#
# Each run resolves Microsoft's redirect afresh and downloads the full ISO without
# prompts, even if a file already exists. No account, PowerShell, or local ISO
# building is required. This is Evaluation media (Standard/Datacenter), not retail
# production media. Setup offers Server Core and Desktop Experience. Microsoft
# documents an evaluation period of 180 days; see the source pages below.
#
# Output: WinServerEval_<year>_<YYMMDD>.iso, using the local run-start date.
# After a successful download, default behavior replaces today's output and removes
# older WinServerEval_<same-year>_<YYMMDD>.iso files. Other Server years and unrelated
# files are preserved. --keep-existing retains all history; if today's exact name
# exists, it retains that file after downloading and validating the new copy.
#
# Progress and status are shown by default, including when redirected to a log.
# --silent (or -s) suppresses progress and success/status output; errors remain on
# stderr and failures exit nonzero. Existing ISOs survive failures before publication.
#
# Validation: HTTPS Microsoft source, expected SERVER_EVAL/x64/English filename,
# exact Content-Length from a fresh HEAD request, and an ISO 9660 volume descriptor.
# If provided by the server, its ETag is used as an If-Match transfer condition.
# SHA-256 is calculated and printed in the log for reference. Microsoft's Evaluation
# download pages do not expose an official checksum to compare; a calculated hash
# alone is NOT independent verification of authenticity or a published checksum.
# The Microsoft evaluation image may be older than current Windows updates.
#
# Dependencies: Bash, curl, Python 3 (standard library only), flock, CA certificates.
# Debian/Ubuntu: sudo apt-get install bash curl python3 util-linux ca-certificates
# Allow space for a full new ISO alongside existing files. Downloads are staged in
# the destination and removed on exit; a forced kill or power failure may leave
# .winServerEval-download.* directories. The persistent .winServerEval-download.lock
# coordinates concurrent runs; a second run targeting the same folder exits nonzero.
#
# Cron: 03:00 on the first day of each month (edit paths; use an absolute folder).
# 0 3 1 * * /bin/bash /path/to/download-winServerEval.sh /mnt/isos --version 2025 >> /path/to/server-eval.log 2>&1
#
# Sources:
# https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
# https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
set -Eeuo pipefail
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin"
export LC_ALL=C
umask 077
exec </dev/null

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "ERROR: Windows Server Evaluation download failed (line %s, status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
keep=0
silent=0
destination=.
path_given=0
options=1
version=$DEFAULT_VERSION
while (( $# )); do
    if (( options )); then
        case $1 in
            --silent|-s) silent=1; shift; continue ;;
            --keep-existing|keep-existing) keep=1; shift; continue ;;
            --version)
                [[ $# -ge 2 && -n $2 && $2 != -* ]] || die '--version requires 2022 or 2025'
                version=$2; shift 2; continue ;;
            --version=*) version=${1#*=}; shift; continue ;;
            --) options=0; shift; continue ;;
            -*) die "Unknown option: $1" ;;
        esac
    fi
    (( path_given == 0 )) || die "Usage: $0 [EXISTING_FOLDER] [--version 2022|2025] [--keep-existing] [--silent]"
    destination=$1
    path_given=1
    shift
done
curl_progress=()
if (( silent )); then
    exec >/dev/null
    curl_progress=(--silent)
fi
case $version in
    2022) source_url=$SERVER_2022_URL ;;
    2025) source_url=$SERVER_2025_URL ;;
    *) die "Unsupported Server version: $version. Choose 2022 or 2025." ;;
esac
[[ -d $destination ]] || die "Download folder does not exist or is not a directory: $destination"
folder=$(cd -- "$destination" && pwd -P)
[[ -w $folder ]] || die "Download folder is not writable: $folder"
run_date=$(date +%y%m%d)
for cmd in curl python3 flock; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
exec 9>"$folder/.winServerEval-download.lock"
flock -n 9 || die "Another Windows Server Evaluation download is running in: $folder"
work=$(mktemp -d "$folder/.winServerEval-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Resolving Microsoft Windows Server %s Evaluation x64 English ISO...\n' "$version"
python3 - "$work" "$source_url" <<'PY_RESOLVE'
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

work, url = Path(sys.argv[1]), sys.argv[2]
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
PY_RESOLVE

url=$(<"$work/url")
etag=$(<"$work/etag")
conditional=()
[[ -z $etag ]] || conditional=(--header "If-Match: $etag")
printf 'Downloading Windows Server %s Evaluation (fresh download on every run)...\n' "$version"
curl --disable "${curl_progress[@]}" --fail --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 10 \
    --connect-timeout 30 --max-time 64800 --speed-limit 1024 --speed-time 300 \
    "${conditional[@]}" --output "$work/download.iso" --write-out '%{url_effective}' "$url" \
    > "$work/final-url" || die 'Windows Server ISO download failed; existing ISOs were preserved.'

printf 'Checking download size and ISO structure; calculating SHA-256...\n'
python3 - "$work" "$folder" "$version" "$run_date" "$keep" <<'PY_PUBLISH'
import hashlib
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit
work, folder, version, stamp, keep = sys.argv[1:]
work, folder = Path(work), Path(folder)
source = work / 'download.iso'
try:
    final = urlsplit((work / 'final-url').read_text().strip())
    if (final.scheme != 'https' or not (final.hostname or '').endswith('.microsoft.com')
        or final.username or final.password):
        raise RuntimeError('Transfer ended at an unexpected download host; existing ISOs preserved.')
    expected = int((work / 'size').read_text())
    actual = source.stat().st_size
    if actual != expected:
        raise RuntimeError(f'Incomplete or changed ISO: expected {expected} bytes, received {actual}; existing ISOs preserved.')
    with source.open('rb') as inp:
        inp.seek(32769)
        if inp.read(5) != b'CD001':
            raise RuntimeError('Downloaded file has no ISO 9660 volume descriptor; existing ISOs preserved.')
        inp.seek(0)
        sha = hashlib.sha256()
        for chunk in iter(lambda: inp.read(8 * 1024 * 1024), b''):
            sha.update(chunk)
        os.fsync(inp.fileno())
    print('Transfer size and ISO structure validated.')
    print('SHA-256 (calculated; no official checksum comparison): ' + sha.hexdigest())
    target = folder / f'WinServerEval_{version}_{stamp}.iso'
    if keep == '1' and os.path.lexists(target):
        print('Fresh download validated; keeping existing file: ' + str(target))
        sys.exit(0)
    os.replace(source, target)
    if keep == '0':
        for old in folder.iterdir():
            if (old != target and re.fullmatch(r'WinServerEval_' + version + r'_\d{6}\.iso', old.name)
                and (old.is_file() or old.is_symlink())):
                old.unlink()
    print('Saved: ' + str(target))
except Exception as exc:
    sys.exit('ERROR: Could not validate or publish Windows Server Evaluation ISO: ' + str(exc))
PY_PUBLISH

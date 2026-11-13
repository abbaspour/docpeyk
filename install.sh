#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

readonly LABEL="io.github.abbaspour.docpeyk"
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly MARKER="# docpeyk (managed by install.sh)"
readonly LOG_FILE="${HOME}/Kindle/docpeyk.log"
DOMAIN="gui/$(id -u)"
readonly DOMAIN

declare scheduler='cron'
[[ "$(uname -s)" == Darwin ]] && scheduler='launchd'

function usage() {
    cat <<END >&2
USAGE: $0 [-s launchd|cron] [-i seconds] [-y] [-n|-u] [-h]
        -s scheduler   # launchd (default on macOS) or cron (default elsewhere)
        -i seconds     # run interval (default 3600); cron needs one that divides an hour or a day
        -y             # install a missing percollate with npm without asking
        -n             # dry run: print the plist or crontab line and exit
        -u             # uninstall the schedule
        -h|?           # usage

Schedules docpeyk.sh to run every interval, logging to ~/Kindle/docpeyk.log:
  launchd: ${PLIST}, which also runs once on wake when a run was missed
  cron:    a crontab line ending in "${MARKER}"
The tools' current PATH is baked into the schedule, so re-run after moving node or percollate.
When percollate is missing it offers to install it with npm (skipping puppeteer's Chrome
download; covers are off by default). It never uses sudo.

eg,
     $0
     $0 -s cron -i 1800
     $0 -u
END
    exit $1
}

function warn() { echo >&2 "WARN: $*"; }

declare -i interval=3600
declare -i opt_dry=0
declare -i opt_uninstall=0
declare -i opt_yes=0

while getopts ":s:i:ynuh?" opt; do
    case ${opt} in
    s) scheduler=${OPTARG} ;;
    i) interval=${OPTARG} ;;
    y) opt_yes=1 ;;
    n) opt_dry=1 ;;
    u) opt_uninstall=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
readonly scheduler interval opt_dry opt_uninstall opt_yes

[[ "${scheduler}" == launchd || "${scheduler}" == cron ]] || { echo >&2 "ERROR: unknown scheduler: ${scheduler}"; usage 1; }
[[ ${interval} -gt 0 ]] || { echo >&2 "ERROR: interval must be a positive number of seconds"; usage 1; }
if [[ "${scheduler}" == launchd ]]; then
    command -v launchctl >/dev/null || { echo >&2 "error: launchctl not found (launchd is macOS only, try -s cron)"; exit 3; }
else
    command -v crontab >/dev/null \
        || { echo >&2 "error: crontab not found: install cron (Debian/Ubuntu: cron, Fedora/Arch: cronie) and start its service"; exit 3; }
fi

# ---- crontab ---------------------------------------------------------------------------
# the user's crontab minus our line (an empty crontab is not an error)
function crontab_without_ours() { { crontab -l 2>/dev/null || true; } | { grep -vF -- "${MARKER}" || true; }; }

# crontab_install [line]: the user's other lines plus line, read in full before `crontab -` writes
function crontab_install() {
    local others
    others=$(crontab_without_ours)
    { [[ -z "${others}" ]] || printf '%s\n' "${others}"; [[ -z "${1:-}" ]] || printf '%s\n' "$1"; } | crontab -
}

# cron_when <seconds>  -> the five schedule fields; fails unless the interval divides an hour or a day
function cron_when() {
    local -i minutes=$(($1 / 60)) hours minute=$((RANDOM % 59 + 1))
    [[ $(($1 % 60)) -eq 0 && ${minutes} -gt 0 ]] || return 1
    if [[ ${minutes} -lt 60 ]]; then
        [[ $((60 % minutes)) -eq 0 ]] || return 1
        if [[ ${minutes} -eq 1 ]]; then echo '* * * * *'; else echo "*/${minutes} * * * *"; fi
        return 0
    fi
    hours=$((minutes / 60))
    [[ $((minutes % 60)) -eq 0 && $((24 % hours)) -eq 0 ]] || return 1
    # a random minute, so installs don't all fire at :00
    if [[ ${hours} -eq 1 ]]; then echo "${minute} * * * *"; else echo "${minute} */${hours} * * *"; fi
}

if [[ ${opt_uninstall} -eq 1 ]]; then
    if [[ "${scheduler}" == launchd ]]; then
        launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
        rm -f "${PLIST}"
        echo "uninstalled ${LABEL} (data in ~/Kindle is untouched)"
    else
        crontab_install
        echo "removed the docpeyk crontab line (data in ~/Kindle is untouched)"
    fi
    exit 0
fi

script=$(cd "${DIR}" && pwd)/docpeyk.sh
readonly script
[[ -x "${script}" ]] || { echo >&2 "ERROR: ${script} missing or not executable"; exit 1; }

# ---- dependencies ----------------------------------------------------------------------
# pkg_hint <tool>  -> how to install it here
function pkg_hint() {
    case "$1" in
    percollate) echo "PUPPETEER_SKIP_DOWNLOAD=1 npm install -g percollate"; return 0 ;;
    node) echo "Node >= 14.17, e.g. with https://github.com/nvm-sh/nvm"; return 0 ;;
    magick)
        if command -v brew >/dev/null; then echo "brew install imagemagick"
        elif command -v dnf >/dev/null; then echo "sudo dnf install ImageMagick"
        elif command -v pacman >/dev/null; then echo "sudo pacman -S imagemagick"
        else echo "ImageMagick 7 (the magick command), see https://imagemagick.org/script/download.php"; fi
        return 0 ;;
    rsvg-convert)
        if command -v brew >/dev/null; then echo "brew install librsvg"
        elif command -v apt-get >/dev/null; then echo "sudo apt-get install librsvg2-bin"
        elif command -v dnf >/dev/null; then echo "sudo dnf install librsvg2-tools"
        elif command -v pacman >/dev/null; then echo "sudo pacman -S librsvg"
        else echo "librsvg (the rsvg-convert command) from your package manager"; fi
        return 0 ;;
    yq)
        if command -v brew >/dev/null; then echo "brew install yq"
        else echo "a binary from https://github.com/mikefarah/yq/releases (not your distro's Python yq)"; fi
        return 0 ;;
    esac
    if command -v brew >/dev/null; then echo "brew install $1"
    elif command -v apt-get >/dev/null; then echo "sudo apt-get install $1"
    elif command -v dnf >/dev/null; then echo "sudo dnf install $1"
    elif command -v pacman >/dev/null; then echo "sudo pacman -S $1"
    elif command -v zypper >/dev/null; then echo "sudo zypper install $1"
    elif command -v apk >/dev/null; then echo "sudo apk add $1"
    else echo "your package manager"; fi
}

function node_version_ok() {
    local v major minor
    v=$(node -p 'process.versions.node' 2>/dev/null) || return 1
    major=${v%%.*}
    minor=${v#*.}
    minor=${minor%%.*}
    [[ ${major} -gt 14 || (${major} -eq 14 && ${minor} -ge 17) ]]
}

# install_percollate: npm install -g, after asking (or -y); never with sudo
function install_percollate() {
    local prefix target answer
    command -v npm >/dev/null || { warn "percollate needs Node >= 14.17 and npm; install them (e.g. with https://github.com/nvm-sh/nvm) and re-run"; return 1; }
    node_version_ok || { warn "percollate needs Node >= 14.17, found $(node --version 2>/dev/null || echo none)"; return 1; }
    prefix=$(npm prefix -g)
    # npm creates what's missing, so check the nearest folder that exists
    target="${prefix}/lib/node_modules"
    while [[ ! -e "${target}" && "${target}" == */* ]]; do target="${target%/*}"; done
    if [[ ! -w "${target:-/}" ]]; then
        warn "npm installs global packages into ${prefix}, which isn't writable for you. Either point npm"
        warn "  at your home folder: npm config set prefix ~/.local  (and put ~/.local/bin on PATH)"
        warn "  or install it yourself: sudo PUPPETEER_SKIP_DOWNLOAD=1 npm install -g percollate"
        warn "  then re-run $0"
        return 1
    fi
    if [[ ${opt_yes} -eq 0 ]]; then
        if [[ ! -t 0 ]]; then
            warn "percollate not found: re-run with -y to install it with npm, or: $(pkg_hint percollate)"
            return 1
        fi
        read -r -p "percollate is not installed. Install it with npm into ${prefix}? [y/N] " answer
        [[ "${answer}" =~ ^[Yy] ]] || { warn "skipped; install it later with: $(pkg_hint percollate)"; return 1; }
    fi
    echo "installing percollate with npm (without puppeteer's Chrome; covers are off by default)"
    PUPPETEER_SKIP_DOWNLOAD=1 PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 npm install -g percollate
    [[ -x "${prefix}/bin/percollate" ]] || { warn "npm finished, but ${prefix}/bin/percollate is missing"; return 1; }
    PATH="${prefix}/bin:${PATH}"
}

if ! command -v percollate >/dev/null && [[ ${opt_dry} -eq 0 ]]; then
    install_percollate || true
fi

# launchd and cron start jobs with a bare PATH: bake in wherever the tools live now
# (percollate under nvm/npm, msmtp/yq/magick under Homebrew)
declare -a dirs=()
for tool in percollate node msmtp yq jq perl curl openssl unzip zip magick; do
    if p=$(command -v "${tool}"); then
        dirs+=("$(dirname "${p}")")
    else
        warn "${tool} not found on PATH; install it before the first run: $(pkg_hint "${tool}")"
    fi
done
# optional: renders SVG diagrams for Kindle
if p=$(command -v rsvg-convert); then
    dirs+=("$(dirname "${p}")")
else
    warn "rsvg-convert not found (optional, for SVG diagrams in books): $(pkg_hint rsvg-convert)"
fi
if command -v yq >/dev/null && [[ "$(yq --version 2>&1)" != *mikefarah* ]]; then
    warn "$(command -v yq) is not mikefarah/yq; docpeyk.sh needs $(pkg_hint yq)"
fi
command -v node >/dev/null && ! node_version_ok && warn "percollate needs Node >= 14.17, found $(node --version)"
dirs+=(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)
job_path=$(printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++' | paste -sd: -)
readonly job_path

# ---- launchd ---------------------------------------------------------------------------
if [[ "${scheduler}" == launchd ]]; then
    plist=$(cat <<EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${job_path}</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>
    <!-- docpeyk.sh writes its own log lines here; these catch tool output and crashes. -->
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
EOL
)
    readonly plist

    if [[ ${opt_dry} -eq 1 ]]; then
        echo "${plist}"
        exit 0
    fi

    mkdir -p "${LOG_FILE%/*}" "${PLIST%/*}"
    echo "${plist}" > "${PLIST}"
    plutil -lint "${PLIST}" >/dev/null
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "${DOMAIN}" "${PLIST}"

    echo "installed ${PLIST}"
    echo "  run now:  launchctl kickstart ${DOMAIN}/${LABEL}"
    echo "  logs:     tail -f ~/Kindle/docpeyk.log"
    echo "  check:    ${script} -D"
    exit 0
fi

# ---- cron ------------------------------------------------------------------------------
when=$(cron_when "${interval}") \
    || { echo >&2 "ERROR: cron can't run every ${interval} s; use a number of minutes that divides an hour, or hours that divide a day"; exit 1; }
readonly when
# cron runs the line with /bin/sh, and % is special in crontabs; keep the quoting simple
for v in "${job_path}" "${script}" "${LOG_FILE}"; do
    [[ "${v}" != *[\'%]* ]] || { echo >&2 "ERROR: can't put a path containing ' or % in a crontab: ${v}"; exit 1; }
done
line="${when} PATH='${job_path}' LANG='${LANG:-C.UTF-8}' '${script}' >> '${LOG_FILE}' 2>&1 ${MARKER}"
readonly line

if [[ ${opt_dry} -eq 1 ]]; then
    echo "${line}"
    exit 0
fi

mkdir -p "${LOG_FILE%/*}"
crontab_install "${line}"

echo "installed crontab line (${when}):"
echo "  ${line}"
echo "  run now:  ${script}"
echo "  logs:     tail -f ~/Kindle/docpeyk.log"
echo "  check:    ${script} -D"

#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

readonly LABEL="local.docpeyk"
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly DOMAIN="gui/$(id -u)"

function usage() {
    cat <<END >&2
USAGE: $0 [-i seconds] [-n|-u] [-h]
        -i seconds     # run interval (default 3600)
        -n             # dry run: print the generated plist and exit
        -u             # uninstall the LaunchAgent
        -h|?           # usage

Installs ${PLIST}, which runs docpeyk.sh every interval and once when
missed while asleep (launchd coalesces missed runs and fires on wake).

eg,
     $0
     $0 -u
END
    exit $1
}

declare -i interval=3600
declare -i opt_dry=0
declare -i opt_uninstall=0

while getopts ":i:nuh?" opt; do
    case ${opt} in
    i) interval=${OPTARG} ;;
    n) opt_dry=1 ;;
    u) opt_uninstall=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done

if [[ ${opt_uninstall} -eq 1 ]]; then
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST}"
    echo "uninstalled ${LABEL} (data in ~/Kindle is untouched)"
    exit 0
fi

script=$(cd "${DIR}" && pwd)/docpeyk.sh
readonly script
[[ -x "${script}" ]] || { echo >&2 "ERROR: ${script} missing or not executable"; exit 1; }

# launchd starts jobs with a bare PATH: bake in wherever the tools live now
# (percollate under nvm/npm, msmtp/yq under Homebrew)
declare -a dirs=()
for tool in percollate node msmtp yq jq perl; do
    if p=$(command -v "${tool}"); then
        dirs+=("$(dirname "${p}")")
    else
        echo >&2 "WARN: ${tool} not found on PATH; install it before the first run"
    fi
done
dirs+=(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)
job_path=$(printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++' | paste -sd: -)
readonly job_path

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
    <key>StandardOutPath</key>
    <string>${HOME}/Kindle/docpeyk.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Kindle/docpeyk.log</string>
</dict>
</plist>
EOL
)
readonly plist

if [[ ${opt_dry} -eq 1 ]]; then
    echo "${plist}"
    exit 0
fi

mkdir -p "${HOME}/Kindle" "${PLIST%/*}"
echo "${plist}" > "${PLIST}"
plutil -lint "${PLIST}" >/dev/null
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "${PLIST}"

echo "installed ${PLIST}"
echo "  run now:  launchctl kickstart ${DOMAIN}/${LABEL}"
echo "  logs:     tail -f ~/Kindle/docpeyk.log"

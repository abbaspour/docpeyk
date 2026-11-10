#!/usr/bin/env bash

set -ueo pipefail

#DIR="${BASH_SOURCE[0]%/*}"
#[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
#readonly DIR

readonly VERSION="0.1.0"

function usage() {
    cat <<END >&2
USAGE: $0 [-d dir] [-f slug] [-C|-S] [-v|-V|-h]
       $0 [-d dir] [-a author] [-C] [-v] URL...
       $0 [-d dir] -D|-R
        -d dir         # data directory (default ~/Kindle)
        -f slug        # only process the feed with this slug
        -a author      # author for ad-hoc URLs (default: the page's byline)
        -C             # convert only, don't send
        -S             # send only, don't fetch/convert
        -D             # doctor: check tools, settings, feeds, mail and schedule, then exit
        -R             # print the daily summary that would be mailed now, then exit
        -V             # print version
        -h|?           # usage
        -v             # verbose

Without URLs: reads <dir>/feeds.csv (feed_url,author,slug), converts every unseen
post to <dir>/<slug>/outbox/*.epub and mails up to MAX_SENDS_PER_RUN files from outbox/
to Kindle, moving sent files to <dir>/<slug>/sent/.
With URLs: converts each page to <dir>/adhoc/outbox/ and sends it right away.
With SUMMARY_TO set, the first scheduled run after SUMMARY_HOUR each day mails it a summary:
posts sent per feed since the last summary, and how many are still queued.
Settings live in <dir>/kindle.conf.

eg,
     $0
     $0 -f jvns -C
     $0 https://example.com/some-post/
     $0 -a "Paul Graham" https://paulgraham.com/greatwork.html
     $0 -D
     $0 -R
END
    exit $1
}

# log lines go to ${LOG_FILE} and, unless stderr already is that file (launchd/cron), to stderr
declare -i log_echo=1
function log() {
    local line
    line="$(date '+%F %T') $*"
    printf '%s\n' "${line}" >> "${LOG_FILE}"
    [[ ${log_echo} -eq 0 ]] || printf '%s\n' "${line}" >&2
}
function vlog() { [[ ${opt_verbose} -eq 1 ]] && log "$@"; return 0; }

declare ROOT="${HOME}/Kindle"
declare only_slug=''
declare adhoc_author=''
declare -i opt_convert=1
declare -i opt_send=1
declare -i opt_verbose=0
declare -i opt_doctor=0
declare -i opt_report=0

while getopts ":d:f:a:CSDRVhv?" opt; do
    case ${opt} in
    d) ROOT=${OPTARG} ;;
    f) only_slug=${OPTARG} ;;
    a) adhoc_author=${OPTARG} ;;
    C) opt_send=0 ;;
    S) opt_convert=0 ;;
    D) opt_doctor=1 ;;
    R) opt_report=1 ;;
    V) echo "docpeyk ${VERSION}"; exit 0 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))
declare -a adhoc_urls=("$@")
readonly ROOT only_slug adhoc_author opt_convert opt_send opt_verbose opt_doctor opt_report adhoc_urls

for u in ${adhoc_urls[@]+"${adhoc_urls[@]}"}; do
    [[ "${u}" =~ ^https?:// ]] || { echo >&2 "ERROR: not an http(s) URL: ${u}"; usage 1; }
done
[[ ${#adhoc_urls[@]} -gt 0 && ${opt_convert} -eq 0 ]] && { echo >&2 "ERROR: -S can't be combined with URLs"; usage 1; }
[[ ${#adhoc_urls[@]} -gt 0 && ${opt_doctor} -eq 1 ]] && { echo >&2 "ERROR: -D can't be combined with URLs"; usage 1; }
[[ ${#adhoc_urls[@]} -gt 0 && ${opt_report} -eq 1 ]] && { echo >&2 "ERROR: -R can't be combined with URLs"; usage 1; }

readonly FEEDS="${ROOT}/feeds.csv"
readonly CONF="${ROOT}/kindle.conf"
readonly LOCK="${ROOT}/.lock"
readonly LOG_FILE="${ROOT}/docpeyk.log"
readonly SUMMARY_STAMP="${ROOT}/.summary"
readonly ADHOC="adhoc"
readonly USER_AGENT="docpeyk/${VERSION} (+https://github.com/abbaspour/docpeyk)"

# ---- bootstrap data directory ----------------------------------------------------------
mkdir -p "${ROOT}"
touch "${LOG_FILE}"
# same device and inode as the open stderr? (bash's -ef can't see through /dev/stderr on macOS)
perl -e 'my @e = stat STDERR; my @f = stat shift; exit !(@e && @f && $e[0] == $f[0] && $e[1] == $f[1])' \
    "${LOG_FILE}" && log_echo=0
readonly log_echo
[[ -f "${FEEDS}" ]] || cat > "${FEEDS}" <<'EOL'
# feed_url,author,slug  -- one feed per line, no commas inside fields, '#' lines are ignored
# https://jvns.ca/atom.xml,Julia Evans,jvns
EOL
[[ -f "${CONF}" ]] || cat > "${CONF}" <<'EOL'
# docpeyk settings (sourced by bash)
KINDLE_TO=""            # your Send-to-Kindle address, e.g. name_abc@kindle.com
MSMTP_ACCOUNT="default" # account in ~/.msmtprc (its 'from' must be approved in Amazon)
SEND_DELAY=30           # seconds to wait between emails
MAX_SENDS_PER_RUN=5     # emails per scheduled run; the rest wait for the next run
MAX_ATTEMPTS=3          # give up converting a post after this many failures
MAX_POSTS_PER_FEED=10   # only the newest posts of each feed are converted; 0 means all
SUMMARY_TO=""           # your own address for a daily summary of what was sent; empty means off
SUMMARY_HOUR=8          # the summary goes out with the first run at or after this hour (0-23)
# extra percollate flags; covers are rendered with headless Chrome, so they are off by default
# (to enable: npx puppeteer browsers install chrome, then set PERCOLLATE_ARGS=())
PERCOLLATE_ARGS=(--no-cover)
EOL

declare KINDLE_TO=''
declare MSMTP_ACCOUNT='default'
declare -i SEND_DELAY=30
declare -i MAX_SENDS_PER_RUN=5
declare -i MAX_ATTEMPTS=3
declare -i MAX_POSTS_PER_FEED=10
declare SUMMARY_TO=''
declare -i SUMMARY_HOUR=8
declare -a PERCOLLATE_ARGS=(--no-cover)
# shellcheck source=/dev/null
. "${CONF}"

# ---- checks shared by runs and the doctor ----------------------------------------------
# where install.sh schedules us; keep in sync with install.sh
readonly LABEL="io.github.abbaspour.docpeyk"
readonly MARKER="# docpeyk (managed by install.sh)"

# dependency_problems  -> one line per missing or unusable tool this run needs
function dependency_problems() {
    local tool
    for tool in curl jq yq perl openssl unzip; do
        command -v "${tool}" >/dev/null || echo "${tool} not found"
    done
    # Debian, Ubuntu and Arch package a different, Python-based tool as "yq" that can't read XML like this
    if command -v yq >/dev/null && [[ "$(yq --version 2>&1)" != *mikefarah* ]]; then
        echo "yq is not mikefarah/yq, install it from https://github.com/mikefarah/yq"
    fi
    # core perl, but packaged separately on some distros (Fedora/RHEL: perl-Unicode-Normalize)
    if command -v perl >/dev/null && ! perl -MUnicode::Normalize -e 1 2>/dev/null; then
        echo "perl module Unicode::Normalize not found"
    fi
    if [[ ${opt_convert} -eq 1 ]] && ! command -v percollate >/dev/null; then echo "percollate not found"; fi
    if [[ ${opt_send} -eq 1 ]] && ! command -v msmtp >/dev/null; then echo "msmtp not found"; fi
    return 0
}

# percollate's requirement
function node_version_ok() {
    local v major minor
    v=$(node -p 'process.versions.node' 2>/dev/null) || return 1
    major=${v%%.*}
    minor=${v#*.}
    minor=${minor%%.*}
    [[ ${major} -gt 14 || (${major} -eq 14 && ${minor} -ge 17) ]]
}

# is there a route out? local checks only: macOS scutil, else Linux iproute2, else assume yes
function network_up() {
    if command -v scutil >/dev/null; then
        [[ "$(scutil -r 1.1.1.1 2>/dev/null)" == Reachable* ]]
    elif command -v ip >/dev/null; then
        ip route get 1.1.1.1 >/dev/null 2>&1
    fi
}

function trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# read_feeds <reporter>  -> "url <US> author <US> slug" for each valid feeds.csv line;
# <reporter> (a command) gets one message per invalid line
function read_feeds() {
    local f_url f_author f_slug f_extra
    local -i lineno=0
    while IFS=, read -r f_url f_author f_slug f_extra || [[ -n "${f_url}" ]]; do
        lineno+=1
        f_url=$(trim "${f_url}")
        [[ -z "${f_url}" || "${f_url}" == \#* ]] && continue
        f_author=$(trim "${f_author:-}")
        f_slug=$(trim "${f_slug:-}")
        if [[ -n "${f_extra:-}" || -z "${f_author}" || ! "${f_slug}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            "$1" "feeds.csv:${lineno}: expected 'feed_url,author,slug', skipping"
            continue
        fi
        printf '%s\x1f%s\x1f%s\n' "${f_url}" "${f_author}" "${f_slug}"
    done < "${FEEDS}"
}

# ---- daily summary ---------------------------------------------------------------------
# A summary covers the posts sent since the previous one: ${SUMMARY_STAMP} holds the day it was
# mailed and its mtime is the end of the window it covered. The first one covers the last 24 hours.

function summary_hour_ok() { [[ ${SUMMARY_HOUR} -ge 0 && ${SUMMARY_HOUR} -le 23 ]]; }

# summary_due  -> is a summary wanted now and not mailed yet today?
function summary_due() {
    [[ -n "${SUMMARY_TO}" ]] || return 1
    summary_hour_ok || { log "SUMMARY_HOUR=${SUMMARY_HOUR} is not an hour (0-23), no summary"; return 1; }
    [[ $((10#$(date +%H))) -ge ${SUMMARY_HOUR} ]] || return 1
    [[ "$(cat "${SUMMARY_STAMP}" 2>/dev/null)" != "$(date +%F)" ]]
}

# summary_window <dir>  -> <dir>/summary.start and <dir>/summary.now, whose mtimes bound the window.
# The end is taken before counting, so a send that lands meanwhile falls in the next window.
function summary_window() {
    if [[ -f "${SUMMARY_STAMP}" ]]; then
        cp -p "${SUMMARY_STAMP}" "$1/summary.start"
    else
        : > "$1/summary.start"
        perl -e '$t = time - 86400; utime $t, $t, shift' "$1/summary.start"
    fi
    : > "$1/summary.now"
}

# count_epubs <dir> [find tests...]  -> number of matching *.epub files in <dir>
function count_epubs() {
    [[ -d "$1" ]] || { echo 0; return 0; }
    find "$1" -name '*.epub' "${@:2}" | wc -l | tr -d ' '
}

declare -i summary_sent=0 summary_queued=0

# summary_report <start> <end>  -> the summary text: per feed, posts sent between the mtimes of
# <start> and <end> and posts still in the outbox. Totals are left in summary_sent/summary_queued.
function summary_report() {
    local start="$1" end="$2" f_url f_author f_slug
    local -i sent queued
    summary_sent=0
    summary_queued=0
    printf 'docpeyk summary since %s\n\n' \
        "$(perl -MPOSIX -e 'print strftime("%Y-%m-%d %H:%M", localtime((stat shift)[9]))' "${start}")"
    printf '%6s %7s  %s\n' sent queued feed
    # invalid feeds.csv lines are already logged by the run
    while IFS=$'\x1f' read -r f_url f_author f_slug; do
        [[ -n "${f_slug}" ]] || continue
        sent=$(count_epubs "${ROOT}/${f_slug}/sent" -newer "${start}" ! -newer "${end}")
        queued=$(count_epubs "${ROOT}/${f_slug}/outbox")
        # ad-hoc pages only get a row when there was something to send
        [[ "${f_url}" == - && ${sent} -eq 0 && ${queued} -eq 0 ]] && continue
        printf '%6d %7d  %s\n' "${sent}" "${queued}" "${f_author} (${f_slug})"
        summary_sent+=sent
        summary_queued+=queued
    done < <(read_feeds true; printf -- '-\x1fad-hoc pages\x1f%s\n' "${ADHOC}")
    printf '%6d %7d  %s\n' "${summary_sent}" "${summary_queued}" total
}

# ---- doctor ----------------------------------------------------------------------------
declare -i doctor_fails=0

# report <ok|warn|FAIL> <message...>
function report() {
    printf '%-5s %s\n' "$1" "${*:2}"
    if [[ "$1" == FAIL ]]; then doctor_fails+=1; fi
    return 0
}
# warnings from inside $(...), sent to the doctor's stdout on fd 3
function report_warn_fd3() { report warn "$@" >&3; }

function doctor() {
    local problems line cfg host from feeds dupes
    local -i scheduled=0
    echo "docpeyk ${VERSION}, data in ${ROOT}"

    problems=$(dependency_problems)
    if [[ -z "${problems}" ]]; then
        report ok "tools: curl jq yq perl openssl unzip percollate msmtp"
    else
        while IFS= read -r line; do report FAIL "${line}"; done <<< "${problems}"
    fi
    if command -v percollate >/dev/null; then
        if ! command -v node >/dev/null; then report FAIL "node not found; percollate needs Node >= 14.17"
        elif ! node_version_ok; then report FAIL "percollate needs Node >= 14.17, found $(node --version)"
        else report ok "node $(node --version) for $(command -v percollate)"; fi
    fi

    if [[ -z "${KINDLE_TO}" ]]; then
        report FAIL "KINDLE_TO is not set in ${CONF}"
    elif [[ "${KINDLE_TO}" =~ @(free\.)?kindle\.(com|cn)$ ]]; then
        report ok "KINDLE_TO ${KINDLE_TO}"
    else
        report warn "KINDLE_TO ${KINDLE_TO} doesn't look like a Send to Kindle address (...@kindle.com)"
    fi

    if ! summary_hour_ok; then
        report FAIL "SUMMARY_HOUR=${SUMMARY_HOUR} is not an hour (0-23)"
    elif [[ -z "${SUMMARY_TO}" ]]; then
        report ok "daily summary off (set SUMMARY_TO in ${CONF} to get one)"
    elif [[ "${SUMMARY_TO}" =~ @(free\.)?kindle\.(com|cn)$ ]]; then
        report warn "SUMMARY_TO ${SUMMARY_TO} is a Kindle address; the summary is meant for your own mailbox"
    else
        report ok "daily summary to ${SUMMARY_TO} after $(printf '%02d' "${SUMMARY_HOUR}"):00"
    fi

    if command -v msmtp >/dev/null; then
        # only host and from are read; the rest of this output can hold credentials.
        # On failure msmtp prints just its error (unknown account, config readable by others, ...)
        if ! cfg=$(msmtp -P -a "${MSMTP_ACCOUNT}" </dev/null 2>&1); then
            report FAIL "$(grep -m1 '^msmtp: ' <<< "${cfg}" || echo "msmtp can't use account '${MSMTP_ACCOUNT}' (MSMTP_ACCOUNT)")"
        else
            host=$(sed -n 's/^host = //p' <<< "${cfg}")
            from=$(sed -n 's/^from = //p' <<< "${cfg}")
            if [[ -n "${from}" ]]; then
                report ok "msmtp account ${MSMTP_ACCOUNT}: host ${host:-?}, from ${from}"
                report ok "  (${from} must be on Amazon's Approved Personal Document E-mail List)"
            else
                report warn "msmtp account ${MSMTP_ACCOUNT} has no 'from'; set it to an address Amazon approves"
            fi
            if ! network_up; then
                report warn "no network: SMTP server not checked"
            elif msmtp -S -a "${MSMTP_ACCOUNT}" </dev/null >/dev/null 2>&1; then
                report ok "SMTP server ${host:-?} answers"
            else
                report FAIL "SMTP server ${host:-?} doesn't answer; details: msmtp -S -a ${MSMTP_ACCOUNT}"
            fi
        fi
    fi

    { feeds=$(read_feeds report_warn_fd3); } 3>&1
    if [[ -z "${feeds}" ]]; then
        report warn "no feeds in ${FEEDS} yet; findfeed.sh -c <blog url> >> ${FEEDS} adds one"
    else
        report ok "feeds.csv: $(grep -c . <<< "${feeds}") feed(s)"
        dupes=$(cut -d $'\x1f' -f3 <<< "${feeds}" | sort | uniq -d | paste -sd, -)
        [[ -z "${dupes}" ]] || report warn "feeds.csv: slug used more than once: ${dupes}"
        if cut -d $'\x1f' -f3 <<< "${feeds}" | grep -qx "${ADHOC}"; then
            report warn "feeds.csv: '${ADHOC}' is reserved for ad-hoc pages; pick another slug"
        fi
    fi

    if command -v launchctl >/dev/null && launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
        report ok "scheduled with launchd (${LABEL})"
        scheduled=1
    fi
    if command -v crontab >/dev/null && [[ "$(crontab -l 2>/dev/null)" == *"${MARKER}"* ]]; then
        report ok "scheduled with cron"
        scheduled=1
    fi
    [[ ${scheduled} -eq 1 ]] || report warn "not scheduled; install.sh sets up launchd (macOS) or cron"

    echo
    if [[ ${doctor_fails} -eq 0 ]]; then
        echo "all good. Send any page to test delivery end to end: $0 <url>"
    else
        echo "${doctor_fails} problem(s) to fix"
    fi
    [[ ${doctor_fails} -eq 0 ]]
}

if [[ ${opt_doctor} -eq 1 ]]; then
    doctor && exit 0
    exit 1
fi

if [[ ${opt_report} -eq 1 ]]; then
    report_dir=$(mktemp -d "${TMPDIR:-/tmp}/docpeyk.XXXXXX")
    summary_window "${report_dir}"
    summary_report "${report_dir}/summary.start" "${report_dir}/summary.now"
    rm -rf "${report_dir}"
    exit 0
fi

problems=$(dependency_problems)
readonly problems
[[ -z "${problems}" ]] || { sed 's/^/error: /' <<< "${problems}" >&2; exit 3; }

# ---- locking ---------------------------------------------------------------------------
# take_lock <dir>: mkdir-based lock holding our pid; clears locks left behind by dead processes
function take_lock() {
    if ! mkdir "$1" 2>/dev/null; then
        kill -0 "$(cat "$1/pid" 2>/dev/null)" 2>/dev/null && return 1
        rm -rf "$1"
        mkdir "$1" 2>/dev/null || return 1
    fi
    echo $$ > "$1/pid"
}

declare -a held_locks=()
work=$(mktemp -d "${TMPDIR:-/tmp}/docpeyk.XXXXXX")
readonly work
trap 'rm -rf ${held_locks[@]+"${held_locks[@]}"} "${work}"' EXIT

# ad-hoc runs skip the global lock so they never wait behind a long scheduled run;
# sending is serialised per folder in send_outbox instead
if [[ ${#adhoc_urls[@]} -eq 0 ]]; then
    if ! take_lock "${LOCK}"; then
        log "another run is in progress (pid $(cat "${LOCK}/pid")), exiting"
        exit 0
    fi
    held_locks+=("${LOCK}")
fi

# after waking from sleep the network can take a while to come back
function wait_for_network() {
    local -i i
    for ((i = 0; i < 12; i++)); do
        network_up && return 0
        sleep 5
    done
    return 1
}

# "Café: Über Title!" -> "cafe-uber-title"  (empty for titles with no latin letters/digits)
function slugify() {
    perl -CSA -MUnicode::Normalize -e '$_ = NFD(shift); s/\p{Mn}|['"'"'\x{2019}]//g; $_ = lc;
        s/[^a-z0-9]+/-/g; s/^-+//; $_ = substr($_, 0, 80); s/-+$//; print' "$1"
}

# first 8 hex digits of the SHA-1; awk takes the last field of both OpenSSL and LibreSSL output
function short_hash() { printf '%s' "$1" | openssl dgst -sha1 | awk '{ print substr($NF, 1, 8) }'; }

# percollate exits 0 even when it couldn't fetch the page, leaving an EPUB with only nav.xhtml
function has_article() { unzip -Z1 "$1" 2>/dev/null | awk '/^OEBPS\/.*\.xhtml$/ && !/\/nav\.xhtml$/ { f = 1 } END { exit !f }'; }

# opf_field <epub> <dc element>  -> value of e.g. <dc:title> from the package document
function opf_field() {
    { unzip -p "$1" '*.opf' 2>/dev/null || true; } | tr '\n' ' ' \
        | sed -n "s|.*<dc:$2[^>]*>\([^<]*\)</dc:$2>.*|\1|p" \
        | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e "s/&#39;/'/g" -e 's/&amp;/\&/g'
}

# ---- feed parsing ----------------------------------------------------------------------
# jq program that normalises RSS 2.0, RSS 1.0 (RDF) and Atom feeds (as JSON from
# `yq -p xml -o json`) into one line per post:  id <US> link <US> title <US> YYYY-MM-DD
# where <US> is the ASCII unit separator (\u001f).
# Kept in a function rather than $(cat <<...) so bash 3.2 doesn't trip over its quotes.
function feed_items_jq() {
    cat <<'EOL'
def arr: if . == null then [] elif type == "array" then . else [.] end;

# element text: yq yields a plain string, or an object with "+content" when the element has attributes
def txt: if type == "object" then (.["+content"] // "") elif . == null then "" else tostring end;

def unhtml:
  gsub("<[^>]*>"; "")
  | gsub("&#(?<n>[0-9]+);"; [.n | tonumber] | implode)
  | gsub("&#x(?<n>[0-9a-fA-F]+);"; ([.n | ascii_downcase | explode[] | if . >= 97 then . - 87 else . - 48 end]
                                     | reduce .[] as $d (0; . * 16 + $d)) as $c | [$c] | implode)
  | gsub("&quot;"; "\"") | gsub("&apos;"; "'") | gsub("&lt;"; "<") | gsub("&gt;"; ">")
  | gsub("&nbsp;"; " ") | gsub("&amp;"; "&");

def clean: gsub("[\\s\u001f]+"; " ") | ltrimstr(" ") | rtrimstr(" ");

# RFC 822 ("Mon, 02 Jan 2006 ...") or ISO 8601 ("2006-01-02T...") -> "2006-01-02"; "" if unknown
def ymd:
  if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") then .[0:10]
  else ([capture("(?<d>[0-9]{1,2})\\s+(?<m>[A-Za-z]{3})[A-Za-z]*\\.?\\s+(?<y>[0-9]{4})")][0]) as $c
    | ({"jan":"01","feb":"02","mar":"03","apr":"04","may":"05","jun":"06",
        "jul":"07","aug":"08","sep":"09","oct":"10","nov":"11","dec":"12"}[$c.m // "" | ascii_downcase]) as $m
    | if $c and $m then "\($c.y)-\($m)-\($c.d | if length == 1 then "0" + . else . end)" else "" end
  end;

# Atom <link href=".."/>: prefer rel="alternate" (or no rel), else the first one
def atomlink: arr | (map(select(type == "object" and (.["+@rel"] == null or .["+@rel"] == "alternate")))[0]["+@href"])
                    // (.[0] | if type == "object" then .["+@href"] else txt end) // "";

(
  (.rss.channel.item | arr | .[]
    | {id: (.guid | txt), link: (.link | arr | .[0] | txt), title: (.title | txt), date: ((.pubDate // .["dc:date"]) | txt)}),
  (.feed.entry | arr | .[]
    | {id: (.id | txt), link: (.link | atomlink), title: (.title | txt), date: ((.published // .updated) | txt)}),
  (.["rdf:RDF"].item | arr | .[]
    | {id: (.["+@rdf:about"] // "" | txt), link: (.link | txt), title: (.title | txt), date: (.["dc:date"] | txt)})
)
| .link |= clean
| select(.link | test("^https?://"))
| .id = ((.id | clean) as $i | if $i == "" then .link else $i end)
| .title = (.title | unhtml | clean | if . == "" then "Untitled" else . end)
| [.id, .link, .title, (.date | clean | ymd)]
| join("\u001f")
EOL
}

# ---- convert ---------------------------------------------------------------------------
# convert_url <url> <title> <author> <YYYY-MM-DD> <folder>  -> path of the new epub on stdout
# empty title/author let percollate take them from the page; empty date means today
function convert_url() {
    local link="$1" title="$2" author="$3" day="$4" base="$5"
    local tag="[${base##*/}]" tmp_epub="${work}/convert.epub" name out
    local -a meta=()
    [[ -n "${title}" ]] && meta+=(--title "${title}")
    [[ -n "${author}" ]] && meta+=(--author "${author}")

    log "${tag} converting: ${title:+${title} }<${link}>"
    rm -f "${tmp_epub}"
    if ! percollate epub ${PERCOLLATE_ARGS[@]+"${PERCOLLATE_ARGS[@]}"} ${meta[@]+"${meta[@]}"} \
            -o "${tmp_epub}" "${link}" </dev/null >"${work}/percollate.log" 2>&1 \
        || ! has_article "${tmp_epub}"; then
        { grep -v '^ *at ' "${work}/percollate.log" || true; } | head -10 \
            | while IFS= read -r line; do log "    ${line}"; done
        return 1
    fi

    if [[ -n "${title}" ]]; then
        [[ "$(opf_field "${tmp_epub}" title)" == "${title}" ]] || log "${tag} WARN: dc:title mismatch for ${link}"
    else
        title=$(opf_field "${tmp_epub}" title)
        log "${tag} title: ${title}"
    fi
    if [[ -n "${author}" ]]; then
        [[ "$(opf_field "${tmp_epub}" creator)" == "${author}" ]] || log "${tag} WARN: dc:creator mismatch for ${link}"
    fi

    [[ -n "${day}" ]] || day=$(date '+%F')
    name=$(slugify "${title}")
    [[ -n "${name}" ]] || name=$(short_hash "${link}")
    name="${day}-${name}"
    [[ -e "${base}/outbox/${name}.epub" || -e "${base}/sent/${name}.epub" ]] && name="${name}-$(short_hash "${link}")"
    out="${base}/outbox/${name}.epub"
    mv "${tmp_epub}" "${out}"
    printf '%s\n' "${out}"
}

# newest_posts <items file> <n>  -> its n newest lines, in feed order. Newest is by date when every
# post has one, else the first n (feeds list newest first by convention). The sort goes to a file,
# not a pipe into head, so an early-closing pipe can't fail the run under pipefail.
function newest_posts() {
    local sorted="$1.sorted"
    if [[ $(wc -l < "$1") -le $2 ]] || ! awk -F $'\x1f' '$4 == "" { exit 1 }' "$1"; then
        head -n "$2" "$1"
        return 0
    fi
    # number the lines, keep the n latest dates (field 5 once numbered), then restore feed order
    awk -v OFS=$'\x1f' '{ print NR, $0 }' "$1" | LC_ALL=C sort -s -t $'\x1f' -k5,5r -o "${sorted}"
    head -n "$2" "${sorted}" | LC_ALL=C sort -t $'\x1f' -k1,1n | cut -d $'\x1f' -f2-
}

# convert_feed <feed_url> <author> <slug>
function convert_feed() {
    local url="$1" author="$2" slug="$3"
    local base="${ROOT}/${slug}"
    local seen="${base}/seen.txt" failed="${base}/failed.txt"
    local xml="${work}/${slug}.xml" items="${work}/${slug}.items"
    local id link title day
    local -i n_new=0

    mkdir -p "${base}/outbox" "${base}/sent"
    touch "${seen}" "${failed}"

    if ! curl -fsSL --max-time 60 --retry 3 --retry-delay 10 -A "${USER_AGENT}" -o "${xml}" "${url}"; then
        log "[${slug}] failed to fetch feed ${url}"
        return 0
    fi
    if ! yq -p xml -o json "${xml}" | jq -r "$(feed_items_jq)" > "${items}"; then
        log "[${slug}] failed to parse feed ${url}"
        return 0
    fi
    vlog "[${slug}] $(wc -l < "${items}" | tr -d ' ') items in feed"
    if [[ ${MAX_POSTS_PER_FEED} -gt 0 ]]; then
        newest_posts "${items}" "${MAX_POSTS_PER_FEED}" > "${items}.newest"
        mv "${items}.newest" "${items}"
    fi

    while IFS=$'\x1f' read -r id link title day; do
        grep -qxF -- "${id}" "${seen}" && continue

        if convert_url "${link}" "${title}" "${author}" "${day}" "${base}" >/dev/null; then
            echo "${id}" >> "${seen}"
            n_new+=1
        else
            echo "${id}" >> "${failed}"
            if [[ $(grep -cxF -- "${id}" "${failed}") -ge ${MAX_ATTEMPTS} ]]; then
                log "[${slug}] giving up on ${link} after ${MAX_ATTEMPTS} attempts"
                echo "${id}" >> "${seen}"
            else
                log "[${slug}] conversion failed, will retry next run: ${link}"
            fi
        fi
    done < "${items}"

    if [[ ${n_new} -gt 0 ]]; then log "[${slug}] ${n_new} new post(s)"; fi
    return 0
}

# ---- send ------------------------------------------------------------------------------
# RFC 2047 encode a header value so non-ASCII titles survive
function mime_header() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | openssl base64 -A)"; }

# RFC 2231/5987 percent-encoding of UTF-8 bytes
function pct_encode() { perl -e 'print join "", map { /[A-Za-z0-9._~-]/ ? $_ : sprintf("%%%02X", ord) } split //, shift' "$1"; }

# Send to Kindle titles emailed documents after the attachment's file name, not the EPUB
# metadata, so name the attachment after the post: "Some Post: Title?" -> "Some Post Title.epub"
function attachment_name() {
    perl -CSA -e '($t, $f) = @ARGV; $t =~ tr/\x{2018}\x{2019}\x{201C}\x{201D}\x{2013}\x{2014}/'"''''"'\-\-/; $t =~ s/\x{2026}/.../g;
        $t =~ s/[\/\\:*?"<>|\p{Cc}]+/ /g; $t =~ s/\s+/ /g; $t =~ s/^ +| +$//g;
        $t = substr($t, 0, 120); $t =~ s/[ .]+$//; print length($t) ? "$t.epub" : $f' "$1" "$2"
}

# build_mail <epub> <title>  -> RFC 5322 message with the epub attached, on stdout
function build_mail() {
    local epub="$1" title="$2"
    local file="${epub##*/}" att boundary ctype disp
    att=$(attachment_name "${title}" "${file}")
    if LC_ALL=C grep -q '[^ -~]' <<< "${att}"; then
        ctype="name=\"$(mime_header "${att}")\""
        disp="filename=\"${file}\"; filename*=UTF-8''$(pct_encode "${att}")"
    else
        ctype="name=\"${att}\""
        disp="filename=\"${att}\""
    fi
    boundary="b2k-$(openssl rand -hex 12)"
    cat <<EOL
To: ${KINDLE_TO}
Subject: $(mime_header "${title}")
Date: $(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="${boundary}"

--${boundary}
Content-Type: text/plain; charset=UTF-8

Sent by docpeyk.

--${boundary}
Content-Type: application/epub+zip; ${ctype}
Content-Disposition: attachment; ${disp}
Content-Transfer-Encoding: base64

EOL
    openssl base64 < "${epub}"
    printf '\n--%s--\n' "${boundary}"
}

# emails left in this run's budget (MAX_SENDS_PER_RUN), shared by all capped send_outbox calls
declare -i sends_left=${MAX_SENDS_PER_RUN}

# send_outbox <slug> <capped 0|1>  -> mails <slug>/outbox/*.epub, moving each to sent/
# capped (scheduled) sends skip a folder another process is sending; uncapped (ad-hoc) ones wait for it
function send_outbox() {
    local slug="$1" capped="$2"
    local base="${ROOT}/${slug}" epub title lock="${ROOT}/${slug}/.sending"
    local -i size tries=0

    until take_lock "${lock}"; do
        if [[ ${capped} -eq 1 || ${tries} -ge 60 ]]; then
            log "[${slug}] another process is sending this folder, skipping"
            return 0
        fi
        tries+=1
        sleep 2
    done
    held_locks+=("${lock}")

    for epub in "${base}/outbox/"*.epub; do
        [[ -e "${epub}" ]] || continue
        [[ ${capped} -eq 1 && ${sends_left} -le 0 ]] && break
        size=$(wc -c < "${epub}")
        # Send to Kindle caps an email at 50 MB; base64 adds ~37%
        if [[ ${size} -gt 35000000 ]]; then
            log "[${slug}] WARN: ${epub##*/} is too large to email (${size} bytes), skipping"
            continue
        fi
        title=$(opf_field "${epub}" title)

        if build_mail "${epub}" "${title}" | msmtp -a "${MSMTP_ACCOUNT}" -- "${KINDLE_TO}"; then
            mv "${epub}" "${base}/sent/"
            # mv keeps the conversion time; the daily summary counts sends by mtime
            touch "${base}/sent/${epub##*/}"
            log "[${slug}] sent: ${epub##*/}"
            sends_left=$((sends_left - 1))
            sleep "${SEND_DELAY}"
        else
            log "[${slug}] failed to send ${epub##*/}, will retry next run"
        fi
    done

    rm -rf "${lock}"
    unset 'held_locks[${#held_locks[@]}-1]'
}

# send_summary  -> mails the daily summary to SUMMARY_TO; once it's out, the next window starts now
function send_summary() {
    local subject
    summary_window "${work}"
    summary_report "${work}/summary.start" "${work}/summary.now" > "${work}/summary.txt"
    subject="docpeyk: ${summary_sent} sent, ${summary_queued} queued"
    if {
        cat <<EOL
To: ${SUMMARY_TO}
Subject: ${subject}
Date: $(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

EOL
        cat "${work}/summary.txt"
    } | msmtp -a "${MSMTP_ACCOUNT}" -- "${SUMMARY_TO}"; then
        date '+%F' > "${SUMMARY_STAMP}"
        touch -r "${work}/summary.now" "${SUMMARY_STAMP}"
        log "summary sent to ${SUMMARY_TO}: ${summary_sent} sent, ${summary_queued} queued"
    else
        log "failed to send the summary to ${SUMMARY_TO}, will retry next run"
    fi
}

# ---- main ------------------------------------------------------------------------------
if ! wait_for_network; then
    log "no network, exiting"
    exit 0
fi

if [[ ${#adhoc_urls[@]} -gt 0 ]]; then
    declare -i rc=0
    mkdir -p "${ROOT}/${ADHOC}/outbox" "${ROOT}/${ADHOC}/sent"
    for u in "${adhoc_urls[@]}"; do
        convert_url "${u}" '' "${adhoc_author}" '' "${ROOT}/${ADHOC}" >/dev/null \
            || { log "[${ADHOC}] failed to convert ${u}"; rc=1; }
    done
    if [[ ${opt_send} -eq 1 ]]; then
        [[ -n "${KINDLE_TO}" ]] || { log "KINDLE_TO is not set in ${CONF}, not sending"; exit 1; }
        send_outbox "${ADHOC}" 0
        compgen -G "${ROOT}/${ADHOC}/outbox/*.epub" >/dev/null && rc=1
    fi
    exit ${rc}
fi

declare -a slugs=()
feed_list=$(read_feeds log)
readonly feed_list
while IFS=$'\x1f' read -r f_url f_author f_slug; do
    [[ -n "${f_url}" ]] || continue
    [[ -n "${only_slug}" && "${f_slug}" != "${only_slug}" ]] && continue
    slugs+=("${f_slug}")
    if [[ ${opt_convert} -eq 1 ]]; then convert_feed "${f_url}" "${f_author}" "${f_slug}"; fi
done <<< "${feed_list}"

# ad-hoc pages whose immediate send failed are retried by the scheduled run
[[ -z "${only_slug}" && -d "${ROOT}/${ADHOC}/outbox" ]] && slugs+=("${ADHOC}")

[[ ${#slugs[@]} -eq 0 ]] && { vlog "no feeds configured in ${FEEDS}"; exit 0; }

if [[ ${opt_send} -eq 1 ]]; then
    if [[ -z "${KINDLE_TO}" ]]; then
        log "KINDLE_TO is not set in ${CONF}, not sending"
    else
        for s in $(printf '%s\n' "${slugs[@]}" | sort -u); do send_outbox "${s}" 1; done
        if [[ ${sends_left} -le 0 ]]; then
            left=$(find "${ROOT}" -path '*/outbox/*.epub' | wc -l | tr -d ' ')
            [[ ${left} -gt 0 ]] && log "send limit of ${MAX_SENDS_PER_RUN} reached, ${left} file(s) wait for the next run"
        fi
    fi
fi
# after the sends, so the summary counts this run's too
if [[ -z "${only_slug}" && ${opt_send} -eq 1 ]] && summary_due; then send_summary; fi
exit 0

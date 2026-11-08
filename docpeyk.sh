#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

function usage() {
    cat <<END >&2
USAGE: $0 [-d dir] [-f slug] [-C|-S] [-v|-h]
       $0 [-d dir] [-a author] [-C] [-v] URL...
        -d dir         # data directory (default ~/Kindle)
        -f slug        # only process the feed with this slug
        -a author      # author for ad-hoc URLs (default: the page's byline)
        -C             # convert only, don't send
        -S             # send only, don't fetch/convert
        -h|?           # usage
        -v             # verbose

Without URLs: reads <dir>/feeds.csv (feed_url,author,slug), converts every unseen
post to <dir>/<slug>/new/*.epub and mails up to MAX_SENDS_PER_RUN files from new/
to Kindle, moving sent files to <dir>/<slug>/sent/.
With URLs: converts each page to <dir>/adhoc/new/ and sends it right away.
Settings live in <dir>/kindle.conf.

eg,
     $0
     $0 -f jvns -C
     $0 https://example.com/some-post/
     $0 -a "Paul Graham" https://paulgraham.com/greatwork.html
END
    exit $1
}

function log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }
function vlog() { [[ ${opt_verbose} -eq 1 ]] && log "$@"; return 0; }

declare ROOT="${HOME}/Kindle"
declare only_slug=''
declare adhoc_author=''
declare -i opt_convert=1
declare -i opt_send=1
declare -i opt_verbose=0

while getopts ":d:f:a:CShv?" opt; do
    case ${opt} in
    d) ROOT=${OPTARG} ;;
    f) only_slug=${OPTARG} ;;
    a) adhoc_author=${OPTARG} ;;
    C) opt_send=0 ;;
    S) opt_convert=0 ;;
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
readonly ROOT only_slug adhoc_author opt_convert opt_send opt_verbose adhoc_urls

for u in ${adhoc_urls[@]+"${adhoc_urls[@]}"}; do
    [[ "${u}" =~ ^https?:// ]] || { echo >&2 "ERROR: not an http(s) URL: ${u}"; usage 1; }
done
[[ ${#adhoc_urls[@]} -gt 0 && ${opt_convert} -eq 0 ]] && { echo >&2 "ERROR: -S can't be combined with URLs"; usage 1; }

readonly FEEDS="${ROOT}/feeds.csv"
readonly CONF="${ROOT}/kindle.conf"
readonly LOCK="${ROOT}/.lock"
readonly ADHOC="adhoc"

# ---- bootstrap data directory ----------------------------------------------------------
mkdir -p "${ROOT}"
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
# extra percollate flags; covers are rendered with headless Chrome, so they are off by default
# (to enable: npx puppeteer browsers install chrome, then set PERCOLLATE_ARGS=())
PERCOLLATE_ARGS=(--no-cover)
EOL

declare KINDLE_TO=''
declare MSMTP_ACCOUNT='default'
declare -i SEND_DELAY=30
declare -i MAX_SENDS_PER_RUN=5
declare -i MAX_ATTEMPTS=3
declare -a PERCOLLATE_ARGS=(--no-cover)
# shellcheck source=/dev/null
. "${CONF}"

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null   || { echo >&2 "error: jq not found";   exit 3; }
command -v yq >/dev/null   || { echo >&2 "error: yq not found";   exit 3; }
[[ ${opt_convert} -eq 1 ]] && { command -v percollate >/dev/null || { echo >&2 "error: percollate not found"; exit 3; }; }
[[ ${opt_send} -eq 1 ]]    && { command -v msmtp >/dev/null      || { echo >&2 "error: msmtp not found";      exit 3; }; }

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
# sending is serialised per folder in send_new instead
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
        [[ "$(scutil -r 1.1.1.1 2>/dev/null)" == Reachable* ]] && return 0
        sleep 5
    done
    return 1
}

function trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# "Café: Über Title!" -> "cafe-uber-title"  (empty for titles with no latin letters/digits)
function slugify() {
    perl -CSA -MUnicode::Normalize -e '$_ = NFD(shift); s/\p{Mn}|['"'"'\x{2019}]//g; $_ = lc;
        s/[^a-z0-9]+/-/g; s/^-+//; $_ = substr($_, 0, 80); s/-+$//; print' "$1"
}

function short_hash() { printf '%s' "$1" | shasum | cut -c1-8; }

# percollate exits 0 even when it couldn't fetch the page, leaving an EPUB with only nav.xhtml
function has_article() { unzip -Z1 "$1" 2>/dev/null | awk '/^OEBPS\/.*\.xhtml$/ && !/\/nav\.xhtml$/ { f = 1 } END { exit !f }'; }

# opf_field <epub> <dc element>  -> value of e.g. <dc:title> from the package document
function opf_field() {
    { unzip -p "$1" '*.opf' 2>/dev/null || true; } | tr '\n' ' ' \
        | sed -n "s|.*<dc:$2[^>]*>\([^<]*\)</dc:$2>.*|\1|p" \
        | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e "s/&#39;/'/g" -e 's/&amp;/\&/g'
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
        grep -v '^ *at ' "${work}/percollate.log" | head -10 | sed 's/^/    /' >&2
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
    [[ -e "${base}/new/${name}.epub" || -e "${base}/sent/${name}.epub" ]] && name="${name}-$(short_hash "${link}")"
    out="${base}/new/${name}.epub"
    mv "${tmp_epub}" "${out}"
    printf '%s\n' "${out}"
}

# convert_feed <feed_url> <author> <slug>
function convert_feed() {
    local url="$1" author="$2" slug="$3"
    local base="${ROOT}/${slug}"
    local seen="${base}/seen.txt" failed="${base}/failed.txt"
    local xml="${work}/${slug}.xml" items="${work}/${slug}.items"
    local id link title day
    local -i n_new=0

    mkdir -p "${base}/new" "${base}/sent"
    touch "${seen}" "${failed}"

    if ! curl -fsSL --max-time 60 --retry 3 --retry-delay 10 -A 'docpeyk-kindle (+percollate)' -o "${xml}" "${url}"; then
        log "[${slug}] failed to fetch feed ${url}"
        return 0
    fi
    if ! yq -p xml -o json "${xml}" | jq -r -f "${DIR}/feed-items.jq" > "${items}"; then
        log "[${slug}] failed to parse feed ${url}"
        return 0
    fi
    vlog "[${slug}] $(wc -l < "${items}" | tr -d ' ') items in feed"

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

# emails left in this run's budget (MAX_SENDS_PER_RUN), shared by all capped send_new calls
declare -i sends_left=${MAX_SENDS_PER_RUN}

# send_new <slug> <capped 0|1>
# capped (scheduled) sends skip a folder another process is sending; uncapped (ad-hoc) ones wait for it
function send_new() {
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

    for epub in "${base}/new/"*.epub; do
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

# ---- main ------------------------------------------------------------------------------
if ! wait_for_network; then
    log "no network, exiting"
    exit 0
fi

if [[ ${#adhoc_urls[@]} -gt 0 ]]; then
    declare -i rc=0
    mkdir -p "${ROOT}/${ADHOC}/new" "${ROOT}/${ADHOC}/sent"
    for u in "${adhoc_urls[@]}"; do
        convert_url "${u}" '' "${adhoc_author}" '' "${ROOT}/${ADHOC}" >/dev/null \
            || { log "[${ADHOC}] failed to convert ${u}"; rc=1; }
    done
    if [[ ${opt_send} -eq 1 ]]; then
        [[ -n "${KINDLE_TO}" ]] || { log "KINDLE_TO is not set in ${CONF}, not sending"; exit 1; }
        send_new "${ADHOC}" 0
        compgen -G "${ROOT}/${ADHOC}/new/*.epub" >/dev/null && rc=1
    fi
    exit ${rc}
fi

declare -a slugs=()
declare -i lineno=0
while IFS=, read -r f_url f_author f_slug f_extra || [[ -n "${f_url}" ]]; do
    lineno+=1
    f_url=$(trim "${f_url}")
    [[ -z "${f_url}" || "${f_url}" == \#* ]] && continue
    f_author=$(trim "${f_author:-}")
    f_slug=$(trim "${f_slug:-}")
    if [[ -n "${f_extra:-}" || -z "${f_author}" || ! "${f_slug}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log "feeds.csv:${lineno}: expected 'feed_url,author,slug', skipping"
        continue
    fi
    [[ -n "${only_slug}" && "${f_slug}" != "${only_slug}" ]] && continue
    slugs+=("${f_slug}")
    if [[ ${opt_convert} -eq 1 ]]; then convert_feed "${f_url}" "${f_author}" "${f_slug}"; fi
done < "${FEEDS}"

# ad-hoc pages whose immediate send failed are retried by the scheduled run
[[ -z "${only_slug}" && -d "${ROOT}/${ADHOC}/new" ]] && slugs+=("${ADHOC}")

[[ ${#slugs[@]} -eq 0 ]] && { vlog "no feeds configured in ${FEEDS}"; exit 0; }

if [[ ${opt_send} -eq 1 ]]; then
    if [[ -z "${KINDLE_TO}" ]]; then
        log "KINDLE_TO is not set in ${CONF}, not sending"
    else
        for s in $(printf '%s\n' "${slugs[@]}" | sort -u); do send_new "${s}" 1; done
        if [[ ${sends_left} -le 0 ]]; then
            left=$(find "${ROOT}" -path '*/new/*.epub' | wc -l | tr -d ' ')
            [[ ${left} -gt 0 ]] && log "send limit of ${MAX_SENDS_PER_RUN} reached, ${left} file(s) wait for the next run"
        fi
    fi
fi
exit 0

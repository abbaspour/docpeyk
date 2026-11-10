#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

function usage() {
    cat <<END >&2
USAGE: $0 [-b bash] [-k] [-h]
        -b bash        # bash binary that runs docpeyk.sh (default: bash on PATH)
        -k             # keep the scratch directory
        -h|?           # usage

End-to-end tests for docpeyk.sh against fixture feeds, with stub percollate,
msmtp and network checks from tests/stubs (no network access needed).

eg,
     $0
     $0 -b /bin/bash
END
    exit $1
}

declare test_bash='bash'
declare -i opt_keep=0

while getopts ":b:kh?" opt; do
    case ${opt} in
    b) test_bash=${OPTARG} ;;
    k) opt_keep=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
# absolute, as some tests run with a minimal PATH
test_bash=$(command -v "${test_bash}") || { echo >&2 "ERROR: bash not found: ${test_bash}"; exit 1; }
readonly test_bash opt_keep

command -v zip >/dev/null || { echo >&2 "error: zip not found (used by the percollate stub)"; exit 3; }

root=$(cd "${DIR}/.." && pwd)
readonly root
scratch=$(mktemp -d "${TMPDIR:-/tmp}/docpeyk-test.XXXXXX")
readonly scratch
if [[ ${opt_keep} -eq 1 ]]; then
    trap 'echo "scratch kept in ${scratch}"' EXIT
else
    trap 'rm -rf "${scratch}"' EXIT
fi

readonly data="${scratch}/data"
export STUB_LOG="${scratch}/stub"
export PATH="${root}/tests/stubs:${PATH}"
mkdir -p "${data}" "${STUB_LOG}"
touch "${STUB_LOG}/percollate.calls" "${scratch}/last.log"

cat > "${data}/kindle.conf" <<EOL
KINDLE_TO="reader@kindle.example"
SEND_DELAY=0
MAX_SENDS_PER_RUN=3
MAX_ATTEMPTS=3
EOL
cat > "${data}/feeds.csv" <<EOL
# fixtures
file://${root}/tests/fixtures/rss2.xml,RSS Author,rss
file://${root}/tests/fixtures/atom.xml, Atom Author , atom
file://${root}/tests/fixtures/rdf.xml,RDF Author,rdf
not,a valid,slug!
EOL

declare -i failures=0
declare -i checks=0

# docpeyk <args...>: runs the script under test; its log goes to ${scratch}/last.log
function docpeyk() { "${test_bash}" "${root}/docpeyk.sh" -d "${data}" "$@" 2>"${scratch}/last.log"; }

# check <description> <command...>
function check() {
    local desc="$1"
    shift
    checks+=1
    if "$@"; then
        echo "ok   ${desc}"
    else
        failures+=1
        echo "FAIL ${desc}"
        sed 's/^/     | /' "${scratch}/last.log" || true
    fi
}

function count() { find "${data}/$1" -name '*.epub' | wc -l | tr -d ' '; }
function calls() { wc -l < "${STUB_LOG}/percollate.calls" | tr -d ' '; }
function mails() { find "${STUB_LOG}" -name 'mail-*.eml' | wc -l | tr -d ' '; }
function logged() { grep -qF -- "$1" "${scratch}/last.log"; }
function files_are() { [[ "$(cd "${data}/$1" && ls)" == "$2" ]]; }

# ---- version ---------------------------------------------------------------------------
check "-V prints the version" [ "$("${test_bash}" "${root}/docpeyk.sh" -V)" = "docpeyk $(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "${root}/docpeyk.sh")" ]

# ---- convert: feed parsing, naming, retries ----------------------------------------------
check "convert-only run succeeds" docpeyk -C
check "RSS 2.0: entities, typographic quote and accents in names" files_are rss/outbox \
    "$(printf '%s\n' 2026-02-03-tom-jerrys-plan.epub 2026-03-02-cafe-uber-alles.epub)"
check "Atom: rel=alternate link, HTML title, published/updated date" files_are atom/outbox \
    "$(printf '%s\n' 2026-04-05-hello-world.epub 2026-04-06-second.epub)"
check "RSS 1.0 (RDF): rdf:about id and dc:date" files_are rdf/outbox 2026-05-01-rdf-one.epub
check "titles and trimmed authors match the EPUB metadata" eval '! logged mismatch'
check "ids recorded in seen.txt (link when there is no guid)" \
    [ "$(cat "${data}/rss/seen.txt")" = "$(printf '%s\n' rss-1 rss-2)" ]
check "invalid feeds.csv line is reported" logged "feeds.csv:5: expected 'feed_url,author,slug'"
check "failed conversion is retried next run" logged "conversion failed, will retry next run: https://example.com/fail-post"
check "nothing is mailed with -C" [ "$(mails)" = 0 ]
check "a run by hand also appends to docpeyk.log" \
    grep -qF "[rss] conversion failed, will retry next run: https://example.com/fail-post" "${data}/docpeyk.log"

check "second run only retries the failed post" docpeyk -C
check "second run made one percollate call" [ "$(calls)" = 7 ]
docpeyk -C || true
check "third failure gives up" logged "giving up on https://example.com/fail-post after 3 attempts"
check "given-up post is marked seen" grep -qxF https://example.com/fail-post "${data}/rss/seen.txt"
docpeyk -C || true
check "fourth run converts nothing" [ "$(calls)" = 8 ]

# ---- send: cap, MIME, outbox -> sent -----------------------------------------------------
check "send-only run succeeds" docpeyk -S
check "MAX_SENDS_PER_RUN caps the run at 3" [ "$(mails)" = 3 ]
check "cap is reported" logged "send limit of 3 reached, 2 file(s) wait for the next run"
docpeyk -S || true
check "next run sends the rest" [ "$(mails)" = 5 ]
check "all outboxes are empty" [ "$(count rss/outbox)$(count atom/outbox)$(count rdf/outbox)" = 000 ]
check "sent files are kept" [ "$(count rss/sent)$(count atom/sent)$(count rdf/sent)" = 221 ]
check "msmtp gets the account and recipient" grep -qxF -- '-a default -- reader@kindle.example' "${STUB_LOG}/msmtp.calls"

cafe=$(grep -l 'cafe-uber-alles' "${STUB_LOG}"/mail-*.eml)
readonly cafe
check "mail is addressed to KINDLE_TO" grep -qxF 'To: reader@kindle.example' "${cafe}"
check "non-ASCII attachment name is RFC 2231 encoded" \
    grep -qF "filename=\"2026-03-02-cafe-uber-alles.epub\"; filename*=UTF-8''Caf%C3%A9%20%C3%9Cber%20alles.epub" "${cafe}"
check "ASCII attachment is named after the title" grep -qF "filename=\"Tom & Jerry's Plan.epub\"" "${STUB_LOG}"/mail-*.eml

# ---- ad-hoc ------------------------------------------------------------------------------
today=$(date '+%F')
readonly today
check "ad-hoc URL is converted and sent" docpeyk -a 'Paul Graham' https://example.com/essay
check "ad-hoc file moved to adhoc/sent" files_are adhoc/sent "${today}-page-title.epub"
check "ad-hoc name collision gets a hash suffix" docpeyk -C https://example.com/essay2
check "suffixed name" files_are adhoc/outbox "${today}-page-title-$(printf '%s' https://example.com/essay2 | openssl dgst -sha1 | awk '{ print substr($NF, 1, 8) }').epub"
rm -f "${data}"/adhoc/outbox/*.epub

export STUB_MSMTP_FAIL=1
check "ad-hoc send failure exits 1" eval '! docpeyk https://example.com/later'
check "unsent ad-hoc file stays in the outbox" [ "$(count adhoc/outbox)" = 1 ]
unset STUB_MSMTP_FAIL
check "scheduled run retries the ad-hoc outbox" docpeyk -S
check "ad-hoc outbox is empty" [ "$(count adhoc/outbox)" = 0 ]

# launchd and cron point stderr at docpeyk.log; each line must land there once, not twice
"${test_bash}" "${root}/docpeyk.sh" -d "${data}" -C https://example.com/launchd-run 2>>"${data}/docpeyk.log" || true
check "stderr redirected to docpeyk.log: no duplicate lines" \
    [ "$(grep -cF '[adhoc] converting: <https://example.com/launchd-run>' "${data}/docpeyk.log")" = 1 ]
rm -f "${data}"/adhoc/outbox/*.epub

check "non-http ad-hoc argument is rejected" eval '! docpeyk ftp://example.com/x'
check "-S with URLs is rejected" eval '! docpeyk -S https://example.com/x'

# ---- dependency checks -------------------------------------------------------------------
mkdir -p "${scratch}/fake-yq"
printf '#!/usr/bin/env bash\necho "yq 3.4.3"\n' > "${scratch}/fake-yq/yq"
chmod +x "${scratch}/fake-yq/yq"
PATH="${scratch}/fake-yq:${PATH}" "${test_bash}" "${root}/docpeyk.sh" -d "${data}" -C 2>"${scratch}/last.log" && rc=0 || rc=$?
check "Python yq is rejected with exit 3" [ "${rc}" = 3 ]
check "Python yq error names mikefarah/yq" logged "yq is not mikefarah/yq"

# ---- MAX_POSTS_PER_FEED ------------------------------------------------------------------
# a separate data dir, so the counts above stay as they are
readonly limits="${scratch}/limits"

# rss_feed <file> <title|YYYY-MM-DD or ->...: writes an RSS 2.0 feed, one item per argument
function rss_feed() {
    local file="$1" item title day
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>t</title>\n'
        for item in "$@"; do
            title="${item%|*}"
            day="${item#*|}"
            printf '<item><title>%s</title><link>https://example.net/%s</link>' "${title}" "${title// /-}"
            [[ "${day}" == - ]] || printf '<pubDate>%s</pubDate>' "${day}"
            printf '</item>\n'
        done
        printf '</channel></rss>\n'
    } > "${file}"
}
function limited() { "${test_bash}" "${root}/docpeyk.sh" -d "${limits}" -C 2>"${scratch}/last.log"; }
function limited_files() { [[ "$(cd "${limits}/$1/outbox" && ls)" == "$2" ]]; }

mkdir -p "${limits}"
rss_feed "${scratch}/dated.xml" 'Post A|2026-01-10' 'Post B|2026-03-01' 'Post C|2026-02-15' 'Post D|2026-03-01' 'Post E|2025-12-31'
rss_feed "${scratch}/undated.xml" 'Post W|-' 'Post X|-' 'Post Y|-' 'Post Z|-'
printf 'MAX_POSTS_PER_FEED=3\n' > "${limits}/kindle.conf"
printf 'file://%s,A,dated\nfile://%s,A,undated\n' "${scratch}/dated.xml" "${scratch}/undated.xml" > "${limits}/feeds.csv"
check "MAX_POSTS_PER_FEED=3 run succeeds" limited
check "dated feed: the 3 newest by date, feed order kept for equal dates" limited_files dated \
    "$(printf '%s\n' 2026-02-15-post-c.epub 2026-03-01-post-b.epub 2026-03-01-post-d.epub)"
check "  ties keep feed order (B is converted before D)" \
    [ "$(grep -o 'Post [BD]' "${scratch}/last.log" | tr '\n' ' ')" = "Post B Post D " ]
check "undated feed: the first 3 in feed order" limited_files undated \
    "$(printf '%s\n' "${today}-post-w.epub" "${today}-post-x.epub" "${today}-post-y.epub")"
rss_feed "${scratch}/dated.xml" 'Post F|2026-04-01' 'Post A|2026-01-10' 'Post B|2026-03-01' 'Post C|2026-02-15' 'Post D|2026-03-01' 'Post E|2025-12-31'
check "next run succeeds" limited
check "  only the new post is converted; older ones aren't backfilled" \
    [ "$(grep -c 'converting:' "${scratch}/last.log")" = 1 ]
check "  and it is Post F" logged 'converting: Post F'

rm -rf "${limits}"
mkdir -p "${limits}"
printf 'MAX_POSTS_PER_FEED=0\n' > "${limits}/kindle.conf"
printf 'file://%s,A,dated\n' "${scratch}/dated.xml" > "${limits}/feeds.csv"
check "MAX_POSTS_PER_FEED=0 converts every post" limited
check "  all 6" [ "$(find "${limits}/dated/outbox" -name '*.epub' | wc -l | tr -d ' ')" = 6 ]

rm -rf "${limits}"
mkdir -p "${limits}"
declare -a twelve=()
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do twelve+=("Post ${i}|2026-01-${i}"); done
rss_feed "${scratch}/twelve.xml" "${twelve[@]}"
printf '# no MAX_POSTS_PER_FEED here\n' > "${limits}/kindle.conf"
printf 'file://%s,A,twelve\n' "${scratch}/twelve.xml" > "${limits}/feeds.csv"
check "default limit run succeeds" limited
check "  default is the 10 newest" [ "$(cd "${limits}/twelve/outbox" && ls | head -1)" = 2026-01-03-post-03.epub ]
check "  10 files" [ "$(find "${limits}/twelve/outbox" -name '*.epub' | wc -l | tr -d ' ')" = 10 ]

# ---- doctor ------------------------------------------------------------------------------
# doctor_run <data dir>: docpeyk.sh -D; report in ${scratch}/out
function doctor_run() { "${test_bash}" "${root}/docpeyk.sh" -d "$1" -D >"${scratch}/out" 2>"${scratch}/last.log"; }
function reported() { grep -qxF -- "$1" "${scratch}/out" || { sed 's/^/     > /' "${scratch}/out"; return 1; }; }

calls_before=$(calls)
check "doctor passes on the test setup (warnings only)" doctor_run "${data}"
check "  tools" reported "ok    tools: curl jq yq perl openssl unzip percollate msmtp"
check "  node" reported "ok    node v20.11.1 for ${root}/tests/stubs/percollate"
check "  odd KINDLE_TO is a warning" \
    reported "warn  KINDLE_TO reader@kindle.example doesn't look like a Send to Kindle address (...@kindle.com)"
check "  msmtp account, host and from" reported "ok    msmtp account default: host smtp.example, from me@example.com"
check "  SMTP server" reported "ok    SMTP server smtp.example answers"
check "  invalid feeds.csv line" reported "warn  feeds.csv:5: expected 'feed_url,author,slug', skipping"
check "  feed count" reported "ok    feeds.csv: 3 feed(s)"
check "  not scheduled" reported "warn  not scheduled; install.sh sets up launchd (macOS) or cron"
check "  doctor doesn't touch feeds" [ "$(calls)" = "${calls_before}" ]
check "  no secrets from msmtp -P" eval '! grep -q password "${scratch}/out"'

readonly sick="${scratch}/sick"
mkdir -p "${sick}"
printf 'KINDLE_TO=""\nMSMTP_ACCOUNT="work"\n' > "${sick}/kindle.conf"
printf 'https://a.example/feed,A,same\nhttps://b.example/feed,B,same\nhttps://c.example/feed,C,adhoc\n' > "${sick}/feeds.csv"
export STUB_NODE_VERSION=12.22.9
check "doctor fails on a broken setup" eval '! doctor_run "${sick}"'
unset STUB_NODE_VERSION
check "  old node" reported "FAIL  percollate needs Node >= 14.17, found v12.22.9"
check "  no KINDLE_TO" reported "FAIL  KINDLE_TO is not set in ${sick}/kindle.conf"
check "  unknown msmtp account, in msmtp's words" reported "FAIL  msmtp: account work not found in ${HOME}/.msmtprc"
check "  duplicate slug" reported "warn  feeds.csv: slug used more than once: same"
check "  reserved slug" reported "warn  feeds.csv: 'adhoc' is reserved for ad-hoc pages; pick another slug"
check "  problem count" reported "3 problem(s) to fix"
export STUB_SMTP_DOWN=1
printf 'KINDLE_TO="me@kindle.com"\n' > "${sick}/kindle.conf"
check "doctor fails when the SMTP server doesn't answer" eval '! doctor_run "${sick}"'
unset STUB_SMTP_DOWN
check "  says so" reported "FAIL  SMTP server smtp.example doesn't answer; details: msmtp -S -a default"
check "  a kindle.com address is fine" reported "ok    KINDLE_TO me@kindle.com"
export STUB_MSMTPRC_OPEN=1
check "doctor fails on a ~/.msmtprc others can read" eval '! doctor_run "${sick}"'
unset STUB_MSMTPRC_OPEN
check "  shows msmtp's reason, not \"account not found\"" \
    reported "FAIL  msmtp: ${HOME}/.msmtprc: contains secrets and therefore must have no more than user read/write permissions"
check "-D with URLs is rejected" eval '! docpeyk -D https://example.com/x'

# ---- install.sh --------------------------------------------------------------------------
# install <args...>: install.sh with HOME in the scratch dir and no terminal; output in ${scratch}/out
readonly home="${scratch}/home"
mkdir -p "${home}"
function install() { HOME="${home}" "${test_bash}" "${root}/install.sh" "$@" </dev/null >"${scratch}/out" 2>"${scratch}/last.log"; }
function crontab_is() { [[ "$(cat "${STUB_LOG}/crontab")" == "$1" ]]; }
readonly cron_tail="'${root}/docpeyk.sh' >> '${home}/Kindle/docpeyk.log' 2>&1 # docpeyk (managed by install.sh)"

check "cron dry run" install -s cron -n
check "  hourly at a random minute, PATH baked in" grep -qE "^([1-9]|[1-5][0-9]) \\* \\* \\* \\* PATH='[^']*/tests/stubs:" "${scratch}/out"
function cron_line_ends_right() { [[ "$(cat "${scratch}/out")" == *" LANG='"*"${cron_tail}" ]]; }
check "  logs appended, tagged" cron_line_ends_right
check "  dry run doesn't touch the crontab" [ ! -e "${STUB_LOG}/crontab" ]
check "-i 1800 runs every 30 minutes" install -s cron -i 1800 -n
check "  */30" grep -q '^\*/30 \* \* \* \* ' "${scratch}/out"
check "-i 7200 runs every 2 hours" install -s cron -i 7200 -n
check "  */2" grep -qE '^[0-9]+ \*/2 \* \* \* ' "${scratch}/out"
check "-i 45 is rejected for cron" eval '! install -s cron -i 45 -n'
check "-i 5400 (90 min) is rejected for cron" eval '! install -s cron -i 5400 -n'
check "  says why" logged "cron can't run every 5400 s"

printf '0 5 * * * /usr/local/bin/backup\n' > "${STUB_LOG}/crontab"
check "cron install" install -s cron
check "  creates ~/Kindle for the log" [ -d "${home}/Kindle" ]
install -s cron || true
check "  installing twice keeps one line and the user's own" \
    [ "$(grep -c 'docpeyk (managed' "${STUB_LOG}/crontab")$(grep -c backup "${STUB_LOG}/crontab")" = 11 ]
check "doctor sees the cron schedule" doctor_run "${data}"
check "  scheduled with cron" reported "ok    scheduled with cron"
check "cron uninstall" install -s cron -u
check "  removes only our line" crontab_is '0 5 * * * /usr/local/bin/backup'

rm -f "${STUB_LOG}/launchctl.calls"
check "launchd dry run" install -s launchd -i 1800 -n
check "  plist label, interval and log" eval 'grep -q "<string>io.github.abbaspour.docpeyk</string>" "${scratch}/out" &&
    grep -q "<integer>1800</integer>" "${scratch}/out" && grep -q "<string>${home}/Kindle/docpeyk.log</string>" "${scratch}/out"'
check "  dry run doesn't call launchctl" [ ! -e "${STUB_LOG}/launchctl.calls" ]
check "unknown scheduler is rejected" eval '! install -s systemd -n'

# percollate missing: a PATH with every stub except percollate, plus the system tools
readonly nopc="${scratch}/no-percollate"
mkdir -p "${nopc}"
for s in "${root}"/tests/stubs/*; do [[ "${s##*/}" == percollate ]] || ln -s "${s}" "${nopc}/${s##*/}"; done
function install_nopc() { PATH="${nopc}:/usr/bin:/bin:/usr/sbin:/sbin" install "$@"; }

check "no percollate, no terminal, no -y: install goes ahead" install_nopc -s cron
check "  without running npm" [ ! -e "${STUB_LOG}/npm.calls" ]
check "  and says how" logged "WARN: percollate not found: re-run with -y to install it with npm"
check "-y installs percollate with npm" install_nopc -s cron -y
check "  skipping puppeteer's Chrome" grep -qxF 'install -g percollate PUPPETEER_SKIP_DOWNLOAD=1' "${STUB_LOG}/npm.calls"
check "  npm's bin folder is in the schedule's PATH" grep -qF "${STUB_LOG}/npm-global/bin:" "${STUB_LOG}/crontab"
rm -rf "${STUB_LOG}/npm-global" "${STUB_LOG}/npm.calls"
export STUB_NODE_VERSION=14.16.1
check "-y with Node 14.16 still installs the schedule" install_nopc -s cron -y
unset STUB_NODE_VERSION
check "  but not percollate" [ ! -e "${STUB_LOG}/npm.calls" ]
check "  and says why" logged "WARN: percollate needs Node >= 14.17, found v14.16.1"
mkdir -p "${scratch}/root-owned"
chmod 555 "${scratch}/root-owned"
export STUB_NPM_PREFIX="${scratch}/root-owned"
check "-y with a read-only npm prefix still installs the schedule" install_nopc -s cron -y
unset STUB_NPM_PREFIX
chmod 755 "${scratch}/root-owned"
check "  but doesn't run npm" [ ! -e "${STUB_LOG}/npm.calls" ]
check "  and suggests a user prefix or sudo" eval 'logged "npm config set prefix ~/.local" && logged "sudo PUPPETEER_SKIP_DOWNLOAD=1 npm install -g percollate"'
install -s cron -u || true

# ---- findfeed.sh -------------------------------------------------------------------------
# findfeed <args...>: runs findfeed.sh against tests/fixtures/sites via the curl stub; output in ${scratch}/out
function findfeed() {
    PATH="${root}/tests/stubs-web:${PATH}" "${test_bash}" "${root}/findfeed.sh" "$@" >"${scratch}/out" 2>"${scratch}/last.log"
}
function printed() { [[ "$(cat "${scratch}/out")" == "$1" ]]; }

check "findfeed -V prints the version" findfeed -V
check "findfeed version matches docpeyk's" printed "findfeed $(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "${root}/docpeyk.sh")"
check "posts feed found, comment feed listed first is skipped" findfeed https://janedoe.example/
check "  commented-out link is ignored" printed https://janedoe.example/feed/
check "bare host name works" findfeed janedoe.example
check "  same feed" printed https://janedoe.example/feed/
check "-a lists posts and comment feeds, deduplicated, without body links" findfeed -a https://janedoe.example/
check "  two feeds with titles" printed "$(printf '%s\t%s\n' https://janedoe.example/feed/ 'Jane & Co' https://janedoe.example/comments/feed/ 'Comments for Jane')"
check "-c uses the sole post author and the host as slug" findfeed -c https://janedoe.example/
check "  csv line" printed "https://janedoe.example/feed/,Jane Doe,janedoe"
check "a feed URL is returned as is" findfeed https://janedoe.example/feed/
check "  itself" printed https://janedoe.example/feed/
check "relative href; dead and non-feed links are skipped" findfeed -c https://www.relative.example/posts/
check "  Atom feed author, www. dropped from slug" printed "https://www.relative.example/atom.xml,Ada Lovelace,relative"
check "<base href>, unquoted attributes and &amp; in the href" findfeed https://based.example/
check "  resolved against the base" printed "https://cdn.based.example/blog/feed.xml?format=rss&v=2"
check "no <link>: common location at the site root" findfeed -c https://blog.multi.example/
check "  several authors: title without commas, blog. dropped" printed "https://blog.multi.example/rss.xml,Multi Inc Blog,multi"
check "no <link>: common location under the page's folder" findfeed https://hugo.example/blog/
check "  index.xml" printed https://hugo.example/blog/index.xml
check "no <link>: /blog served without a trailing slash counts as a folder" findfeed https://section.example/blog
check "  /blog/feed" printed https://section.example/blog/feed
check "no <link>: folders above a post page are tried" findfeed https://section.example/blog/2024/05/post.html
check "  /blog/feed from three levels down" printed https://section.example/blog/feed
check "only a comment feed: exits 1" eval '! findfeed https://nofeed.example/'
check "  says so" logged "no feed found for https://nofeed.example/"
check "unreachable site: exits 1" eval '! findfeed https://missing.example/'
check "  says so" logged "failed to fetch https://missing.example/"
check "non-http URL is rejected" eval '! findfeed ftp://example.com/'

echo
echo "${checks} checks, ${failures} failed"
[[ ${failures} -eq 0 ]]

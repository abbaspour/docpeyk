#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

readonly VERSION="0.1.0"

function usage() {
    cat <<END >&2
USAGE: $0 [-a] [-c] [-v|-V|-h] URL
        -a             # list every feed found (url<TAB>title), not just the first
        -c             # print a feeds.csv line: feed_url,author,slug
        -V             # print version
        -h|?           # usage
        -v             # verbose: show each candidate tried

Finds the RSS/Atom feed of a website. URL can be the feed itself, any page of the
site, or a bare host name. Tries the page's <link rel="alternate"> tags (skipping
comment feeds), then common locations (/feed, /rss.xml, /atom.xml, /index.xml, ...) in the
page's folder, each folder above it and the site root.
Every candidate is downloaded and must parse as RSS 2.0, RSS 1.0 or Atom.
The csv author is the feed's author, the sole author of its posts, or else its title;
the slug comes from the site's host name. Review both before use.
Exits 1 when no feed is found.

eg,
     $0 jvns.ca
     $0 -a https://www.joelonsoftware.com/
     $0 -c https://jvns.ca/ >> ~/Kindle/feeds.csv
END
    exit $1
}

function log() { printf '%s\n' "$*" >&2; }
function vlog() { [[ ${opt_verbose} -eq 1 ]] && log "$@"; return 0; }

declare -i opt_all=0
declare -i opt_csv=0
declare -i opt_verbose=0

while getopts ":acVhv?" opt; do
    case ${opt} in
    a) opt_all=1 ;;
    c) opt_csv=1 ;;
    V) echo "findfeed ${VERSION}"; exit 0 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))
readonly opt_all opt_csv opt_verbose

[[ $# -eq 1 ]] || { echo >&2 "ERROR: expected exactly one URL"; usage 1; }
declare site="$1"
[[ "${site}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || site="https://${site}"
[[ "${site}" =~ ^https?:// ]] || { echo >&2 "ERROR: not an http(s) URL: $1"; usage 1; }
readonly site

for tool in curl jq yq perl; do
    command -v "${tool}" >/dev/null || { echo >&2 "error: ${tool} not found"; exit 3; }
done
# Debian, Ubuntu and Arch package a different, Python-based tool as "yq" that can't read XML like this
[[ "$(yq --version 2>&1)" == *mikefarah* ]] \
    || { echo >&2 "error: yq is not mikefarah/yq, install it from https://github.com/mikefarah/yq"; exit 3; }

readonly USER_AGENT="findfeed/${VERSION} (docpeyk; +https://github.com/abbaspour/docpeyk)"
readonly US=$'\x1f'
work=$(mktemp -d "${TMPDIR:-/tmp}/findfeed.XXXXXX")
readonly work
trap 'rm -rf "${work}"' EXIT

# fetch <url> <file>  -> downloads, following redirects; prints the final URL
function fetch() {
    curl -fsL --max-time 20 -A "${USER_AGENT}" -o "$2" -w '%{url_effective}' "$1" 2>/dev/null
}

# jq program over `yq -p xml -o json` output: "title <US> author" of an RSS 2.0, RSS 1.0 or
# Atom feed, failing for anything else. The author is the feed's own, else the one author all
# posts share, else the feed title (multi-author blogs). In a function so bash 3.2 parses the quotes.
function feed_meta_jq() {
    cat <<'EOL'
def arr: if . == null then [] elif type == "array" then . else [.] end;
def txt: if type == "object" then (.["+content"] // "") elif . == null then "" else tostring end;
# Atom <author><name>, or RSS "jane@example.com (Jane Doe)" / "Jane Doe"
def who: if type == "object" and has("name") then (.name | txt) else (txt | (capture("\\((?<n>[^)]+)\\)").n // .)) end;
def clean: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");

(if .feed then
    [(.feed.title | txt), (.feed.author | arr | .[0] | who), [.feed.entry | arr | .[] | .author | arr | .[0] | who]]
 elif .rss.channel then
    [(.rss.channel.title | txt), ((.rss.channel["itunes:author"] // .rss.channel["dc:creator"]) | who),
     [.rss.channel.item | arr | .[] | (.["dc:creator"] // .author) | who]]
 elif .["rdf:RDF"] then
    [(.["rdf:RDF"].channel.title | txt), (.["rdf:RDF"].channel["dc:creator"] | who),
     [.["rdf:RDF"].item | arr | .[] | .["dc:creator"] | who]]
 else error("not a feed") end)
| (.[0] | clean) as $title
| (.[1] | clean) as $author
| ([.[2][] | clean | select(. != "")] | unique) as $posts
| [$title, (if $author != "" then $author elif ($posts | length) == 1 then $posts[0] else $title end)]
| join("\u001f")
EOL
}

# feed_meta <file>  -> "title <US> author"; fails when the file is not a feed
function feed_meta() { yq -p xml -o json "$1" 2>/dev/null | jq -er "$(feed_meta_jq)" 2>/dev/null; }

# feed_links <page url> < html  -> "href <TAB> title" of each <link rel="alternate"> feed in <head>,
# with hrefs resolved against the page URL (or its <base href>)
function feed_links() {
    perl -e '
        use strict; use warnings; use Encode qw(encode_utf8);
        my $base = shift; local $/; my $html = <STDIN> // "";
        $html =~ s/<!--.*?-->//gs;
        $html =~ s{</head>.*}{}is;     # body links are usually per-category or per-post feeds

        sub decode { my $s = shift;
            $s =~ s/&#(\d+);/encode_utf8(chr $1)/ge; $s =~ s/&#x([0-9a-f]+);/encode_utf8(chr hex $1)/gei;
            $s =~ s/&quot;/"/g; $s =~ s/&apos;/\x27/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&amp;/&/g; $s }

        # RFC 3986 reference resolution, enough for feed links (no query/fragment merging)
        sub resolve { my ($b, $h) = @_;
            $h =~ s/^\s+|\s+$//g;
            return $h if $h =~ m{^[a-z][a-z0-9+.-]*:}i;
            my ($scheme, $auth, $path, $query) = $b =~ m{^([a-z][a-z0-9+.-]*)://([^/?#]*)([^?#]*)(\?[^#]*)?}i or return $h;
            return "$scheme:$h" if $h =~ m{^//};
            $path = "/" if $path eq "";
            return "$scheme://$auth$path$h" if $h =~ /^\?/;
            return "$scheme://$auth$path" . ($query // "") . $h if $h =~ /^#/;
            my ($p, $rest) = ($h =~ m{^/} ? $h : ($path =~ s{[^/]*$}{}r) . $h) =~ /^([^?#]*)(.*)$/;
            my @out;
            for my $seg (split m{/}, $p, -1) {
                if ($seg eq "..") { pop @out if @out > 1 } elsif ($seg ne ".") { push @out, $seg }
            }
            $p = join "/", @out; $p .= "/" if $h =~ m{(^|/)\.\.?$};
            return "$scheme://$auth$p$rest" }

        sub attrs { my %a; my $s = shift;
            while ($s =~ /([\w:-]+)\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s"\x27>]+))/g) { $a{lc $1} = decode($2 // $3 // $4) }
            return %a }

        if ($html =~ /<base\b([^>]*)>/i) { my %a = attrs($1); $base = resolve($base, $a{href}) if length($a{href} // "") }
        while ($html =~ /<link\b([^>]*)>/gi) {
            my %a = attrs($1);
            next unless ($a{rel} // "") =~ /(^|\s)alternate(\s|$)/i;
            next unless ($a{type} // "") =~ m{^\s*application/(rss|atom|rdf)\+xml\s*(;.*)?$}i;
            next unless length($a{href} // "");
            my $t = $a{title} // ""; $t =~ s/[\t\n\r]+/ /g;
            print resolve($base, $a{href}), "\t", $t, "\n";
        }' "$1"
}

# site_slug <url>  -> "jvns" for https://jvns.ca/, "cloudflare" for https://blog.cloudflare.com/
function site_slug() {
    local host="${1#*://}" re='^(www|blog|feeds?)\.'
    host="${host%%[/?#]*}"
    host="${host##*@}"
    host=$(printf '%s' "${host%%:*}" | tr '[:upper:]' '[:lower:]')
    while [[ "${host}" =~ ${re} ]]; do host="${host#*.}"; done
    host="${host%%.*}"
    host="${host//[^a-z0-9-]/}"
    printf '%s' "${host:-feed}"
}

declare -a found=()   # "feed url <US> title <US> author", in discovery order

# try_feed <url>: adds the feed at url to found, unless it isn't one or is already there
function try_feed() {
    local file="${work}/candidate" eff meta f
    vlog "trying ${1}"
    eff=$(fetch "$1" "${file}") || { vlog "  not reachable"; return 1; }
    meta=$(feed_meta "${file}") || { vlog "  not a feed"; return 1; }
    for f in ${found[@]+"${found[@]}"}; do
        [[ "${f%%"${US}"*}" == "${eff}" ]] && return 0
    done
    found+=("${eff}${US}${meta}")
}

# done_looking: true once we have what was asked for (the first feed, unless -a)
function done_looking() { [[ ${opt_all} -eq 0 && ${#found[@]} -gt 0 ]]; }

# ---- main ------------------------------------------------------------------------------
readonly page="${work}/page"
vlog "fetching ${site}"
page_url=$(fetch "${site}" "${page}") || { log "ERROR: failed to fetch ${site}"; exit 1; }
readonly page_url

if meta=$(feed_meta "${page}"); then
    vlog "${page_url} is a feed"
    found+=("${page_url}${US}${meta}")
else
    links=$(feed_links "${page_url}" < "${page}")
    readonly links
    vlog "$(grep -c . <<< "${links}" || true) feed link(s) in the page"
    # posts feeds first; comment feeds only for -a
    for pass in posts comments; do
        [[ "${pass}" == comments && ${opt_all} -eq 0 ]] && break
        while IFS=$'\t' read -r href title; do
            [[ -n "${href}" ]] || continue
            if [[ "${title}${href}" =~ [Cc]omment ]]; then is_comments=comments; else is_comments=posts; fi
            [[ "${is_comments}" == "${pass}" ]] || continue
            try_feed "${href}" || true
            done_looking && break 2
        done <<< "${links}"
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        # no usable <link>: try where blog engines put feeds, in the page's folder, each folder
        # above it, then the site root. A last segment without an extension ("/blog") is usually
        # a section served without a trailing slash, so it counts as a folder too.
        origin=$(printf '%s' "${page_url}" | sed -E 's|^([a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*).*|\1|')
        path=$(printf '%s' "${page_url#"${origin}"}" | sed -E 's|[?#].*||')
        [[ "${path}" == */ || "${path##*/}" == *.* ]] || path="${path}/"
        folder="${path%/*}/"
        declare -a bases=()
        while [[ "${folder}" != / ]]; do
            bases+=("${origin}${folder}")
            folder="${folder%/}"
            folder="${folder%/*}/"
        done
        bases+=("${origin}/")
        for b in "${bases[@]}"; do
            for p in feed rss rss.xml atom.xml index.xml feed.xml; do
                try_feed "${b}${p}" || true
                done_looking && break 2
            done
        done
    fi
fi

if [[ ${#found[@]} -eq 0 ]]; then
    log "no feed found for ${site}"
    exit 1
fi

slug=$(site_slug "${site}")
readonly slug
for f in "${found[@]}"; do
    IFS="${US}" read -r f_url f_title f_author <<< "${f}"
    if [[ ${opt_csv} -eq 1 ]]; then
        f_author="${f_author//,/}"   # feeds.csv fields can't contain commas
        printf '%s,%s,%s\n' "${f_url}" "${f_author:-${slug}}" "${slug}"
    elif [[ ${opt_all} -eq 1 ]]; then
        printf '%s\t%s\n' "${f_url}" "${f_title}"
    else
        printf '%s\n' "${f_url}"
    fi
done
exit 0

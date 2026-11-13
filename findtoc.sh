#!/usr/bin/env bash

set -ueo pipefail

DIR="${BASH_SOURCE[0]%/*}"
[ "$DIR" = "${BASH_SOURCE[0]}" ] && DIR="."
readonly DIR

readonly VERSION="0.1.0"

function usage() {
    cat <<END >&2
USAGE: $0 [-t] [-p prefix] [-v|-V|-h] URL...
        -t             # print url<TAB>title, not just the url
        -p prefix      # only chapters whose path starts with prefix (default: the first two
                       # folders of each URL's path, e.g. /docs/v4/ for /docs/v4/onboarding)
        -V             # print version
        -h|?           # usage
        -v             # verbose: show each sidebar candidate

Lists the chapters of a documentation site in reading order, from the sidebar of each URL's
page: of its <nav>, <aside> and "sidebar" elements, the one with the most links under the
prefix. Several URLs (say, one per section) are listed in turn, each chapter only once.
Review the list, then make it a book with docpeyk.sh -b.
Exits 1 when a page can't be fetched or has no sidebar.

eg,
     $0 https://effect.website/docs/v4/onboarding https://effect.website/docs/v4/guides > effect.txt
     ./docpeyk.sh -b "Effect v4" - < effect.txt
     $0 -t -p /docs/ https://docs.example.com/docs/intro
END
    exit $1
}

function log() { printf '%s\n' "$*" >&2; }
function vlog() { [[ ${opt_verbose} -eq 1 ]] && log "$@"; return 0; }

declare -i opt_titles=0
declare -i opt_verbose=0
declare prefix=''

while getopts ":tp:Vhv?" opt; do
    case ${opt} in
    t) opt_titles=1 ;;
    p) prefix=${OPTARG} ;;
    V) echo "findtoc ${VERSION}"; exit 0 ;;
    v) opt_verbose=1 ;;
    h) usage 0 ;;
    \?) [[ "${OPTARG}" == "?" ]] && usage 0
        echo >&2 "ERROR: illegal option -- ${OPTARG}"
        usage 1 ;;
    :) echo >&2 "ERROR: option requires an argument -- ${OPTARG}"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))
readonly opt_titles opt_verbose prefix

[[ $# -gt 0 ]] || { echo >&2 "ERROR: expected at least one URL"; usage 1; }
for u in "$@"; do
    [[ "${u}" =~ ^https?:// ]] || { echo >&2 "ERROR: not an http(s) URL: ${u}"; usage 1; }
done
[[ -z "${prefix}" || "${prefix}" == /* ]] || { echo >&2 "ERROR: prefix must start with /: ${prefix}"; usage 1; }

for tool in curl perl; do
    command -v "${tool}" >/dev/null || { echo >&2 "error: ${tool} not found"; exit 3; }
done

readonly USER_AGENT="findtoc/${VERSION} (docpeyk; +https://github.com/abbaspour/docpeyk)"
work=$(mktemp -d "${TMPDIR:-/tmp}/findtoc.XXXXXX")
readonly work
trap 'rm -rf "${work}"' EXIT

# fetch <url> <file>  -> downloads, following redirects; prints the final URL
function fetch() {
    curl -fsL --max-time 20 -A "${USER_AGENT}" -o "$2" -w '%{url_effective}' "$1" 2>/dev/null
}

# default_prefix <url>  -> the first two folders of its path: /docs/v4/ for /docs/v4/onboarding
function default_prefix() {
    local path="${1#*://}"
    path="/${path#*/}"
    [[ "${1#*://}" == */* ]] || path=/
    path="${path%%[?#]*}"
    path="${path%/*}/"
    printf '%s' "${path}" | awk -F/ '{ out = "/"; for (i = 2; i <= NF && i <= 3; i++) if ($i != "") out = out $i "/"; print out }'
}

# sidebar_links <page url> <prefix> < html  -> "href <TAB> title" of each chapter link in the page's
# sidebar, in order, resolved against the page URL (or its <base href>), without fragments.
# The sidebar is the <nav>, <aside>, or element with "sidebar" in its id or class, holding the
# most distinct same-site links under <prefix>; ties go to the first. Exits 1 when there is none.
function sidebar_links() {
    perl -e '
        use strict; use warnings; use Encode qw(encode_utf8);
        my ($base, $prefix, $verbose) = @ARGV; local $/; my $html = <STDIN> // "";
        $html =~ s/<!--.*?-->//gs;
        $html =~ s{<(script|style|template)\b.*?</\1\s*>}{}gis;

        # decode, resolve and attrs as in findfeed.sh
        sub decode { my $s = shift;
            $s =~ s/&#(\d+);/encode_utf8(chr $1)/ge; $s =~ s/&#x([0-9a-f]+);/encode_utf8(chr hex $1)/gei;
            $s =~ s/&quot;/"/g; $s =~ s/&apos;/\x27/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g;
            $s =~ s/&nbsp;/ /g; $s =~ s/&amp;/&/g; $s }

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
        my ($host) = $base =~ m{^[a-z][a-z0-9+.-]*://([^/?#]*)}i;

        # element starting at pos: up to its matching end tag, counting nested ones of the same name
        sub element { my ($pos, $name) = @_; my $depth = 0;
            pos($html) = $pos;
            while ($html =~ m{<(/?)\Q$name\E\b[^>]*?(/?)>}gi) {
                next if $2;
                $depth += $1 ? -1 : 1;
                return substr($html, $pos, pos($html) - $pos) if $depth == 0;
            }
            return substr($html, $pos) }

        my ($best, $best_n) = ([], 0);
        my @starts;
        while ($html =~ /<(nav|aside)\b/gi) { push @starts, [$-[0], lc $1] }
        while ($html =~ /<([a-z][\w-]*)\b[^>]*\s(?:id|class)\s*=\s*["\x27][^"\x27]*sidebar/gi) { push @starts, [$-[0], lc $1] }
        for my $s (sort { $a->[0] <=> $b->[0] } @starts) {
            my $el = element(@$s);
            my (@links, %seen);
            while ($el =~ m{<a\b([^>]*)>(.*?)</a\s*>}gis) {
                my %a = attrs($1); my $text = $2;
                my $href = $a{href} // ""; next if $href eq "" || $href =~ /^\s*#/;
                my $url = resolve($base, $href); $url =~ s/#.*//;
                my ($h, $path) = $url =~ m{^https?://([^/?#]*)(/[^?#]*)?}i or next;
                next unless lc $h eq lc $host && index($path // "/", $prefix) == 0;
                next if $seen{$url}++;
                $text =~ s/<[^>]*>/ /g; $text = decode($text); $text =~ s/\s+/ /g; $text =~ s/^ | $//g;
                push @links, "$url\t$text";
            }
            printf STDERR "  <%s> at byte %d: %d chapter link(s)\n", $s->[1], $s->[0], scalar @links if $verbose;
            ($best, $best_n) = (\@links, scalar @links) if @links > $best_n;
        }
        exit 1 unless $best_n;
        print "$_\n" for @$best;' "$1" "$2" "${opt_verbose}"
}

# ---- main ------------------------------------------------------------------------------
declare -i rc=0
readonly page="${work}/page" found="${work}/found"
: > "${found}"
for u in "$@"; do
    vlog "fetching ${u}"
    if ! page_url=$(fetch "${u}" "${page}"); then
        log "ERROR: failed to fetch ${u}"
        rc=1
        continue
    fi
    p="${prefix}"
    [[ -n "${p}" ]] || p=$(default_prefix "${page_url}")
    vlog "chapters under ${p} in ${page_url}"
    if ! sidebar_links "${page_url}" "${p}" < "${page}" >> "${found}"; then
        log "no sidebar with links under ${p} found in ${u}"
        rc=1
    fi
done

# each chapter once, where it first appears
if [[ ${opt_titles} -eq 1 ]]; then
    awk -F '\t' '!seen[$1]++' "${found}"
else
    awk -F '\t' '!seen[$1]++ { print $1 }' "${found}"
fi
exit ${rc}

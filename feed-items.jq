# Normalises RSS 2.0, RSS 1.0 (RDF) and Atom feeds (as JSON from `yq -p xml -o json`)
# into one line per post:  id <US> link <US> title <US> YYYY-MM-DD
# where <US> is the ASCII unit separator (\u001f).

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

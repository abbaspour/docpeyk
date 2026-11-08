# docpeyk

Self-hosted scheduler that turns RSS/Atom feeds and web pages into EPUBs and delivers them
to your Kindle. Powered by [percollate](https://github.com/danburzo/percollate).

`docpeyk.sh` runs every hour on your Mac (launchd) or Linux machine (cron). It converts each
new blog post into its own EPUB and emails it to your Kindle through
[Send to Kindle](https://www.amazon.com/sendtokindle/email). You can also send any web page
on demand: `./docpeyk.sh <url>`. It's a small bash script around standard Unix tools,
with no cloud service and no account other than your own SMTP server.

```
feeds.csv ─curl─▶ feed.xml ─yq|jq─▶ post URLs ─┐
                                               ├─percollate─▶ <slug>/outbox/*.epub ─msmtp─▶ Kindle
ad-hoc URL ────────────────────────────────────┘                │
                                                                └─ once sent ─▶ <slug>/sent/
```

## Install

You need a Mac or a Linux machine that is on for at least part of the day, an email account
that can send through SMTP, and a Kindle. The steps below take about 15 minutes.

### 1. Install the tools

| Tool                                                                               | Used for          |
|------------------------------------------------------------------------------------|-------------------|
| [percollate](https://github.com/danburzo/percollate) (double "l") on Node >= 14.17 | page → EPUB       |
| [msmtp](https://marlam.de/msmtp/)                                                  | sending the email |
| [yq](https://github.com/mikefarah/yq) (mikefarah's), `jq`                          | reading feeds     |
| `curl`, `perl`, `openssl`, `unzip`, `git`                                          | everything else   |

**macOS** (with [Homebrew](https://brew.sh); `jq`, `curl`, `perl`, `openssl` and `unzip` ship
with macOS):

```bash
brew install msmtp yq node
PUPPETEER_SKIP_DOWNLOAD=1 npm install -g percollate
```

**Debian / Ubuntu:**

```bash
sudo apt-get install git curl jq unzip msmtp ca-certificates

sudo snap install yq     # mikefarah's yq. Not `apt install yq`: that's a different tool

sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq
```

The msmtp package asks whether to enable AppArmor. Unless you use AppArmor on purpose,
answer *No*: its profile can block the `passwordeval` command used in step 4.

**Fedora / RHEL:**

```bash
sudo dnf install git curl jq unzip msmtp perl-Unicode-Normalize cronie
sudo systemctl enable --now crond
```

**Arch:**

```bash
sudo pacman -S git curl jq unzip msmtp go-yq cronie     # go-yq is mikefarah's; "yq" is not
sudo systemctl enable --now cronie
```

**yq without snap** (Debian/Ubuntu without snap, Fedora, RHEL): use the release binary
(`yq_linux_arm64` on ARM):

```bash
sudo curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version     # must mention mikefarah
```

**Node and percollate on Linux:** install Node with [nvm](https://github.com/nvm-sh/nvm), not
the distro's `nodejs` package. Distro Node is often too old for percollate (Ubuntu 22.04 ships
12.x), and its global npm folder needs `sudo`. nvm keeps both in your home folder:

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.41.0/install.sh | bash
exec "$SHELL" -l          # or open a new terminal, so that nvm is on PATH
nvm install --lts
PUPPETEER_SKIP_DOWNLOAD=1 npm install -g percollate
command -v percollate     # e.g. ~/.nvm/versions/node/v22.x/bin/percollate
```

`PUPPETEER_SKIP_DOWNLOAD=1` skips the headless Chrome that percollate's puppeteer would
otherwise download (well over 100 MB). docpeyk only needs it for covers, which are off by
default. If you skip this step, `install.sh` (step 7) offers to install percollate for you.

### 2. Get docpeyk

```bash
git clone https://github.com/abbaspour/docpeyk.git ~/docpeyk
cd ~/docpeyk
```

The schedule remembers this folder, so keep the checkout where it is, or re-run
`./install.sh` after moving it.

### 3. Find your Kindle address and approve a sender

In Amazon's [Manage Your Content and Devices](https://www.amazon.com/mycd) (use your own
country's Amazon site), go to *Preferences* → *Personal Document Settings*:

- **Send-to-Kindle E-Mail Settings** shows your device's address, e.g. `name_abc@kindle.com`.
- **Approved Personal Document E-mail List**: add the address you'll send from in step 4.
  Amazon ignores documents from any other sender.

### 4. Configure msmtp

Create `~/.msmtprc`. This example is for a typical provider on port 587:

```
defaults
auth           on
tls            on
logfile        ~/.msmtp.log

account        default
host           smtp.example.com
port           587
from           you@example.com
user           you@example.com
passwordeval   "cat ~/.config/msmtp/password"
```

msmtp refuses a config file that other users can read, so lock it down, and put the password
in its own file:

```bash
chmod 600 ~/.msmtprc
mkdir -p ~/.config/msmtp
read -rsp 'SMTP password: ' p && printf '%s' "$p" > ~/.config/msmtp/password && unset p; echo
chmod 600 ~/.config/msmtp/password
```

- **Gmail:** host `smtp.gmail.com`, port 587. Use an
  [app password](https://myaccount.google.com/apppasswords), which needs 2-Step Verification.
  Most providers with two-factor login need an app password too.
- **Port 465** (implicit TLS): add `tls_starttls off`.
- **macOS Keychain** instead of a password file: store the password with
  `security add-generic-password -s msmtp -a you@example.com -w` and use
  `passwordeval "security find-generic-password -s msmtp -a you@example.com -w"`.
- **TLS certificate errors** on older systems: add `tls_trust_file /etc/ssl/certs/ca-certificates.crt`
  (Debian, Ubuntu, Arch) or `tls_trust_file /etc/pki/tls/certs/ca-bundle.crt` (Fedora, RHEL).
- docpeyk doesn't write a `From:` header itself; msmtp's default `set_from_header auto` adds
  one from `from`.

Send yourself (not the Kindle) a test message:

```bash
printf 'Subject: docpeyk test\n\nhello\n' | msmtp -a default you@example.com
```

### 5. Configure docpeyk

The first run creates `~/Kindle/` with a template `feeds.csv` and `kindle.conf`. Run it as
the doctor, which also reports what's still missing:

```bash
./docpeyk.sh -D
```

Edit `~/Kindle/kindle.conf` and set at least your Kindle address:

```bash
KINDLE_TO="name_abc@kindle.com"
MSMTP_ACCOUNT="default"   # account name in ~/.msmtprc
SEND_DELAY=30             # seconds between emails
MAX_SENDS_PER_RUN=5       # emails per scheduled run; the rest wait for the next hour
MAX_ATTEMPTS=3            # give up on a post after this many failed conversions
MAX_POSTS_PER_FEED=10     # only the newest posts of each feed; 0 means all
PERCOLLATE_ARGS=(--no-cover)  # extra percollate flags (see Covers below)
```

### 6. Add feeds

Add feeds to `~/Kindle/feeds.csv`, one per line: `feed_url,author,slug`. Fields can't
contain commas, and lines starting with `#` are ignored.

```
https://jvns.ca/atom.xml,Julia Evans,jvns
https://www.joelonsoftware.com/feed/,Joel Spolsky,joel
```

Don't know a blog's feed URL? `findfeed.sh` finds it from any page of the site and can
write the line for you:

```bash
./findfeed.sh jvns.ca                                # https://jvns.ca/atom.xml
./findfeed.sh -c https://jvns.ca/ >> ~/Kindle/feeds.csv
./findfeed.sh -a https://www.joelonsoftware.com/     # every feed, with titles
```

It reads the page's `<link rel="alternate">` tags, skipping comment feeds, then tries
common locations (`/feed`, `/rss.xml`, `/atom.xml`, `/index.xml`, ...), and only reports
URLs that really parse as feeds. With `-c`, the author is the feed's author, the single
author of all its posts, or else the blog's title. The slug comes from the host name.
Check both before you rely on them. Some sites, such as paulgraham.com, don't advertise
a feed at all.

### 7. Check, try it once, then schedule it

```bash
./docpeyk.sh -D                # every line should be ok (warnings are fine)
./docpeyk.sh -v -f jvns -C     # convert one feed without sending: see ~/Kindle/jvns/outbox/
./docpeyk.sh https://jvns.ca/  # send one page now, to test delivery end to end
./docpeyk.sh -v                # convert and send everything, MAX_SENDS_PER_RUN at a time
./install.sh                   # run hourly: launchd on macOS, cron on Linux
./docpeyk.sh -D                # should now say "scheduled with launchd" or "with cron"
```

On Linux, the cron daemon must be running: `systemctl status cron` (Debian, Ubuntu),
`crond` (Fedora, RHEL) or `cronie` (Arch). cron also runs while you're logged out, which suits
a headless server. On macOS the LaunchAgent runs only while you're logged in.

On the first run, the newest `MAX_POSTS_PER_FEED` posts of each feed (10 by default) are
converted, then sent `MAX_SENDS_PER_RUN` at a time, oldest first, one batch per hourly run.
Older posts are never backfilled: later runs only pick up new posts that appear among the newest
`MAX_POSTS_PER_FEED`. "Newest" goes by post date when every post in the feed has one, else by
feed order.

### Troubleshooting

`./docpeyk.sh -D` catches most problems. The log is `~/Kindle/docpeyk.log`.

| Symptom | Fix |
|---------|-----|
| `error: yq is not mikefarah/yq` | Install mikefarah's yq (step 1) and remove the other one, or put mikefarah's first on PATH. |
| `npm ERR! EACCES` installing percollate | npm's global folder needs root: use nvm (step 1), or `npm config set prefix ~/.local` and put `~/.local/bin` on PATH. |
| Works by hand, but the log says `percollate not found` | The schedule's PATH was fixed at install time. Re-run `./install.sh` after installing or upgrading Node. |
| `msmtp: ... contains secrets and therefore must have no more than user read/write permissions` | `chmod 600 ~/.msmtprc` |
| `passwordeval` fails with *Permission denied* (Debian, Ubuntu) | AppArmor: `sudo dpkg-reconfigure msmtp` and answer *No*. |
| TLS or certificate errors from msmtp | Add the `tls_trust_file` line from step 4. Use port 465 with `tls_starttls off` if your provider wants it. |
| Sent, but nothing arrives on the Kindle | Check the sender is on Amazon's approved list (step 3). Amazon emails rejections to the sender address. See also *Pending delivery* under Caveats. |
| Nothing runs on schedule (Linux) | Is the cron daemon running? `crontab -l` should show a line ending in `# docpeyk (managed by install.sh)`. |

## Ad-hoc pages

Send any web page right away, without adding a feed:

```bash
./docpeyk.sh https://example.com/some-post/
./docpeyk.sh -a "Paul Graham" https://paulgraham.com/greatwork.html https://paulgraham.com/hwh.html
./docpeyk.sh -C https://example.com/later/      # convert only; the hourly run sends it
```

- The title comes from the page. The author is `-a`, or else the page's byline.
- Files go to `~/Kindle/adhoc/outbox/` and are sent immediately to `sent/`. The send cap does
  not apply.
- If conversion or sending fails, the script exits 1. A file left in `adhoc/outbox/` is picked
  up by the next scheduled run.
- An ad-hoc run doesn't wait for a scheduled run to finish. Each folder is sent by only one
  process at a time, so nothing is emailed twice.
- `adhoc` is reserved; don't use it as a slug in `feeds.csv`.

## Layout

```
~/Kindle/
├── feeds.csv
├── kindle.conf
├── docpeyk.log              # log of every run, scheduled or by hand
├── adhoc/{outbox,sent}/     # ad-hoc pages
└── <slug>/
    ├── outbox/              # converted, not yet sent
    ├── sent/                # accepted by the SMTP server (kept forever)
    ├── seen.txt             # post ids already converted (or given up on)
    └── failed.txt           # one line per failed conversion attempt
```

Files are named `YYYY-MM-DD-post-title.epub`. The EPUB title is the post title from the
feed and the author is the `author` column from `feeds.csv`; each conversion is checked
against the EPUB's OPF metadata and a `WARN` is logged on mismatch.

## How it works

- **New posts** are decided by `seen.txt` (feed `guid`/`id`, else the link), not by what is
  in `outbox/`/`sent/`, so cleaning up those folders never causes a re-send.
- **Conversion** fetches the full article page (`percollate epub <url>`) rather than using
  the feed's content, since many feeds only carry a summary. percollate exits 0 even when
  the page fetch fails, so a conversion only counts if the EPUB actually contains an
  article. A failed conversion is retried on the next run, up to `MAX_ATTEMPTS`.
- **Covers** are off (`--no-cover`): percollate renders them with headless Chrome. To get
  generated covers, run `npx puppeteer browsers install chrome` and set
  `PERCOLLATE_ARGS=()` in `kindle.conf`. Any other percollate flags can go in that array too.
- **Sending** builds a MIME message with the EPUB attached and pipes it to `msmtp`. A file
  moves to `sent/` only when msmtp exits 0; otherwise it stays in `outbox/` and is retried.
  Files over 35 MB are skipped (Send to Kindle caps an email at 50 MB).
- **Kindle title:** Send to Kindle titles emailed documents after the attachment's file
  name, not the EPUB's `dc:title`. So the attachment is named after the post (e.g.
  `What I've learned - part 1.epub`), while the file on disk keeps its
  `YYYY-MM-DD-slug.epub` name. Characters not allowed in file names are dropped, and
  typographic quotes and dashes become ASCII. Titles that are still non-ASCII are sent
  RFC 2231-encoded (`filename*=`), with the on-disk name as an ASCII fallback.
- **Throttling:** each scheduled run sends at most `MAX_SENDS_PER_RUN` emails,
  `SEND_DELAY` seconds apart, so a backlog reaches Amazon in small batches.
- **Scheduling** on macOS uses a LaunchAgent with `StartInterval` and `RunAtLoad`. If the Mac
  was asleep at the scheduled time, launchd runs the job once on wake. Elsewhere it's a crontab
  line tagged `# docpeyk (managed by install.sh)`, at a random minute past the hour; cron
  doesn't catch up on missed runs, so a laptop asleep at that minute waits for the next hour.
  `install.sh -s cron` picks cron on macOS too. The script waits up to 60 s for the network
  and holds a lock so runs never overlap.

## Operations

```bash
launchctl kickstart gui/$(id -u)/io.github.abbaspour.docpeyk   # run now (macOS; or just ./docpeyk.sh)
tail -f ~/Kindle/docpeyk.log                                   # watch
./install.sh -u                                                 # uninstall (keeps ~/Kindle)
./install.sh -n                                                 # print the plist or crontab line
./install.sh -i 1800                                            # every 30 minutes
./docpeyk.sh -D                                                 # check the setup
./docpeyk.sh -V                                                 # print the version
```

- **Re-send a post:** move it from `<slug>/sent/` back to `<slug>/outbox/`.
- **Re-convert a post:** delete its line from `<slug>/seen.txt`.

## Caveats

- **Power Nap:** macOS does not run third-party launchd jobs during Power Nap dark wakes.
  The job runs on the next full wake (or the next hour). To get deliveries while the Mac
  is idle, schedule a wake, e.g. `sudo pmset repeat wake MTWRFSU 07:00:00`.
- **PATH is baked in at install time.** If percollate or node moves (e.g. an nvm Node
  upgrade), re-run `./install.sh`.
- Amazon reports rejected documents by email to the sender address; the pipeline can't
  see that, so check that inbox if something never arrives.
- **"Pending delivery"** in Manage Your Content is on Amazon's side. Usually it means the
  Kindle hasn't synced yet: wake it on Wi-Fi and use *Sync*. Or pick the document in Manage
  Your Content → *Deliver or Remove from Device*. Large bursts seem to make it worse, which
  is why sends are throttled.
- Sites that render posts with JavaScript may convert poorly.
- `docpeyk.log` is not rotated; it grows by a few lines per new post.
- **Moving the checkout:** the LaunchAgent or crontab line stores the absolute path of
  `docpeyk.sh`, so re-run `./install.sh` after moving or renaming the folder.

## Development

```bash
tests/run.sh               # end-to-end tests with stub percollate/msmtp, no network needed
tests/run.sh -b /bin/bash  # same, under macOS's stock bash 3.2
shellcheck -S warning docpeyk.sh findfeed.sh install.sh tests/run.sh tests/stubs/* tests/stubs-web/*
```

The tests feed RSS 2.0, Atom and RSS 1.0 fixtures from `tests/fixtures/` through the real
script, and run `findfeed.sh` against fixture websites in `tests/fixtures/sites/` through a
`curl` stand-in. They need `zip` for the stub EPUBs. CI runs them on Linux and macOS.

## Credits

The heavy lifting (fetching, Readability extraction, EPUB packaging) is done by
[percollate](https://github.com/danburzo/percollate) by Dan Burzo.

## License

[MIT](LICENSE)

*Not affiliated with or endorsed by Amazon. Kindle is a trademark of Amazon.com, Inc. or its
affiliates.*

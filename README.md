# docpeyk-kindle

Self-hosted scheduler that turns RSS/Atom feeds and web pages into EPUBs and delivers them
to your Kindle. Powered by [percollate](https://github.com/danburzo/percollate).

`docpeyk.sh` runs on your Mac every hour (via launchd). It converts each new blog post into
its own EPUB and emails it to your Kindle through
[Send to Kindle](https://www.amazon.com/sendtokindle/email). You can also send any web page
on demand: `./docpeyk.sh <url>`. It's a small bash script around standard Unix tools,
with no cloud service and no account other than your own SMTP server.

```
feeds.csv ─curl─▶ feed.xml ─yq|jq─▶ post URLs ─┐
                                               ├─percollate─▶ <slug>/new/*.epub ─msmtp─▶ Kindle
ad-hoc URL ────────────────────────────────────┘                │
                                                                └─ once sent ─▶ <slug>/sent/
```

## Requirements

```bash
npm install -g percollate   # note the double "l"; needs Node >= 14.17
brew install msmtp
```

Also used, already present on a typical setup: `yq` (`brew install yq`), `jq`, `curl`,
`perl`, `openssl`, `unzip`, `scutil` (the last five ship with macOS).

## Setup

1. **Configure msmtp** (`~/.msmtprc`) with an account that can send mail. Its `from`
   address must be on Amazon's Approved Personal Document E-mail List
   (Manage Your Content and Devices → Preferences → Personal Document Settings).
   The script relies on msmtp's default `set_from_header auto` to add the `From:` header.
   To keep the SMTP password in Keychain rather than in the file:
   ```
   passwordeval "security find-generic-password -s msmtp -a you@example.com -w"
   ```
   Test it with: `printf 'Subject: test\n\nhi\n' | msmtp -a default you@example.com`

2. **First run** creates `~/Kindle/` with a template `feeds.csv` and `kindle.conf`:
   ```bash
   ./docpeyk.sh
   ```

3. **Edit `~/Kindle/kindle.conf`** and set your Kindle address:
   ```bash
   KINDLE_TO="name_abc@kindle.com"
   MSMTP_ACCOUNT="default"   # account name in ~/.msmtprc
   SEND_DELAY=30             # seconds between emails
   MAX_SENDS_PER_RUN=5       # emails per scheduled run; the rest wait for the next hour
   MAX_ATTEMPTS=3            # give up on a post after this many failed conversions
   PERCOLLATE_ARGS=(--no-cover)  # extra percollate flags (see Covers below)
   ```

4. **Add feeds to `~/Kindle/feeds.csv`**, one per line: `feed_url,author,slug`.
   Fields can't contain commas; lines starting with `#` are ignored.
   ```
   https://jvns.ca/atom.xml,Julia Evans,jvns
   https://www.joelonsoftware.com/feed/,Joel Spolsky,joel
   ```

5. **Try it once by hand**, then install the LaunchAgent:
   ```bash
   ./docpeyk.sh -v -f jvns -C   # convert one feed, don't send
   ./docpeyk.sh -v              # convert + send everything
   ./install.sh                  # hourly via launchd
   ```

On the first run, every post currently in each feed is converted, then sent
`MAX_SENDS_PER_RUN` at a time, oldest first, one batch per hourly run.

## Ad-hoc pages

Send any web page right away, without adding a feed:

```bash
./docpeyk.sh https://example.com/some-post/
./docpeyk.sh -a "Paul Graham" https://paulgraham.com/greatwork.html https://paulgraham.com/hwh.html
./docpeyk.sh -C https://example.com/later/      # convert only; the hourly run sends it
```

- The title comes from the page. The author is `-a`, or else the page's byline.
- Files go to `~/Kindle/adhoc/new/` and are sent immediately to `sent/`. The send cap does
  not apply.
- If conversion or sending fails, the script exits 1. A file left in `adhoc/new/` is picked
  up by the next scheduled run.
- An ad-hoc run doesn't wait for a scheduled run to finish. Each folder is sent by only one
  process at a time, so nothing is emailed twice.
- `adhoc` is reserved; don't use it as a slug in `feeds.csv`.

## Layout

```
~/Kindle/
├── feeds.csv
├── kindle.conf
├── docpeyk.log             # launchd output
├── adhoc/{new,sent}/        # ad-hoc pages
└── <slug>/
    ├── new/                 # converted, not yet sent
    ├── sent/                # accepted by the SMTP server (kept forever)
    ├── seen.txt             # post ids already converted (or given up on)
    └── failed.txt           # one line per failed conversion attempt
```

Files are named `YYYY-MM-DD-post-title.epub`. The EPUB title is the post title from the
feed and the author is the `author` column from `feeds.csv`; each conversion is checked
against the EPUB's OPF metadata and a `WARN` is logged on mismatch.

## How it works

- **New posts** are decided by `seen.txt` (feed `guid`/`id`, else the link), not by what is
  in `new/`/`sent/`, so cleaning up those folders never causes a re-send.
- **Conversion** fetches the full article page (`percollate epub <url>`) rather than using
  the feed's content, since many feeds only carry a summary. percollate exits 0 even when
  the page fetch fails, so a conversion only counts if the EPUB actually contains an
  article. A failed conversion is retried on the next run, up to `MAX_ATTEMPTS`.
- **Covers** are off (`--no-cover`): percollate renders them with headless Chrome. To get
  generated covers, run `npx puppeteer browsers install chrome` and set
  `PERCOLLATE_ARGS=()` in `kindle.conf`. Any other percollate flags can go in that array too.
- **Sending** builds a MIME message with the EPUB attached and pipes it to `msmtp`. A file
  moves to `sent/` only when msmtp exits 0; otherwise it stays in `new/` and is retried.
  Files over 35 MB are skipped (Send to Kindle caps an email at 50 MB).
- **Kindle title:** Send to Kindle titles emailed documents after the attachment's file
  name, not the EPUB's `dc:title`. So the attachment is named after the post (e.g.
  `What I've learned - part 1.epub`), while the file on disk keeps its
  `YYYY-MM-DD-slug.epub` name. Characters not allowed in file names are dropped, and
  typographic quotes and dashes become ASCII. Titles that are still non-ASCII are sent
  RFC 2231-encoded (`filename*=`), with the on-disk name as an ASCII fallback.
- **Throttling:** each scheduled run sends at most `MAX_SENDS_PER_RUN` emails,
  `SEND_DELAY` seconds apart, so a backlog reaches Amazon in small batches.
- **Scheduling** uses a LaunchAgent with `StartInterval` and `RunAtLoad`. If the Mac was
  asleep at the scheduled time, launchd runs the job once on wake. The script waits up to
  60 s for the network after wake and holds a lock so runs never overlap.

## Operations

```bash
launchctl kickstart gui/$(id -u)/local.docpeyk   # run now
tail -f ~/Kindle/docpeyk.log                     # watch
./install.sh -u                                   # uninstall (keeps ~/Kindle)
./install.sh -n                                   # print the plist without installing
```

- **Re-send a post:** move it from `<slug>/sent/` back to `<slug>/new/`.
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
- **Moving the checkout:** the LaunchAgent stores the absolute path of `docpeyk.sh`, so
  re-run `./install.sh` after moving or renaming the folder.

## Credits

The heavy lifting (fetching, Readability extraction, EPUB packaging) is done by
[percollate](https://github.com/danburzo/percollate) by Dan Burzo.

*Not affiliated with or endorsed by Amazon. Kindle is a trademark of Amazon.com, Inc. or its
affiliates.*

# HEY-style email in Emacs

A HEY.com-style email workflow built on **notmuch** (read/tag) + **mbsync**
(sync) + **msmtp** (send). The Emacs side is [`hey-notmuch.el`](./hey-notmuch.el);
the backend config lives in iCloud dotfiles (`$DOTFILES/email/`) and is symlinked
into place by `$DOTFILES/email.sh`.

The idea: every sender is **screened once**, and that decision routes all their
future mail into a box. A "box" is just a notmuch tag.

---

## Daily loop

**poll → screen new senders once → read your Imbox**

1. `C-c m` — open notmuch.
2. `G` — poll (runs mbsync, indexes, applies tagging). iCloud is slow/flaky;
   the sync is capped at 120s, so poll again if it only fetched part.
3. `J s` — open the Screener and decide where each new sender belongs.
4. `J i` — read your Imbox.

---

## Opening

| Key | Action |
|-----|--------|
| `C-c m` | notmuch hello screen (boxes + counts) |
| `C-x m` | compose a new mail |
| `G`     | poll for new mail (from the hello screen) |

## The boxes — `J` then a letter

| Key | Box | Contains |
|-----|-----|----------|
| `J i` | **Imbox** | screened-in senders, unread — what matters |
| `J s` | **Screener** | new senders awaiting a decision |
| `J f` | **The Feed** | newsletters |
| `J p` | **Paper Trail** | receipts / confirmations |
| `J I` | **Seen** | screened + already read |
| `J x` | **All Inbox** | everything still in the inbox |
| `J t` | **Sent** | sent mail |

## Screening — the core action

In any message list (Screener, search, tree), put the cursor on a message and
decide where that **sender** lives from now on:

| Key | Action |
|-----|--------|
| `H i` | screen **in** → Imbox |
| `H f` | → The Feed (newsletters) |
| `H p` | → Paper Trail (prompts for a category, e.g. `amazon`) |
| `H o` | screen **out** → trash, now and forever |
| `H l` | filter the view to just this sender (preview before deciding) |

Each keypress retags **all** of that sender's existing mail *and* records the
address in a `.db` file, so future mail auto-routes on the next poll. Screen a
sender once; the Screener shrinks as you go. The `.db` files sync across machines
via iCloud, so a screening decision on one Mac applies on the other.

## Reading

| Key | Action |
|-----|--------|
| `Enter` | open thread |
| `n` / `p` | next / previous message |
| `Tab` | jump between links |
| `a` | archive (drop from inbox) |
| `V` | open in browser (remote images / tracking pixels are blocked by default) |
| `q` | back to the list |

## Composing & replying

| Key | Action |
|-----|--------|
| `C-x m` | new mail |
| `r` / `R` | reply to sender / reply-all (on an open message) |
| `C-c C-c` | send |
| `C-c C-k` | cancel draft |

The sending account (gmail / icloud) is auto-selected from the `From:` header.
Spellcheck is on in compose buffers.

---

## A good first session

1. `C-c m`, then `G` to poll.
2. `J s` (Screener) — walk down the unread list: `H o` on newsletters/noise,
   `H f` on subscriptions, `H i` on real people. Watch the count drop.
3. Poll again later — screened senders skip the Screener and land in their boxes
   automatically.

---

## Architecture / setup

- **Sync:** `mbsync -a` pulls accounts into `~/Mail/{gmail,icloud}`.
- **Index/tag:** `notmuch new` indexes; the `pre-new` hook runs mbsync, the
  `post-new` hook applies the HEY tags from the `.db` sender lists.
- **Send:** `msmtp`, account chosen from the `From:` header.
- **Secrets:** app passwords in the macOS Keychain (services `mbsync-gmail` /
  `mbsync-icloud`) — never stored in files.
- **macOS quirk:** macOS's own SASL PLAIN plugin is broken, so
  `SASL_PATH=/opt/homebrew/opt/cyrus-sasl/lib/sasl2` is exported in `.zshrc` and
  the `pre-new` hook. iCloud also drops IMAP connections mid-fetch; just poll
  again to resume.

**New machine:** `git pull` this repo, then `bash $DOTFILES/email.sh` (installs
deps, symlinks config, prompts for the two Keychain passwords), then
`SASL_PATH=/opt/homebrew/opt/cyrus-sasl/lib/sasl2 mbsync -a && notmuch new`.

**Note:** Gmail is disabled by default in `mbsyncrc` — uncomment its block and
the `Channel gmail` line in the `Group` to enable it.

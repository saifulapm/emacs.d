# HEY-style email in Emacs

A HEY.com-style email workflow on **notmuch** (index/tag/search) + **mbsync**
(sync) + **msmtp** (send) + **goimapnotify** (IMAP IDLE push).
The Emacs side is nine `lisp/hey-*.el` modules; everything else is
chezmoi-managed in `~/.dotfiles`.

The idea: every sender is **screened once**, and that decision routes all their
future mail into a box. A "box" is just a notmuch tag.

HEY itself supports no IMAP or POP — by design, permanently — so this is not a
client for HEY. It is the same workflow, rebuilt on your own mail.

---

## Daily loop

**mail arrives by itself → screen new senders once → read your Imbox**

1. `C-c m` — open notmuch.
2. `J s` — the Screener: decide where each new sender belongs, once.
3. `J i` — read your Imbox. `H P` to burn through it one key at a time.
4. `H F` — Focus & Reply: everything you owe a reply to, in one buffer.

There is no polling step. goimapnotify holds an IMAP IDLE connection, so mail
is fetched, indexed, routed and on the bar within about a second of arriving
(measured end-to-end: **10s** from `msmtp` send to routed and counted).
`G` forces a sync anyway, for impatience.

---

## Opening

| Key | Action |
|-----|--------|
| `C-c m` | notmuch hello screen (the boxes + counts) |
| `C-x m` | compose a new mail |
| `G` | sync now (normally unnecessary) |
| `J` | jump to a box from anywhere |
| `H ?` | every HEY key currently bound, described |

## The boxes — `J` then a letter

| Key | Box | Contains |
|-----|-----|----------|
| `J i` | **Imbox** | screened-in senders, unread, not yet seen — what matters |
| `J y` | **Prev. Seen** | unread, but you have glanced at it (`H v`) |
| `J s` | **Screener** | new senders awaiting a decision |
| `J f` | **The Feed** | newsletters |
| `J p` | **Paper Trail** | receipts, filed by category |
| `J l` | **Reply Later** | the pile you owe replies to |
| `J a` | **Set Aside** | reference material, near but not in front |
| `J b` | **Bubbled Up** | came back because you asked it to |
| `J n` | **Notes** | notes you wrote to yourself (`H y`) |
| `J m` | **Muted** | threads that will never bother you again |
| `J I` | **Read** | screened + already read |
| `J t` | **Sent** | sent mail |
| `J e` | **Everything** | all of it |

The Imbox is HEY's two-section box. **New for You** is `J i`; **Previously
Seen** is `J y`, and a thread moves between them with `H v` — which does *not*
mark it read, because read state belongs to iCloud and is shared with your
phone. Bundled senders (below) are excluded from both and appear as one row
per sender on the hello screen.

Most boxes are drawn as trees, so you see a conversation in context. **The
Screener is the exception** — it is drawn unthreaded, one line per unread
message. It is a list of decisions about people, not conversations, and a
sender who threads everything into one conversation would otherwise take the
screen with them: GitHub sends every security advisory with `In-Reply-To:
<repo/security-advisories@github.com>`, so nineteen of them are one thread,
and in tree view the fifteen you had already read were drawn above the four
you had not.

## HEY actions — the `H` prefix

Everything HEY-specific is under `H`, so notmuch's own keys (`a` archive,
`r`/`R` reply, `f` forward, `*` tag-all) keep working as upstream documents
them. The letter after `H` is **HEY's own key** for that action wherever one
exists, so the muscle memory transfers. `H ?` lists the lot.

Anything that acts on a thread acts on **the region** if there is one, so
"select six lines, press one key" works for labels, collections, workflows,
mute, seen, merge and Read Together.

### Screening — decide once, per sender

| Key | Action |
|-----|--------|
| `H i` | screen **in** → Imbox |
| `H f` | → The Feed |
| `H p` | → Paper Trail (prompts for a category, e.g. `shopify`) |
| `H o` | screen **out** → trashed, now and forever |
| `H u` | **undo** every decision for this sender, back to the Screener |
| `H s` | show only this sender — preview before deciding |

Each of these retags **all** of that sender's existing mail *and* records the
address in a `.db` file, so future mail auto-routes with no further thought.
Verified: one `H i` retagged 99 existing messages and every later arrival.

### The piles — per thread

| Key | Action |
|-----|--------|
| `H l` | Reply Later |
| `H a` | Set Aside |
| `H z` | Bubble Up — away until a time you pick, then back on top |
| `H c` | clear the thread out of all three piles |

`H z` takes any `org-read-date` expression — `+2d`, `fri 9am`, `next month`,
or a calendar pick. HEY offers five fixed presets.

### Standing per-contact rules

| Key | Action |
|-----|--------|
| `H C` | **Contact page** — everything about this person, in one buffer |
| `H A` | Autofile — auto-label everything this sender ever sends |
| `H R` | Recycling — auto-trash their mail after 30 / 90 / 730 days |

Recycling only **tags**; nothing is unlinked. An automated rule that deletes
mail is a rule that will one day delete the wrong mail.

### The thread itself

| Key | Action |
|-----|--------|
| `H v` | mark **seen** (not read) — moves it to Previously Seen |
| `H m` / `H M` | mute / unmute — and future replies stay out too |
| `H S` | rename the subject, locally |
| `H j` | merge the selected threads · `H C-j` open the group · `H J` unmerge |
| `H b` | who was watching: the tracker report for this thread |

Renaming never touches the mail. The override lives in `subjects.db`, keyed by
thread id, and is applied where subjects are drawn — the search list, the tree
list, the show buffer — so iCloud and your phone still see what the sender
called it.

### Grouping

| Key | Action |
|-----|--------|
| `H t` / `H T` / `H L` | add label · remove label · browse a label |
| `H k` / `H C-k` / `H K` | add to a collection · remove · open one |
| `H w` / `H C-w` / `H W` | set a workflow stage · clear · open the board |

Three namespaces, three ideas: `label/x` is a word you stuck on a thread,
`collection/x` is a pile you are building, and `wf/<name>/<stage>` is a thread
somewhere in a named process — exactly one stage at a time, which is why
moving a thread on clears the stage it came from. `H W` draws the board: one
section per stage, `RET` opens a thread, `m` moves it.

### Notes and clips

| Key | Action |
|-----|--------|
| `H n` | note on **this thread** |
| `H N` | note on **this contact** |
| `H y` | note to **yourself** — it lands in your Imbox as real mail |
| `H x` | clip the selected text into the library |
| `H X` | open the clip library |

Thread and contact notes are org, in `notes.org`, and are shown at the top of
the thread and on the contact page. A note to yourself is delivered with
`notmuch insert` into a local-only maildir, so it is searchable, countable,
archivable and repliable like anything else — and never leaves the machine.

Clips keep the useful paragraph instead of the whole mail: the door code, the
account number, the sentence where they agreed the price. Each one remembers
the message it came from (`m` in the library opens it), and `/` searches them.

### Moving through mail

| Key | Action |
|-----|--------|
| `H P` | **Power Through New** — one thread at a time, one key per decision |
| `H F` | **Focus & Reply** — every Reply Later thread, each open for replying |
| `H r` | **Read Together** — the selected threads in one scrollable buffer |
| `H D` | **All Files** — every attachment, without finding the thread first |

**Power Through** shows one thread with a progress header and turns every HEY
action into a single key — the same letters as under `H`, so `i`, `f`, `p`,
`o`, `l`, `a`, `z` mean what they always mean. `e` archives, `n`/`SPC` moves
on, `b` goes back, `q` stops. Called from a list it powers through *that*
list; anywhere else it powers through the Screener.

**Focus & Reply** is the one HEY calls a game changer, and it is. Every thread
in Reply Later, quoted, each followed by a box you type your reply into.
`C-c C-c` sends it through notmuch's own reply path (so the headers, the Fcc
into Sent and the threading are identical to any other reply), drops the
thread out of Reply Later and removes it from the buffer. `C-c C-d` clears one
without replying, `C-c C-o` opens the real thread, `C-c C-n`/`C-c C-p` move
between boxes. The quoted mail is read-only; the boxes are not.

**All Files** lists every named attachment in the mailbox — 43 of them here,
scanned live in 20ms. `RET` opens it in Emacs, `x` hands it to the desktop,
`s` saves it, `m` opens the message it came on, `/` narrows by any notmuch
query.

### Bundling

A prolific sender can be **bundled** from their contact page (`B`). Their
threads leave the Imbox list and appear as one row — sender and count — in a
Bundles section on the hello screen. Nothing is archived, nothing is marked
read; they are simply not allowed to be twenty rows.

## The contact page — `H C`

HEY reaches this by clicking an avatar. It is one buffer per person:

* where their mail is routed, and every screening key to change it
  (`i` `f` `p` `o` `u`)
* whether they may notify you (`!`) — off for everyone by default
* autofile (`A`), recycling (`R`), bundling (`B`)
* your note about them (`n`)
* how much mail, in how many threads, how much unread, when you first heard
  from them, how much you have sent back
* their last five attachments and last ten threads — `RET` opens either
* `s` to search their mail, `W` to write to them, `g` to redraw

Rendered from scratch every time (about 70ms for a sender with 99 messages),
because a contact page that lies about where somebody's mail goes is worse
than no contact page at all.

## Composing

| Key | Action |
|-----|--------|
| `r` / `R` | reply / reply-all · `C-c C-c` send · `C-c C-k` cancel |
| `H E` | **Reply to Everyone** — everyone in the thread, not just this message |
| `C-c s` / `C-c S` | insert a snippet · save the region as one |
| `C-c f` | attach a **big file** through the dufs server |
| `C-c n` | edit your **Name Tag** (the signature) |

`R` answers the recipients of one message; `H E` answers everyone who wrote,
was written to, or was copied anywhere in the thread — which on a forwarded
thread is a different, usually more correct, set.

`C-c f` copies the file into `~/Public/hey-mail`, which the dufs server
already publishes, and inserts a link. It offers to start the server if it is
off. LAN-only and password-gated: this is for the other machines in the house
and for yourself, not HEY's upload-to-the-cloud feature.

### Which address you send as

One iCloud account, several iCloud+ custom domains, one inbox — so every
message needs an answer to "which of me is sending this?".

**Replies answer themselves.** `notmuch reply` sets the From: to whichever of
your addresses the original was delivered to, so a mail to `support@` on one
domain is answered from `support@` on that domain, with no prompt and no
thought. That works because every address is listed in `user.other_email` in
the notmuch config.

**New mail asks** (`notmuch-always-prompt-for-sender`), offering
`primary_email` plus every `other_email`, because nothing in a blank message
can tell you which hat you are wearing.

The list lives in the machine-local chezmoi config as `mailIdentities`
(semicolon-separated), never in this repo:

```
~/.config/chezmoi/chezmoi.toml   →  [data] mailIdentities = "a@x;b@y;…"
   ↓ chezmoi apply
~/.config/notmuch/default/config →  [user] other_email=a@x;b@y;…
```

Add a domain by editing that one line and running `chezmoi apply
~/.config/notmuch/default/config`. Two rules: iCloud authenticates as the
**iCloud address** whatever the From says (that is what `~/.msmtprc` holds),
and it will only send as an address it has actually been configured with —
catch-all delivers anything at a domain, but sending as an address iCloud does
not know is refused at the server.

## Settings — `H ,`

| Key | Setting |
|-----|---------|
| `H , s` | **Speakeasy** — show the code; `C-u` regenerates it |
| `H , a` | **Away** — the out-of-office autoresponder |
| `H , n` | **Name Tag** — your signature |
| `H , N` | open `notes.org` |
| `H , S` | open `snippets.org` |

The **Speakeasy** code is a private word-plus-digits token that walks a
stranger past the Screener when it appears in the subject line. One
alphanumeric token, no hyphen: notmuch matches subjects through Xapian's
tokeniser, which splits on every non-alphanumeric character — verified on this
mailbox, where `subject:"Cool9977"` matches 18 messages while `ool9977` and
`Cool997` match none. Regenerating retires the old code instantly.

**Away** is the only thing here that talks to the outside world, so it is the
most heavily guarded. iCloud's vacation responder is out of reach and msmtp
only sends, so the post-new hook sends the replies — to screened-in senders
only, once per address ever, never to a mailing list, never to auto-submitted
mail, never to a no-reply address, never to you, and at most ten per sync.
Every one of those rules has cost somebody a mail loop at some point. The
reply carries `Auto-Submitted: auto-replied`, which is how a well-behaved
responder on the other side knows not to answer back. It needs an `until:`
date, and turning it off forgets who has already been replied to.

## Reading

| Key | Action |
|-----|--------|
| `Enter` | open thread · `n`/`p` next/prev · `Tab` next link |
| `a` | archive (drop from inbox) |
| `V` | open in a browser (remote images are blocked by default) |

Remote images are blocked outright, so tracking pixels never load and no
sender learns when — or how often — you opened their mail. On top of that,
every thread reports what was blocked and **who by**:

```
  1 spy tracker blocked — facebook.com · 4 other remote images not loaded
```

The classification is a list of the usual platforms plus the patterns they all
share (`/wf/open`, `/o/`, `pixel`, `beacon`, `utm_`, a `.gif` with a query
string). Verified against real mail here: an Anthropic newsletter's five
`claude.ai` images counted as images, and its
`url…mail.anthropic.com/wf/open?upn=…` beacon counted as a tracker.

---

## Architecture

```
iCloud IMAP ──IDLE──> goimapnotify ──> bin/mail-sync ──> mbsync ──> ~/Mail/icloud
                                                            │
                                                      notmuch new
                                                            └── post-new hook:
                                                                folder fixups, Speakeasy,
                                                                sender routing, bundling,
                                                                Bubble Up · recycling ·
                                                                mute sweeps, away replies,
                                                                bar counts, Emacs refresh,
                                                                notifications
```

**Division of labour** — Emacs writes *decisions* (a line in a `.db`) and
retags what already exists. The hook *applies* those decisions to mail that
arrives later. Neither re-implements the other.

| Where | What |
|---|---|
| `~/.mbsyncrc` | sync (a blank line **ends a section** — do not add one mid-block) |
| `~/.config/notmuch/default/config` | index; `synchronize_flags` mirrors read state to the phone |
| `~/.config/notmuch/hooks/post-new` | the router — 11 steps, none of which may kill the next |
| `~/.msmtprc` | send (`tls_trust_file system`, never a hardcoded path) |
| `~/.config/imapnotify/icloud.yaml` | IDLE watcher |
| `~/.dotfiles/bin/mail-sync` | the one "get mail now" entry point, flock-serialised |
| `~/.local/share/hey-mail/` | every decision below — **never** committed anywhere |

### The decision files

| File | Shape | Written by |
|---|---|---|
| `screened.db` `thefeed.db` `spam.db` | one address per line | `H i` `H f` `H o` |
| `ledger.db` | `<category> <address>` | `H p` |
| `autofile.db` | `<address> <label>` | `H A` |
| `recycle.db` | `<address> <days>` | `H R` |
| `bubble.db` | `<thread-id> <epoch>` | `H z` |
| `notify.db` | one address per line | contact page `!` |
| `bundle.db` | one address per line | contact page `B` |
| `subjects.db` | `<thread-id> <your subject>` | `H S` |
| `workflows.db` | `<name> <stage>,<stage>,…` | `H w` |
| `speakeasy` `nametag` `away` | one value each | `H ,` |
| `away-replied.db` | one address per line | the hook |
| `notes.org` `clips.org` `snippets.org` | org | `H n` `H x` `C-c S` |

They are plain text because the other reader is a bash script — and because a
decision you can inspect with `cat` is a decision you can fix when the elisp
is wrong.

### The Emacs modules

| File | What |
|---|---|
| `hey-notmuch.el` | the boxes, screening, the piles, Speakeasy, sync, the `H` map, and the plumbing everything else shares |
| `hey-notes.el` | notes on a thread, a contact, or yourself; the org file format the others reuse |
| `hey-labels.el` | labels, collections, workflows, the board |
| `hey-files.el` | the MIME part walker, and the All Files screen |
| `hey-contact.el` | Mission Control, and the per-contact rules with no other home |
| `hey-flow.el` | Power Through, Focus & Reply, Read Together, the Bundles section |
| `hey-clips.el` | the clip library |
| `hey-compose.el` | snippets, Name Tag, Away, Reply to Everyone, big files |
| `hey-thread.el` | seen, mute, rename, merge, the tracker report |

Loaded in that order from `init.el`; each defers notmuch itself, so all nine
cost nothing until `C-c m`.

**Tag vocabulary** — shared by the hook and the elisp; change one, change both:

```
inbox unread screened thefeed ledger/<cat> spam deleted archived sent draft
replylater setaside bubble bubbled seen bundled muted note speakeasy new
label/<x> collection/<x> wf/<name>/<stage> merge/<id>
```

**Secrets** — the iCloud app-specific password is in `pass
email/icloud/<local-part>`; no config file contains it. Your address is not in
either public repo: the dotfiles read `mailUser` from the machine-local
`~/.config/chezmoi/chezmoi.toml`, and this file reads it back out of the
notmuch config at load time.

**Units** — `imapnotify@icloud.service` (IDLE), `mail-sync.timer` (15 min
fallback, because IDLE connections die quietly and a push-only design sits
there looking healthy while fetching nothing). Both session-tied to
`graphical-session.target`, like `emacs.service`, because `pass` needs a
gpg-agent that can draw a pinentry.

**New machine** — `chezmoi init --apply`, answer the mail-address prompt,
`pass` clone, then the first `mbsync --pull icloud && notmuch new`.

---

## Where this beats HEY

Real query language (`from:`/`subject:`/`date:`/`tag:`/`attachment:` + regex +
boolean) instead of one text box · sub-second IDLE push instead of polling ·
fully offline, the maildir *is* the store · arbitrary Bubble Up times ·
bulk-screen a whole domain or List-Id in one action · every thread action
works on a selection · workflows and collections, which HEY has no equivalent
of · counts in the system bar · $0 instead of $99/yr.

## Where HEY still wins

**Mobile** — no Emacs on your phone. Read/unread already syncs both ways;
making the boxes visible there needs the tag→IMAP-folder mapping (Phase 4).
**Big files** — theirs are a link anyone on the internet can fetch; ours are a
link anyone on the LAN can fetch. **Calendar and Journal** — a separate
project (org-agenda + CalDAV).

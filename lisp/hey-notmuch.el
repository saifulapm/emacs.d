;;; hey-notmuch.el --- HEY.com-style email with notmuch  -*- lexical-binding: t; -*-

;; A HEY.com-style email workflow on top of notmuch + mbsync + msmtp.
;;
;; The backend lives outside Emacs and is chezmoi-managed in ~/.dotfiles:
;;   ~/.mbsyncrc                        sync        (isync)
;;   ~/.config/notmuch/default/config   index       (notmuch)
;;   ~/.config/notmuch/hooks/post-new   THE ROUTER  (tags, sweeps, bar counts)
;;   ~/.msmtprc                         send        (msmtp)
;;   ~/.config/imapnotify/icloud.yaml   IMAP IDLE   (goimapnotify)
;;   bin/mail-sync                      the "get mail now" entry point
;;
;; The HEY idea: every sender is screened ONCE, and that decision routes all
;; their future mail into a box. Here a "box" is just a notmuch tag, and the
;; screening commands below both retag that sender's existing mail AND append
;; the address to a .db file, so the post-new hook keeps routing them without
;; being asked again.
;;
;; Division of labour, so neither side re-implements the other:
;;   * Emacs writes DECISIONS (a line in a .db file) and retags what exists.
;;   * The post-new hook APPLIES those decisions to mail that arrives later,
;;     sweeps Bubble Up and recycling, and publishes the bar counts.
;; Nothing here polls or syncs; goimapnotify does that within ~1s of arrival.

;;; Code:

(require 'subr-x)
(require 'seq)

;; notmuch is loaded on demand (`use-package … :commands' below), so at compile
;; time none of its functions exist yet.  Declaring them keeps the build free
;; of "might not be defined at runtime" noise WITHOUT pulling the whole of
;; notmuch into every Emacs session that merely loads this file — the point of
;; deferring it in the first place.  A warning-free build is worth having
;; because the next real warning is then visible; a build with fifteen
;; expected warnings is a build nobody reads.
(declare-function org-read-date "org")
(declare-function notmuch-user-name "notmuch-lib")
(declare-function notmuch-user-primary-email "notmuch-lib")
(declare-function notmuch-refresh-all-buffers "notmuch-lib")
(declare-function notmuch-tag "notmuch-tag")
(declare-function notmuch-call-notmuch-sexp "notmuch-lib")
(declare-function notmuch-jump-search "notmuch-jump")
(declare-function notmuch-search-filter "notmuch")
(declare-function notmuch-search-find-subject "notmuch")
(declare-function notmuch-search-find-thread-id "notmuch")
(declare-function notmuch-search-next-thread "notmuch")
(declare-function notmuch-show-get-from "notmuch-show")
(declare-function notmuch-show-get-message-id "notmuch-show")
(declare-function notmuch-show-get-subject "notmuch-show")
(declare-function notmuch-tree-get-message-id "notmuch-tree")
(declare-function notmuch-tree-get-message-properties "notmuch-tree")
(declare-function notmuch-tree-get-prop "notmuch-tree")
(declare-function notmuch-tree-next-matching-message "notmuch-tree")
(declare-function notmuch-unthreaded "notmuch-tree")
(defvar notmuch-show-thread-id)
(defvar notmuch-command)
(defvar kao-global-modes)

(defgroup hey-notmuch nil
  "HEY.com-style email workflow on notmuch."
  :group 'mail
  :prefix "hey-notmuch-")

(defcustom hey-notmuch-db-dir
  (expand-file-name "hey-mail" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Directory holding the HEY sender-decision databases.

Read by the notmuch post-new hook, written by the commands in this file.
Deliberately NOT inside this repo: it is a list of everyone who emails
you, and github.com/saifulapm/emacs.d is public.  Deliberately not inside
~/Mail either, so wiping the maildir to re-sync from scratch cannot take
your screening decisions with it."
  :type 'directory
  :group 'hey-notmuch)

(defcustom hey-notmuch-sync-command "mail-sync"
  "Program run by \\[hey-notmuch-sync] to fetch mail now.

The same entry point imapnotify and the fallback timer use, so a manual
poll and a pushed one do exactly the same work.  It is flock-serialised,
so pressing this while a push is mid-flight is harmless."
  :type 'string
  :group 'hey-notmuch)

;; ─────────────────────────── notmuch core ───────────────────────────
(use-package notmuch
  :ensure t
  :commands (notmuch notmuch-search notmuch-tree notmuch-mua-new-mail)
  :bind (("C-c m" . notmuch)
         ("C-x m" . notmuch-mua-new-mail))
  :custom
  ;; The HEY boxes, in HEY's own order. `J' (bound below) jumps to one by key.
  ;; Queries match the vocabulary the post-new hook writes — change one, change
  ;; both.
  ;;
  ;; The Imbox is HEY's two-section box: "New for You" on top, "Previously
  ;; Seen" underneath.  `seen' is what `H v' writes — you glanced at a thread
  ;; and it is no longer news, but you have NOT opened it, so `unread' (which
  ;; iCloud owns) is untouched.  `bundled' is the prolific-sender roll-up,
  ;; excluded here because those threads are shown as one row per sender in
  ;; the Bundles section of the hello screen instead (hey-flow.el).
  (notmuch-saved-searches
   '((:name "Imbox"       :query "tag:inbox and tag:screened and tag:unread and not tag:seen and not tag:bundled" :key "i" :search-type tree)
     (:name "Prev. Seen"  :query "tag:inbox and tag:screened and tag:unread and tag:seen"                         :key "y" :search-type tree)
     ;; UNTHREADED, alone among the boxes.  Tree view draws the whole thread
     ;; around every match, which is right when you are reading a conversation
     ;; and wrong here: the Screener is a list of decisions about PEOPLE, and a
     ;; sender who threads a year of notifications into one conversation
     ;; hijacks the screen with it.  Measured on this mailbox — GitHub sends
     ;; every security advisory with `In-Reply-To:
     ;; <repo/security-advisories@github.com>', so nineteen advisories are one
     ;; thread; four were unread and the fifteen already-read ones were drawn
     ;; above them in grey, pushing fifteen real decisions off the screen.
     ;; Unthreaded draws one line per MATCHING message and nothing else.
     (:name "Screener"    :query "tag:inbox and tag:unread and not tag:screened" :key "s" :search-type unthreaded)
     (:name "The Feed"    :query "tag:thefeed and tag:unread"                    :key "f" :search-type tree)
     (:name "Paper Trail" :query "tag:/^ledger\\//"                              :key "p")
     (:name "Reply Later" :query "tag:replylater"                                :key "l" :search-type tree)
     (:name "Set Aside"   :query "tag:setaside"                                  :key "a" :search-type tree)
     (:name "Bubbled Up"  :query "tag:bubbled and tag:unread"                    :key "b" :search-type tree)
     ;; Named "Read", not "Seen": since `H v' introduced HEY's own meaning of
     ;; seen (glanced at, still unread), two boxes called Seen would be two
     ;; different questions wearing one name.
     (:name "Read"        :query "tag:inbox and tag:screened and not tag:unread" :key "I")
     ;; `note' is written by `hey-notes-inbox' (hey-notes.el), which delivers a
     ;; note to yourself as a real message so it sits in the Imbox next to the
     ;; mail it is about — HEY's own behaviour, and the reason all the boxes
     ;; are listed here rather than each module pushing its own: this variable
     ;; is set by use-package's `:custom' when notmuch loads, so a later push
     ;; from a module would simply be overwritten.
     (:name "Notes"       :query "tag:note"                                      :key "n" :search-type tree)
     (:name "Muted"       :query "tag:muted"                                     :key "m" :search-type tree)
     (:name "Sent"        :query "tag:sent"                                      :key "t")
     (:name "Everything"  :query "*"                                             :key "e")))
  ;; Show every box even when empty: HEY's layout is fixed, and a box that
  ;; vanishes when it empties is a box you stop trusting.
  (notmuch-show-empty-saved-searches t)
  ;; `hey-notmuch-hello-extras' is the one seam the modules draw through: this
  ;; variable is set by `:custom' when notmuch loads, which is AFTER the
  ;; modules have loaded, so a module that pushed itself onto the list
  ;; directly would simply be overwritten.  It runs a hook instead, which
  ;; modules can add to whenever they like.
  (notmuch-hello-sections '(notmuch-hello-insert-saved-searches
                            hey-notmuch-hello-extras))
  (notmuch-hello-thousands-separator "")
  (notmuch-show-logo nil)
  (notmuch-search-oldest-first nil)
  (notmuch-archive-tags '("-inbox" "+archived"))
  ;; Sent mail is filed into iCloud's own Sent maildir; mbsync pushes it up on
  ;; the next sync, so it appears on the phone too. Single account, so this
  ;; needs no address to key on — which also keeps the address out of this
  ;; public repo.
  ;; QUOTED, and it has to be.  notmuch's Fcc header is "folder +tag -tag",
  ;; and notmuch.el pulls it apart with `split-string-and-unquote' — so an
  ;; unquoted "icloud/Sent Messages" reaches the CLI as `--folder=icloud/Sent'
  ;; plus a stray argument `Messages', and every send ends at the prompt
  ;; "Insert failed: (r)etry, (c)reate folder, (i)gnore, or (e)dit the
  ;; header?" with the mail already gone and no copy filed.  iCloud named the
  ;; folder, not us; the double quotes are what `split-string-and-unquote'
  ;; documents for exactly this case.
  ;; The tag operations after the folder are not decoration.  `notmuch insert'
  ;; applies `new.tags' to whatever it files, and new.tags here is
  ;; "unread;inbox;new" — so without them every message you send lands in your
  ;; own Screener, unread, as though a stranger had sent it, and stays there
  ;; until the next sync runs the post-new hook's folder fixup.  Measured: one
  ;; test send took the Screener from 219 to 220.  Tagging at insert time
  ;; fixes it at the source; the hook's fixup stays for the copies that come
  ;; DOWN from iCloud when you send from the phone.
  (notmuch-fcc-dirs "\"icloud/Sent Messages\" +sent -inbox -unread -new")
  ;; Several addresses arrive in this one mailbox — the iCloud+ custom domains
  ;; — so "which of me is sending this?" is a real question and gets asked.
  ;;
  ;; REPLIES are not affected and do not need to be: `notmuch reply' fills the
  ;; From: itself, choosing whichever of `user.primary_email' /
  ;; `user.other_email' the original was addressed to.  Verified against real
  ;; mail — a message to support@<domain> replies as support@<domain>, one to
  ;; info@<other domain> replies as info@<other domain>.  The prompt is only
  ;; for new mail and forwards, where nothing in the message can tell you
  ;; which hat you are wearing.
  ;;
  ;; The list the prompt offers is built from the notmuch config, not from
  ;; `notmuch-identities' — one place to add a domain, and it is the machine's
  ;; own file rather than this public repo.
  (notmuch-always-prompt-for-sender t)
  ;; Privacy: block ALL remote images, so tracking pixels never load and no
  ;; sender learns when (or how often) you opened their mail. HEY blocks these
  ;; and reports them; we simply never make the request. `V' opens the message
  ;; in a browser on the rare occasion the images are the point.
  (notmuch-show-text/html-blocked-images ".")
  (mm-text-html-renderer 'shr)
  :hook ((notmuch-message-mode . turn-off-auto-fill)
         (notmuch-message-mode . flyspell-mode))
  :config
  ;; Identity comes from the notmuch config, which chezmoi renders from the
  ;; machine-local `mailUser'. Hardcoding it here would publish an IMAP login
  ;; address to a public repo — the same reason the dotfiles templates read it
  ;; from chezmoi data rather than naming it.
  (setq user-mail-address (notmuch-user-primary-email)
        user-full-name    (notmuch-user-name))
  ;; `J' = jump to a HEY box from anywhere in notmuch (HEY's own `H' menu).
  ;; The show buffer included: finishing with a message and going straight to
  ;; another box is the commonest move there is, and leaving `J' out of it
  ;; meant the one screen where you have actually finished something was the
  ;; one screen you could not leave by key.
  (define-key notmuch-search-mode-map (kbd "J") #'notmuch-jump-search)
  (define-key notmuch-tree-mode-map   (kbd "J") #'notmuch-jump-search)
  (define-key notmuch-hello-mode-map  (kbd "J") #'notmuch-jump-search)
  (define-key notmuch-show-mode-map   (kbd "J") #'notmuch-jump-search))

;; ───────────────────────────── sending ──────────────────────────────
(with-eval-after-load 'message
  (setq message-send-mail-function 'message-send-mail-with-sendmail
        sendmail-program (executable-find "msmtp")
        message-sendmail-envelope-from 'header
        message-sendmail-f-is-evil nil
        message-kill-buffer-on-exit t)
  ;; message.el auto-saves drafts to `message-directory'/drafts, which is
  ;; ~/Mail/drafts — INSIDE notmuch's database.path.  Left alone, a compose
  ;; buffer that lives long enough to auto-save (or an Emacs that dies with
  ;; one open) drops a half-written mail where the next `notmuch new' indexes
  ;; it, and your own unfinished draft turns up in the Screener addressed by
  ;; nobody.  Found the empty ~/Mail/drafts this creates on its own; moved
  ;; before it had anything in it.  `auto-save-file-name-transforms' in
  ;; init.el does not cover this — message-mode sets the auto-save name
  ;; itself and never consults them.
  (setq message-auto-save-directory
        (expand-file-name "message-drafts/" (locate-user-emacs-file ".cache/")))
  (make-directory message-auto-save-directory t)
  (add-hook 'message-send-mail-hook #'hey-notmuch--choose-msmtp-account))

;; One account today, but the account is still selected explicitly rather than
;; left to msmtp's `default' — adding a second one then means adding a branch
;; here, not discovering that everything silently went out as iCloud.  Defined
;; at top level, not inside the `with-eval-after-load' above, so the byte
;; compiler can see it when it compiles the `add-hook'.
(defun hey-notmuch--choose-msmtp-account ()
  "Send through the `icloud' msmtp account rather than msmtp's default."
  (when (message-mail-p)
    (setq-local message-sendmail-extra-arguments (list "-a" "icloud"))))

;; ──────────────────────── shared plumbing ───────────────────────────
(defun hey-notmuch--from-address ()
  "Best-effort sender address of the message/thread at point."
  (let ((raw (pcase major-mode
               ('notmuch-show-mode (notmuch-show-get-from))
               ('notmuch-tree-mode
                (plist-get (plist-get (notmuch-tree-get-message-properties) :headers) :From))
               ('notmuch-search-mode
                (car (ignore-errors
                       (process-lines notmuch-command "address" "--output=sender"
                                      (notmuch-search-find-thread-id))))))))
    (when (and raw (stringp raw))
      (downcase (or (cadr (mail-extract-address-components raw)) raw)))))

(defun hey-notmuch--threads-of (message-ids)
  "Bare thread ids of MESSAGE-IDS, deduplicated, in one notmuch call."
  (when message-ids
    (mapcar (lambda (s) (string-remove-prefix "thread:" s))
            (ignore-errors
              (process-lines notmuch-command "search" "--output=threads"
                             (mapconcat (lambda (id) (format "id:%s" id))
                                        message-ids " or "))))))

(defun hey-notmuch--thread-id ()
  "Bare thread id (no \"thread:\" prefix) of the thread at point."
  ;; `notmuch-show-thread-id' is a buffer-local VARIABLE (defvar-local,
  ;; notmuch-show.el:223), not an accessor function — calling it would signal
  ;; void-function in every show buffer.
  (let ((tid (pcase major-mode
               ('notmuch-show-mode   notmuch-show-thread-id)
               ;; A tree buffer knows only about MESSAGES.  Its per-line
               ;; property list is :id :match :excluded :filename :timestamp
               ;; :date_relative :tags :duplicate :crypto :headers :first
               ;; :tree-status :orig-tags :level :previous-subject — verified
               ;; against a live tree buffer, and there is no thread among
               ;; them.  An earlier version asked for `:thread' here and got
               ;; nil, which meant every per-thread key (`H l', `H a', `H z',
               ;; `H c') failed with "No thread at point" in exactly the boxes
               ;; that are drawn as trees — which is most of them.  So ask the
               ;; database which thread the message belongs to.
               ('notmuch-tree-mode
                (car (hey-notmuch--threads-of
                      (list (notmuch-tree-get-message-id t)))))
               ('notmuch-search-mode (notmuch-search-find-thread-id)))))
    (when (stringp tid)
      (string-remove-prefix "thread:" tid))))

(defun hey-notmuch--tag-by-from (tag-changes &optional addr)
  "Apply TAG-CHANGES to all mail from ADDR (or the sender at point).
Return ADDR.  Retagging the sender's WHOLE history, not just this
message, is the point: HEY's promise is that one decision cleans up
everything they have ever sent you."
  (let ((addr (or addr (hey-notmuch--from-address))))
    (unless addr (user-error "No sender address at point"))
    (notmuch-tag (format "from:%s" addr) tag-changes)
    addr))

(defun hey-notmuch--tag-thread (tag-changes)
  "Apply TAG-CHANGES to the whole thread at point."
  (let ((tid (hey-notmuch--thread-id)))
    (unless tid (user-error "No thread at point"))
    (notmuch-tag (concat "thread:" tid) tag-changes)
    tid))

(defun hey-notmuch--message-id ()
  "Bare Message-Id of the message at point.

In a search buffer there is no message at point, only a thread, so the
newest message of the thread stands in for it — that is the one you are
looking at in the summary line and the one a note or a clip means."
  (pcase major-mode
    ('notmuch-show-mode (notmuch-show-get-message-id t))
    ('notmuch-tree-mode (notmuch-tree-get-message-id t))
    ('notmuch-search-mode
     (let ((tid (hey-notmuch--thread-id)))
       (when tid
         (car (ignore-errors
                (mapcar (lambda (id) (string-remove-prefix "id:" id))
                        (process-lines notmuch-command "search" "--output=messages"
                                       "--sort=newest-first" "--limit=1"
                                       (concat "thread:" tid))))))))))

(defun hey-notmuch--subject ()
  "Subject of the message/thread at point, or nil."
  (pcase major-mode
    ('notmuch-show-mode   (notmuch-show-get-subject))
    ('notmuch-search-mode (notmuch-search-find-subject))
    ('notmuch-tree-mode
     (plist-get (plist-get (notmuch-tree-get-message-properties) :headers) :Subject))))

(defun hey-notmuch--region-thread-ids ()
  "Thread ids under the region, or a one-element list for the thread at point.

The whole multi-thread family — Read Together, merge, mute a batch — takes
its input from here, so \"select some lines, act on them\" is one idea
learned once rather than one per command.  notmuch's own `*' works the
same way for tagging."
  (if (not (and (region-active-p)
                (memq major-mode '(notmuch-search-mode notmuch-tree-mode))))
      (let ((tid (hey-notmuch--thread-id)))
        (and tid (list tid)))
    (save-excursion
      (let ((end (region-end))
            (tree (derived-mode-p 'notmuch-tree-mode))
            (ids nil))
        (goto-char (region-beginning))
        (beginning-of-line)
        (while (and (< (point) end) (not (eobp)))
          ;; In a tree buffer collect MESSAGE ids and resolve the whole lot to
          ;; threads in one notmuch call below: a line-by-line lookup would be
          ;; one process per line, and a fifty-line region would take longer
          ;; than reading the fifty mails.  A thread spanning several lines
          ;; collapses to one id there, and is deduplicated here otherwise.
          (let ((id (if tree
                        (notmuch-tree-get-message-id t)
                      (hey-notmuch--thread-id))))
            (when (and (stringp id) (not (member id ids)))
              (push id ids)))
          (forward-line 1))
        (setq ids (nreverse ids))
        (if tree (delete-dups (hey-notmuch--threads-of ids)) ids)))))

;; ─────────────────── the hello screen, extended ─────────────────────
(defvar hey-notmuch-hello-section-functions nil
  "Extra sections HEY modules draw on the notmuch hello screen.
Each function is called with no arguments, in a widget buffer, after the
saved searches have been drawn.")

(defun hey-notmuch-hello-extras ()
  "Run `hey-notmuch-hello-section-functions'.
Listed in `notmuch-hello-sections' so modules loaded later than notmuch
still get a say in what the hello screen shows."
  (run-hooks 'hey-notmuch-hello-section-functions))

;; ──────────────────────── asking notmuch ───────────────────────────
(defun hey-notmuch--count (query &optional threads)
  "Number of messages — or THREADS — matching QUERY."
  (string-to-number
   (or (car (ignore-errors
              (apply #'process-lines notmuch-command "count"
                     (append (when threads '("--output=threads")) (list query)))))
       "0")))

(defun hey-notmuch--count-batch (queries &optional threads)
  "Counts for QUERIES, in order, as a list of numbers.

One `notmuch count --batch' rather than one process per query: the
contact page asks eight questions about a sender and the workflow board
asks one per stage, and at ~25ms of process startup each that is the
difference between a page that appears and a page that arrives."
  (if (null queries)
      nil
    (with-temp-buffer
      (let ((args (append (list "count") (when threads '("--output=threads")) '("--batch"))))
        (apply #'call-process-region
               ;; The query list goes in on stdin; an empty line would ask for
               ;; the whole database, so a blank query is sent as "()" — an
               ;; empty conjunction, which matches nothing, like the caller
               ;; meant.
               (mapconcat (lambda (q) (if (string-empty-p (string-trim q)) "()" q))
                          queries "\n")
               nil notmuch-command nil t nil args))
      (mapcar #'string-to-number
              (split-string (buffer-string) "\n" t)))))

(defun hey-notmuch--search (query &rest args)
  "Parsed `notmuch search' output for QUERY as a list of plists.
ARGS are extra command-line arguments, e.g. \"--limit=20\"."
  (ignore-errors
    (apply #'notmuch-call-notmuch-sexp
           "search" "--format=sexp" "--format-version=5" (append args (list query)))))

(defun hey-notmuch--tags-in-namespace (prefix &optional query)
  "Bare names of every tag under PREFIX (e.g. \"label/\"), across QUERY.

Sorted, deduplicated, and taken from the database rather than from a file
we maintain: a tag that exists is a label that exists, whether this file
knows about it or not."
  (let ((tags (ignore-errors
                (process-lines notmuch-command "search" "--output=tags"
                               "--exclude=false" (or query "*")))))
    (sort (delete-dups
           (delq nil (mapcar (lambda (tag)
                               (and (string-prefix-p prefix tag)
                                    (substring tag (length prefix))))
                             tags)))
          #'string<)))

;; ─────────────────────── the decision files ─────────────────────────
;; Everything Emacs decides and the hook must honour later lives as plain
;; lines in `hey-notmuch-db-dir': one file per kind of decision, `#' comments
;; allowed, blank lines ignored.  Plain text because the other reader is a
;; bash script — and because a decision you can inspect with `cat' is a
;; decision you can fix when the elisp is wrong.
(defun hey-notmuch--db-path (db)
  "Absolute path of DB inside `hey-notmuch-db-dir', creating the directory."
  (make-directory hey-notmuch-db-dir t)
  (expand-file-name db hey-notmuch-db-dir))

(defun hey-notmuch--db-lines (db)
  "Live lines of DB: no blanks, no `#' comments, whitespace trimmed."
  (let ((file (hey-notmuch--db-path db)))
    (when (file-readable-p file)
      (seq-remove (lambda (l) (string-prefix-p "#" l))
                  (with-temp-buffer
                    (insert-file-contents file)
                    (split-string (buffer-string) "\n" t "[ \t\r]+"))))))

(defun hey-notmuch--db-write (db lines)
  "Replace DB's contents with LINES.

Written to a sibling and renamed, because the post-new hook reads these
files on every push and a half-written routing table is a mis-routed
inbox.  The suffix is `.emacs-tmp' rather than `.tmp': the hook already
uses `bubble.db.tmp' for its own rewrite, and two writers sharing one
temp name is a race waiting for a busy morning."
  (let* ((file (hey-notmuch--db-path db))
         (tmp (concat file ".emacs-tmp")))
    (with-temp-file tmp
      (dolist (l lines) (insert l "\n")))
    (rename-file tmp file t)))

(defun hey-notmuch--add-to-db (line db)
  "Append LINE to DB in `hey-notmuch-db-dir', creating it if needed."
  (append-to-file (concat line "\n") nil (hey-notmuch--db-path db)))

(defun hey-notmuch--db-remove (db regexp)
  "Drop every line of DB matching REGEXP.  Return how many went."
  (let* ((lines (hey-notmuch--db-lines db))
         (keep (seq-remove (lambda (l) (string-match-p regexp l)) lines))
         (gone (- (length lines) (length keep))))
    (when (> gone 0)
      (hey-notmuch--db-write db keep))
    gone))

(defun hey-notmuch--db-get (db key)
  "Value of the first `KEY VALUE…' line of DB, or nil.
Only for the key-first files (autofile.db, recycle.db, …); ledger.db puts
the category first and is read by hand where it is used."
  (let ((prefix (concat key " ")))
    (seq-some (lambda (l)
                (and (string-prefix-p prefix l)
                     (string-trim (substring l (length prefix)))))
              (hey-notmuch--db-lines db))))

(defun hey-notmuch--db-put (db key value)
  "Set KEY to VALUE in DB, replacing any line already keyed on KEY."
  (let ((keep (seq-remove (lambda (l) (string-prefix-p (concat key " ") l))
                          (hey-notmuch--db-lines db))))
    (hey-notmuch--db-write db (append keep (list (format "%s %s" key value))))))

(defun hey-notmuch--db-member-p (db key)
  "Non-nil if KEY is one of DB's lines (a one-column file)."
  (and (member key (hey-notmuch--db-lines db)) t))

(defun hey-notmuch--db-toggle (db key)
  "Add KEY to DB if absent, remove it if present.  Return t when now present."
  (if (hey-notmuch--db-member-p db key)
      (progn (hey-notmuch--db-remove db (concat "\\`" (regexp-quote key) "\\'")) nil)
    (hey-notmuch--add-to-db key db)
    t))

(defun hey-notmuch--file-string (name)
  "Whole contents of NAME in `hey-notmuch-db-dir', trimmed, or nil if empty.
For the one-value settings (the Speakeasy code, the Name Tag, the away
message) that have no list to be a line of."
  (let ((file (hey-notmuch--db-path name)))
    (when (file-readable-p file)
      (let ((s (string-trim (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))))
        (unless (string-empty-p s) s)))))

(defun hey-notmuch--file-set (name string)
  "Write STRING as the whole contents of NAME in `hey-notmuch-db-dir'."
  (let ((file (hey-notmuch--db-path name)))
    (with-temp-file file (insert string "\n"))))

(defun hey-notmuch--sanitize-name (name what)
  "NAME reduced to what a tag component may hold here, or an error naming WHAT.

The post-new hook narrows the same fields with `tr -cd \\='[:alnum:]_-\\=''
before pasting them into a tag, so anything wider would mean a label
typed in Emacs and a label applied by the router quietly differing by a
space.  Both sides drop the same characters, so both sides agree."
  (let ((clean (replace-regexp-in-string "[^[:alnum:]_-]" "" (or name ""))))
    (when (string-empty-p clean)
      (user-error "%s must contain a letter, digit, - or _" what))
    clean))

(defun hey-notmuch--advance ()
  "Move to the next message/thread after acting, so screening is a rhythm."
  (pcase major-mode
    ('notmuch-tree-mode   (notmuch-tree-next-matching-message))
    ('notmuch-search-mode (notmuch-search-next-thread))))

(defun hey-notmuch--refresh ()
  "Refresh every notmuch buffer so a tag change shows up where you can see it.
Cheap (one `notmuch count'/`search' per live buffer) and worth it: a box
whose count lies for the next ten minutes is a box you stop believing."
  (when (fboundp 'notmuch-refresh-all-buffers)
    (notmuch-refresh-all-buffers)))

;; ──────────────────── the Screener: decide once ─────────────────────
(defun hey-notmuch-screen-in ()
  "Screen the sender IN: their mail belongs in the Imbox from now on."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from '("+screened"))))
    (hey-notmuch--add-to-db addr "screened.db")
    (message "Screened in → Imbox: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-move-to-feed ()
  "Route the sender to The Feed (newsletters, casual reading)."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from '("+thefeed" "+archived" "-inbox"))))
    (hey-notmuch--add-to-db addr "thefeed.db")
    (message "→ The Feed: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-move-to-papertrail (category)
  "Route the sender to The Paper Trail under CATEGORY (e.g. shopify, godaddy).
Marked read on arrival: the Paper Trail is a place you go looking, not a
thing that should ask for your attention."
  (interactive "sPaper Trail category: ")
  (let* ((category (hey-notmuch--sanitize-name category "Category"))
         (addr (hey-notmuch--tag-by-from
                (list (format "+ledger/%s" category) "+archived" "-inbox" "-unread"))))
    (hey-notmuch--add-to-db (format "%s %s" category addr) "ledger.db")
    (message "→ Paper Trail/%s: %s" category addr))
  (hey-notmuch--advance))

(defun hey-notmuch-screen-out ()
  "Screen the sender OUT: trash everything from them, now and forever.
Nothing is unlinked — `deleted' is excluded from search by the notmuch
config, so this hides rather than destroys, and `H u' can undo it."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from
               '("+spam" "+deleted" "+archived" "-inbox" "-unread" "-screened"))))
    (hey-notmuch--add-to-db addr "spam.db")
    (message "Screened out: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-unscreen ()
  "Undo every routing decision for the sender at point and re-Screen them.
The escape hatch for a misfire: HEY keeps a Screener history you can
reverse, and a workflow built on one-way doors is one you hesitate to
use.  Removes the sender from every .db file as well as retagging."
  (interactive)
  (let ((addr (hey-notmuch--from-address)))
    (unless addr (user-error "No sender address at point"))
    (dolist (db '("screened.db" "thefeed.db" "spam.db" "ledger.db" "autofile.db" "recycle.db"))
      (let ((file (expand-file-name db hey-notmuch-db-dir)))
        (when (file-exists-p file)
          (with-temp-buffer
            (insert-file-contents file)
            ;; ledger/autofile/recycle lines are "<field> <addr>" or
            ;; "<addr> <field>", so the address is matched anywhere on the line
            ;; rather than anchored to the start.
            (flush-lines (regexp-quote addr) (point-min) (point-max))
            (write-region (point-min) (point-max) file nil 'silent)))))
    ;; Restores the ROUTING only. `unread' is deliberately untouched: it is
    ;; read state, not a routing decision, and iCloud is its source of truth
    ;; (notmuch mirrors it into the maildir S flag, which mbsync pushes back).
    ;; An earlier version added `+unread' here and marked 92 already-read
    ;; messages unread on a single undo — a one-key action that silently
    ;; rewrites read state across a sender's entire history is not an undo.
    (notmuch-tag (format "from:%s" addr)
                 '("-screened" "-thefeed" "-spam" "-deleted" "-bubble" "+inbox"))
    (message "Un-screened, back in the Screener: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-filter-by-sender ()
  "Narrow the view to just this sender — preview before you decide.

Unthreaded, for the same reason the Screener is: a search view shows one
row per THREAD, and the question here is \"what does this person actually
send me?\".  GitHub answers that with nineteen security advisories all
carrying `In-Reply-To: <repo/security-advisories@github.com>' — one
thread, so `notmuch search' drew exactly one line reading [19/19] and the
preview showed nothing worth deciding on.  One line per message is the
preview; the thread is not the unit of a screening decision."
  (interactive)
  (let ((addr (hey-notmuch--from-address)))
    (unless addr (user-error "No sender address at point"))
    (pcase major-mode
      ;; In a search buffer, narrow in place instead: `notmuch-search-filter'
      ;; keeps you in the view you were reading, which is the whole point of
      ;; filtering there rather than opening something new.
      ('notmuch-search-mode (notmuch-search-filter (format "from:%s" addr)))
      (_ (notmuch-unthreaded (format "from:%s" addr))))))

;; ─────────────── the piles: Reply Later / Set Aside ─────────────────
;; Per-THREAD, unlike screening — these are about one conversation, not a
;; standing decision about a person.
(defun hey-notmuch-reply-later ()
  "Mark the thread Reply Later — into the pile, out of the way, not forgotten."
  (interactive)
  (hey-notmuch--tag-thread '("+replylater"))
  (message "→ Reply Later")
  (hey-notmuch--advance))

(defun hey-notmuch-set-aside ()
  "Set the thread aside — reference material you want near but not in front."
  (interactive)
  (hey-notmuch--tag-thread '("+setaside"))
  (message "→ Set Aside")
  (hey-notmuch--advance))

(defun hey-notmuch-clear-pile ()
  "Take the thread out of Reply Later / Set Aside / Bubbled."
  (interactive)
  (hey-notmuch--tag-thread '("-replylater" "-setaside" "-bubbled"))
  (message "Cleared from the piles"))

;; ───────────────────────── Bubble Up ────────────────────────────────
(defun hey-notmuch-bubble-up (when)
  "Put the thread away until WHEN, then float it back to the top of the Imbox.

Beats HEY's five fixed presets: `org-read-date' takes \"+2d\", \"fri
9am\", \"next month\" or a calendar pick, so the delay is whatever you
actually mean.  The post-new hook sweeps the due list on every sync, so
a bubble surfaces within one sync of its time."
  ;; org-read-date is NOT autoloaded (verified against emacs -Q), so org has to
  ;; be pulled in explicitly — otherwise the first Bubble Up of a session dies
  ;; with void-function unless something else happened to load org first.
  (interactive (progn (require 'org)
                      (list (org-read-date t t nil "Bubble up when? "))))
  (let ((tid (hey-notmuch--thread-id)))
    (unless tid (user-error "No thread at point"))
    (hey-notmuch--add-to-db (format "%s %d" tid (float-time when)) "bubble.db")
    (notmuch-tag (concat "thread:" tid)
                 '("+bubble" "-inbox" "-unread" "-bubbled"))
    (message "Bubbling up %s" (format-time-string "%a %d %b %H:%M" when)))
  (hey-notmuch--advance))

;; ─────────────────── per-contact standing rules ─────────────────────
(defun hey-notmuch-autofile (label)
  "Auto-apply LABEL to everything this sender ever sends (HEY's Autofile)."
  (interactive "sAuto-label this sender's mail as: ")
  (let* ((label (hey-notmuch--sanitize-name label "Label"))
         (addr (hey-notmuch--from-address)))
    (unless addr (user-error "No sender address at point"))
    (hey-notmuch--add-to-db (format "%s %s" addr label) "autofile.db")
    (notmuch-tag (format "from:%s" addr) (list (format "+label/%s" label)))
    (message "Autofiling %s → label/%s" addr label)))

(defun hey-notmuch-recycle (days)
  "Auto-trash this sender's mail once it is older than DAYS (HEY's Recycling).
Tagging only — nothing is unlinked.  An automated rule that deletes mail
is a rule that will one day delete the wrong mail."
  (interactive (list (completing-read "Recycle this sender's mail after: "
                                      '("30" "90" "730") nil t)))
  (let ((addr (hey-notmuch--from-address)))
    (unless addr (user-error "No sender address at point"))
    (hey-notmuch--add-to-db (format "%s %s" addr days) "recycle.db")
    (message "Recycling %s after %s days" addr days)))

;; ───────────────────────────── Speakeasy ────────────────────────────
;; HEY's Speakeasy: a private code that, put anywhere in the subject line,
;; walks a stranger straight past the Screener.  You give it to the plumber,
;; the recruiter, the form on a website that will mail you a receipt once —
;; people who should reach you exactly once without becoming a decision.
;;
;; The post-new hook is what applies it (step 2, `+screened +speakeasy' on
;; tag:new).  This side only owns the code itself, in a one-line file the hook
;; reads with `head -n1'.
(defconst hey-notmuch--speakeasy-words
  '("amber" "basalt" "cedar" "delta" "ember" "fjord" "granite" "harbor"
    "indigo" "juniper" "kestrel" "lantern" "meadow" "nimbus" "onyx" "pewter"
    "quartz" "ripple" "saffron" "tundra" "umber" "violet" "willow" "zephyr")
  "Word half of a generated Speakeasy code.
Deliberately concrete nouns: the code gets read aloud down a phone line
and spelled out to a stranger, so \"quartz-then-four-digits\" survives
that trip in a way that a random string does not.")

(defun hey-notmuch--speakeasy-generate ()
  "Make a fresh Speakeasy code: one word plus four digits, no separator.

No hyphen, no space, on purpose.  notmuch matches the subject through
Xapian's tokeniser, which breaks on every non-alphanumeric character, so
`quartz-4718' would be indexed as two terms and `subject:\"quartz-4718\"'
would then also match a subject containing the two words apart.  A single
alphanumeric token is matched whole: verified against this mailbox, where
`subject:\"Cool9977\"' matches 18 real messages while `subject:\"ool9977\"'
and `subject:\"Cool997\"' both match none."
  (format "%s%04d"
          (capitalize (nth (random (length hey-notmuch--speakeasy-words))
                           hey-notmuch--speakeasy-words))
          (random 10000)))

(defun hey-notmuch-speakeasy (&optional regenerate)
  "Show the Speakeasy code, or with a prefix argument REGENERATE it.

Regenerating retires the old code instantly — anyone still holding it
lands back in the Screener, which is the whole point of being able to
change it.  The new code goes to the kill ring, because the next thing
you do with it is paste it into a form."
  (interactive "P")
  (let* ((current (hey-notmuch--file-string "speakeasy"))
         (code (if (or regenerate (null current))
                   (let ((new (read-string "Speakeasy code: "
                                           (hey-notmuch--speakeasy-generate))))
                     ;; Anything the tokeniser would split is silently a
                     ;; different code than the one you think you set, so a
                     ;; non-alphanumeric code is refused rather than mangled.
                     (unless (string-match-p "\\`[[:alnum:]]+\\'" new)
                       (user-error "Speakeasy code must be letters and digits only"))
                     (hey-notmuch--file-set "speakeasy" new)
                     new)
                 current)))
    (kill-new code)
    (message "Speakeasy: %s  (in the subject line, it skips the Screener · copied)"
             code)))

;; ───────────────────────── sync + counts ────────────────────────────
(defun hey-notmuch-sync ()
  "Fetch mail now, asynchronously.

Normally unnecessary — goimapnotify pushes within about a second of
arrival — so this is for impatience and for proving the pipe works."
  (interactive)
  (message "Syncing mail…")
  (make-process
   :name "hey-mail-sync" :buffer "*hey-mail-sync*"
   :command (list hey-notmuch-sync-command)
   :noquery t
   :sentinel (lambda (_proc event)
               (if (string-prefix-p "finished" event)
                   (progn (notmuch-refresh-all-buffers) (message "Mail synced"))
                 (message "Mail sync: %s" (string-trim event))))))

;; ─────────────────── phone parity: the folder map ───────────────────
;; A box here is a notmuch tag, and IMAP cannot see tags — so on the iPhone
;; there are no boxes and every stranger lands in one INBOX.  `bin/hey-folder-
;; sync' in the dotfiles repo is the bridge: it moves everything that is not
;; screened-in Imbox mail OUT of INBOX into a HEY/* folder, which is what makes
;; the Screener's promise hold on a device that only notifies for INBOX.
;;
;; None of that logic lives here, deliberately, and it is the same division of
;; labour as everywhere else in this setup: Emacs writes DECISIONS, the shell
;; side APPLIES them to files.  The bridge has to run without Emacs (it is
;; called from mail-sync, which is called from a systemd unit and from an IDLE
;; watcher), so re-implementing the map in elisp would give two authorities on
;; where a message belongs and one of them would eventually be wrong.
;;
;; What this command is for is the one thing Emacs is better at: reading the
;; report before you switch a box on.  Boxes are enabled one line at a time in
;; `foldersync.db', each one migrating that box's mail on the next sync, and
;; `e' below opens that file.
(defcustom hey-notmuch-folder-sync-command "hey-folder-sync"
  "Program that maps notmuch tags onto IMAP folders for the phone.
Found on `exec-path'; lives in the dotfiles repo next to `mail-sync'."
  :type 'string
  :group 'hey-notmuch)

(defvar hey-notmuch-folder-map-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'hey-notmuch-folder-map-edit)
    (define-key map (kbd "g") #'hey-notmuch-folder-map)
    map)
  "Keymap for the folder-map report.")

(define-derived-mode hey-notmuch-folder-map-mode special-mode "HEY folders"
  "Report of the tag → IMAP-folder map and what the next sync would move.")

(defun hey-notmuch-folder-map-edit ()
  "Open the list of boxes that exist as IMAP folders on the phone."
  (interactive)
  (find-file (hey-notmuch--db-path "foldersync.db")))

(defun hey-notmuch-folder-map ()
  "Show the tag → IMAP-folder map, and what a sync would move, per box.

Read-only: this runs the bridge's dry run, which moves nothing.  A box
only migrates once its folder is listed in `foldersync.db' (`e' here),
and the TO MOVE column is exactly how many messages that would be."
  (interactive)
  (let ((buffer (get-buffer-create "*HEY folders*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Synchronous, unlike `hey-notmuch-sync': measured at 356ms on this
        ;; mailbox (1968 messages, ~40 `notmuch count' invocations), which is
        ;; short enough not to be worth the sentinel — and unlike a sync there
        ;; is nothing useful to do in the buffer until the numbers are in.
        (unless (eq 0 (call-process hey-notmuch-folder-sync-command
                                    nil t nil "--dry-run"))
          (insert "\n(hey-folder-sync failed — see the output above)\n"))
        (insert "\n  e  edit the enabled-box list      g  refresh\n"))
      (goto-char (point-min))
      (hey-notmuch-folder-map-mode))
    (pop-to-buffer buffer)))

;; ───────────────────────────── keys ─────────────────────────────────
;; Everything HEY-specific lives under `H', so notmuch's own single-key
;; bindings (a = archive, r/R = reply, f = forward, * = tag all) keep working
;; exactly as documented upstream.  The letter after `H' is HEY's own key for
;; the same action wherever one exists (l = Reply Later, a = Set Aside,
;; z = Bubble Up), so the muscle memory transfers.
;;
;; kao (the Kakoune modal layer) stays out of the LIST buffers on its own: its
;; `kao--editing-buffer-p' heuristic asks whether `a' self-inserts here, and a
;; notmuch list binds `a' to archive.  The hello screen is the exception, and
;; needs the exemption below.
;; Two levels only.  The everyday verbs are one keystroke after `H'; the
;; things you set once a year — the Speakeasy code, the Name Tag, the away
;; message — sit behind `H ,' so they cannot crowd out a letter that a daily
;; action wants.  Modules add to both maps as they load (see `hey-labels',
;; `hey-flow', …), which is also why `H ?' describes the map rather than
;; printing a list this file would have to keep in step.
(defvar hey-notmuch-settings-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'hey-notmuch-speakeasy)
    (define-key map (kbd "f") #'hey-notmuch-folder-map)
    map)
  "Set-once HEY settings, bound under `H ,'.")

(defun hey-notmuch-help ()
  "Describe every HEY action currently bound under `H'."
  (interactive)
  (describe-keymap 'hey-notmuch-map))

(defvar hey-notmuch-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ",") hey-notmuch-settings-map)
    (define-key map (kbd "?") #'hey-notmuch-help)
    (define-key map (kbd "i") #'hey-notmuch-screen-in)
    (define-key map (kbd "f") #'hey-notmuch-move-to-feed)
    (define-key map (kbd "p") #'hey-notmuch-move-to-papertrail)
    (define-key map (kbd "o") #'hey-notmuch-screen-out)
    (define-key map (kbd "u") #'hey-notmuch-unscreen)
    (define-key map (kbd "s") #'hey-notmuch-filter-by-sender)
    (define-key map (kbd "l") #'hey-notmuch-reply-later)
    (define-key map (kbd "a") #'hey-notmuch-set-aside)
    (define-key map (kbd "z") #'hey-notmuch-bubble-up)
    (define-key map (kbd "c") #'hey-notmuch-clear-pile)
    (define-key map (kbd "A") #'hey-notmuch-autofile)
    (define-key map (kbd "R") #'hey-notmuch-recycle)
    (define-key map (kbd "g") #'hey-notmuch-sync)
    map)
  "HEY actions, bound under the `H' prefix in every notmuch buffer.")

(with-eval-after-load 'notmuch
  ;; The hello screen is in this list, and has to be: it is the FIRST thing
  ;; `C-c m' shows, and the screen where half of these actions make the most
  ;; sense — `H ?' for the key list, `H ,' for the settings, `H F' for Focus &
  ;; Reply, `H D' for the files, `H P' to start powering through.  An earlier
  ;; version bound `H' only in the three list modes, so the entry screen was
  ;; the one place in the client where the HEY prefix silently did nothing.
  ;;
  ;; Nothing on the hello screen wants a literal "H": `notmuch-hello-sections'
  ;; above draws the boxes and the bundles and nothing else, so the buffer
  ;; contains no editable widget field — checked, zero positions carry a
  ;; keymap text property.  Were `notmuch-hello-insert-search' put back, it
  ;; would still be safe: a widget field carries its own keymap as a text
  ;; property, and that takes precedence over the major-mode map.
  (dolist (map (list notmuch-hello-mode-map
                     notmuch-search-mode-map
                     notmuch-tree-mode-map
                     notmuch-show-mode-map))
    (define-key map (kbd "H") hey-notmuch-map))
  ;; `G' is the conventional "get mail" key in mail clients; notmuch leaves it
  ;; free on the hello screen.
  (define-key notmuch-hello-mode-map (kbd "G") #'hey-notmuch-sync)
  (define-key notmuch-search-mode-map (kbd "G") #'hey-notmuch-sync)
  (define-key notmuch-tree-mode-map (kbd "G") #'hey-notmuch-sync)
  ;; Overrides notmuch's own `G' in the show buffer
  ;; (`notmuch-poll-and-refresh-this-buffer', which runs `notmuch-poll-script'
  ;; — a script this setup does not have).  bin/mail-sync is the single entry
  ;; point every other path uses; one key meaning two different kinds of
  ;; "fetch mail" depending on which buffer you were in is a key you cannot
  ;; trust.
  (define-key notmuch-show-mode-map (kbd "G") #'hey-notmuch-sync))

;; kao must be kept out of the hello screen by hand.  `notmuch-hello-mode'
;; derives from `fundamental-mode' and binds no printable key of its own, so
;; kao's "does `a' self-insert here?" heuristic reads the boxes as an editing
;; buffer, turns on, and its suppressed normal map shadows the entire screen:
;; measured in a live buffer, `a' was `kao-append', `J' was `kao-extend-down',
;; `G' was `kao-goto-extend' and `H' reached nothing at all.  Every mail key on
;; the first screen of the client, silently gone.
;;
;; `kao-global-modes' is kao's own supported answer for this — it excludes
;; `ghostel-mode' by the same mechanism for the same reason (fundamental-mode
;; derivative that the heuristic misreads).  The entry is CONSED ON rather than
;; the variable being replaced, because kao's default already excludes
;; special-mode, the minibuffer and the terminals, and re-stating that list
;; here would freeze a copy of it that stops tracking the package.  The
;; predicate takes the first matching entry, so a `not' at the front wins.
(with-eval-after-load 'kao
  (let ((entry '(not notmuch-hello-mode)))
    (cond
     ((not (listp kao-global-modes))     ; plain t, or nil: build a real list
      (setq kao-global-modes (list entry kao-global-modes)))
     ((member entry kao-global-modes))   ; already there — loading twice is free
     (t (setq kao-global-modes (cons entry kao-global-modes))))))

(provide 'hey-notmuch)
;;; hey-notmuch.el ends here

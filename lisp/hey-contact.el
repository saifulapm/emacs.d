;;; hey-contact.el --- Mission Control: one page per sender  -*- lexical-binding: t; -*-

;; HEY puts an avatar next to every message; clicking it opens that person's
;; page — where their mail goes, whether they may notify you, what you have
;; written about them, what they have sent you.  Every standing decision about
;; a human being, in one place, changeable on the spot.
;;
;; This is that page.  `H C' from anywhere in notmuch opens it for the sender
;; at point; the same page is reachable for anyone by name from `M-x
;; hey-contact'.
;;
;; It is also where the per-contact rules live that have no other home:
;;
;;   notify.db   people whose mail is allowed to interrupt you.  HEY's
;;               notifications are off by default and opt-in per contact,
;;               which is the only setting that makes push tolerable.
;;   bundle.db   prolific senders collapsed to one row in the Imbox
;;               (hey-flow.el draws the row; the decision belongs here with
;;               the other per-person rules).
;;
;; The page is rendered from scratch on every `g' — nine batched counts, two
;; small searches and an attachment scan, measured at 71ms for a sender with
;; 99 messages and 24 attachments — rather than kept up to date, because a
;; contact page that lies about where someone's mail goes is worse than no
;; contact page at all.

;;; Code:

(require 'hey-notmuch)
(require 'hey-notes)
(require 'hey-files)
(require 'subr-x)

(declare-function notmuch-show "notmuch-show")
(declare-function notmuch-tree "notmuch-tree")
(declare-function notmuch-search "notmuch")
(declare-function notmuch-mua-mail "notmuch-mua")
(defvar notmuch-command)

(defconst hey-contact-notify-db "notify.db"
  "One address per line: senders whose mail may raise a notification.")

(defconst hey-contact-bundle-db "bundle.db"
  "One address per line: senders collapsed to a single Imbox row.")

(defface hey-contact-heading
  '((t :inherit font-lock-function-name-face :weight bold :height 1.2))
  "Face for the name at the top of a contact page."
  :group 'hey-notmuch)

(defface hey-contact-field
  '((t :inherit font-lock-keyword-face))
  "Face for a field label on a contact page."
  :group 'hey-notmuch)

(defface hey-contact-hint
  '((t :inherit shadow))
  "Face for the key hints on a contact page."
  :group 'hey-notmuch)

;; ─────────────────────── what we know about them ────────────────────
(defun hey-contact--routing (addr)
  "Where ADDR's mail is routed, as (LABEL . EXPLANATION)."
  (cond
   ((hey-notmuch--db-member-p "spam.db" addr)
    (cons "Screened out" "trashed on arrival, now and forever"))
   ((hey-notmuch--db-member-p "thefeed.db" addr)
    (cons "The Feed" "newsletters — out of the inbox, still unread"))
   ((seq-some (lambda (line)
                (and (string-suffix-p (concat " " addr) line)
                     (car (split-string line "[ \t]+" t))))
              (hey-notmuch--db-lines "ledger.db"))
    (cons (format "Paper Trail/%s"
                  (seq-some (lambda (line)
                              (and (string-suffix-p (concat " " addr) line)
                                   (car (split-string line "[ \t]+" t))))
                            (hey-notmuch--db-lines "ledger.db")))
          "receipts — filed and marked read on arrival"))
   ((hey-notmuch--db-member-p "screened.db" addr)
    (cons "Imbox" "screened in — straight to the Imbox"))
   (t
    (cons "Screener" "no decision yet — their mail waits to be screened"))))

(defun hey-contact--message-date (query sort)
  "Date of the oldest or newest message matching QUERY, per SORT.

Asked at MESSAGE granularity, not thread: `notmuch search' reports a
thread's date, and the thread you were first in with someone is often
one they are still replying to, so \"first heard from\" would show today."
  (let* ((id (car (ignore-errors
                    (process-lines notmuch-command "search" "--output=messages"
                                   (format "--sort=%s" sort) "--limit=1" query))))
         (msg (and id (car (hey-files--forest-messages
                            (ignore-errors
                              (notmuch-call-notmuch-sexp
                               "show" "--format=sexp" "--format-version=5"
                               "--body=false" "--entire-thread=false" id)))))))
    (when msg
      (format-time-string "%e %b %Y" (seconds-to-time (plist-get msg :timestamp))))))

(defun hey-contact--stats (addr)
  "Everything countable about ADDR, as a plist."
  (let* ((q (format "from:%s" addr))
         (message-counts
          (hey-notmuch--count-batch
           (list q
                 (format "%s and tag:unread" q)
                 (format "%s and tag:attachment" q)
                 (format "%s and tag:inbox" q)
                 (format "%s and tag:thefeed" q)
                 (format "%s and tag:/^ledger\\//" q)
                 (format "%s and tag:deleted" q)
                 (format "to:%s" addr))))
         (thread-count (car (hey-notmuch--count-batch (list q) 'threads))))
    (list :messages (nth 0 message-counts)
          :unread (nth 1 message-counts)
          :attachments (nth 2 message-counts)
          :inbox (nth 3 message-counts)
          :feed (nth 4 message-counts)
          :ledger (nth 5 message-counts)
          :deleted (nth 6 message-counts)
          :sent-to-them (nth 7 message-counts)
          :threads thread-count)))

;; ──────────────────────────── rendering ─────────────────────────────
(defvar-local hey-contact-address nil "Address this page is about.")
(defvar-local hey-contact-name nil "Display name for `hey-contact-address'.")

(defun hey-contact--field (label value &optional hint)
  "Insert one LABEL/VALUE row, with an optional key HINT on the right."
  (insert "  " (propertize (format "%-16s" label) 'face 'hey-contact-field)
          (format "%-38s" (or value ""))
          (if hint (propertize hint 'face 'hey-contact-hint) "")
          "\n"))

(defun hey-contact--render ()
  "Draw the contact page for `hey-contact-address'."
  (let* ((addr hey-contact-address)
         (inhibit-read-only t)
         (line (line-number-at-pos))
         (q (format "from:%s" addr))
         (routing (hey-contact--routing addr))
         (stats (hey-contact--stats addr))
         (note (hey-notes--read (concat "contact:" addr)))
         (autofile (hey-notmuch--db-get "autofile.db" addr))
         (recycle (hey-notmuch--db-get "recycle.db" addr)))
    (erase-buffer)
    (insert (propertize (format "%s\n" (or hey-contact-name addr)) 'face 'hey-contact-heading)
            (propertize (format "%s\n\n" addr) 'face 'shadow))

    (hey-contact--field "Routing" (car routing) "i imbox · f feed · p paper trail · o out · u undo")
    (insert "  " (propertize (format "%-16s" "") 'face 'hey-contact-field)
            (propertize (cdr routing) 'face 'shadow) "\n")
    (hey-contact--field "Notifications"
                        (if (hey-notmuch--db-member-p hey-contact-notify-db addr)
                            "on — their mail may interrupt you"
                          "off")
                        "! toggle")
    (hey-contact--field "Autofile" (if autofile (concat "label/" autofile) "—") "A set")
    (hey-contact--field "Recycling"
                        (if recycle (format "trash their mail after %s days" recycle) "—")
                        "R set")
    (hey-contact--field "Bundling"
                        (if (hey-notmuch--db-member-p hey-contact-bundle-db addr)
                            "one Imbox row for all their mail"
                          "—")
                        "B toggle")
    (insert "\n")

    ;; ── what you have written about them
    (insert "  " (propertize "Note" 'face 'hey-contact-field)
            (propertize "              n edit\n" 'face 'hey-contact-hint))
    (if note
        (dolist (l (split-string note "\n"))
          (insert "    " (propertize (concat "│ " l) 'face 'hey-notes-banner) "\n"))
      (insert "    " (propertize "nothing yet\n" 'face 'shadow)))
    (insert "\n")

    ;; ── the shape of the correspondence
    (insert "  " (propertize "Mail" 'face 'hey-contact-field)
            (propertize "              s search theirs · W write to them\n" 'face 'hey-contact-hint))
    (insert (format "    %d message%s in %d thread%s · %d unread · %d with attachments\n"
                    (plist-get stats :messages) (if (= 1 (plist-get stats :messages)) "" "s")
                    (plist-get stats :threads) (if (= 1 (plist-get stats :threads)) "" "s")
                    (plist-get stats :unread) (plist-get stats :attachments)))
    (insert (format "    in the inbox %d · the feed %d · paper trail %d · trashed %d\n"
                    (plist-get stats :inbox) (plist-get stats :feed)
                    (plist-get stats :ledger) (plist-get stats :deleted)))
    (insert (format "    you have sent them %d\n" (plist-get stats :sent-to-them)))
    (let ((first (hey-contact--message-date q "oldest-first"))
          (last (hey-contact--message-date q "newest-first")))
      (when first
        (insert (format "    first heard from %s · last %s\n" (string-trim first)
                        (string-trim (or last ""))))))
    (insert "\n")

    ;; ── recent files
    (let ((files (hey-files-attachments q 12)))
      (when files
        (insert "  " (propertize "Recent files" 'face 'hey-contact-field)
                (propertize "      RET open\n" 'face 'hey-contact-hint))
        (dolist (f (seq-take files 5))
          (insert (propertize
                   (format "    %-12s %-38s %s\n"
                           (plist-get f :date)
                           (truncate-string-to-width (plist-get f :filename) 38)
                           (truncate-string-to-width (plist-get f :subject) 30))
                   'hey-file f)))
        (insert "\n")))

    ;; ── recent threads
    (let ((threads (hey-notmuch--search q "--sort=newest-first" "--limit=10")))
      (when threads
        (insert "  " (propertize "Recent threads" 'face 'hey-contact-field)
                (propertize "    RET open\n" 'face 'hey-contact-hint))
        (dolist (thread threads)
          (insert (propertize
                   (format "    %-12s %-50s %s\n"
                           (plist-get thread :date_relative)
                           (truncate-string-to-width (or (plist-get thread :subject) "") 50)
                           (if (member "unread" (plist-get thread :tags)) "●" ""))
                   'hey-thread (plist-get thread :thread))))
        (insert "\n")))

    (insert (propertize "  g refresh · q quit\n" 'face 'hey-contact-hint))
    (goto-char (point-min))
    (forward-line (1- line))))

;; ────────────────────────── the commands ────────────────────────────
(defvar hey-contact-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hey-contact-open)
    (define-key map (kbd "g")   #'hey-contact-refresh)
    (define-key map (kbd "n")   #'hey-contact-note)
    (define-key map (kbd "!")   #'hey-contact-notify-toggle)
    (define-key map (kbd "B")   #'hey-contact-bundle-toggle)
    (define-key map (kbd "A")   #'hey-contact-autofile)
    (define-key map (kbd "R")   #'hey-contact-recycle)
    (define-key map (kbd "i")   #'hey-contact-screen-in)
    (define-key map (kbd "f")   #'hey-contact-move-to-feed)
    (define-key map (kbd "p")   #'hey-contact-move-to-papertrail)
    (define-key map (kbd "o")   #'hey-contact-screen-out)
    (define-key map (kbd "u")   #'hey-contact-unscreen)
    (define-key map (kbd "s")   #'hey-contact-search)
    (define-key map (kbd "W")   #'hey-contact-write)
    map)
  "Keymap for a HEY contact page.")

(define-derived-mode hey-contact-mode special-mode "HEY contact"
  "Everything you have decided about one person, and everything they sent.
\\{hey-contact-mode-map}"
  (setq truncate-lines t))

;;;###autoload
(defun hey-contact (&optional addr)
  "Open the contact page for ADDR, or for the sender at point."
  (interactive
   (list (or (and (not current-prefix-arg)
                  (derived-mode-p 'notmuch-show-mode 'notmuch-tree-mode 'notmuch-search-mode)
                  (hey-notmuch--from-address))
             (read-string "Contact page for address: "))))
  (let* ((addr (downcase (string-trim (or addr ""))))
         (name (car (ignore-errors
                      (process-lines notmuch-command "address" "--output=sender"
                                     "--deduplicate=address"
                                     (format "from:%s" addr)))))
         (buffer (get-buffer-create (format "*HEY contact: %s*" addr))))
    (when (string-empty-p addr) (user-error "No address"))
    (with-current-buffer buffer
      (hey-contact-mode)
      (setq hey-contact-address addr
            hey-contact-name (when (and name (string-match "\\`\\([^<]+\\)<" name))
                               (string-trim (match-string 1 name))))
      (hey-contact--render))
    (pop-to-buffer buffer)))

(defun hey-contact--this ()
  "The address this page is about."
  (or hey-contact-address (user-error "Not a contact page")))

(defun hey-contact-refresh ()
  "Redraw the page."
  (interactive)
  (hey-contact--this)
  (hey-contact--render))

(defun hey-contact-open ()
  "Open the thread or file on this line."
  (interactive)
  (let ((thread (get-text-property (point) 'hey-thread))
        (file (get-text-property (point) 'hey-file)))
    (cond (thread (notmuch-show thread))
          (file (let* ((dir (expand-file-name "hey-mail-parts" temporary-file-directory))
                       (path (progn (make-directory dir t)
                                    (expand-file-name
                                     (hey-files--safe-name (plist-get file :filename)) dir))))
                  (hey-files--extract file path)
                  (find-file-read-only path)))
          (t (user-error "Nothing to open on this line")))))

(defun hey-contact-note ()
  "Edit the note on this contact."
  (interactive)
  (hey-notes-contact (hey-contact--this)))

(defun hey-contact-notify-toggle ()
  "Let this contact's mail interrupt you — or stop letting it.

The post-new hook reads notify.db and raises a notification naming the
sender for anyone on the list.  Everyone else is silent: an unscreened
stranger buzzing your phone is exactly the thing the Screener exists to
prevent, and \"notify me about everything\" is how notifications stop
meaning anything."
  (interactive)
  (let* ((addr (hey-contact--this))
         (on (hey-notmuch--db-toggle hey-contact-notify-db addr)))
    (hey-contact--render)
    (message "Notifications for %s: %s" addr (if on "on" "off"))))

(defun hey-contact-bundle-toggle ()
  "Collapse this sender to one Imbox row — or stop."
  (interactive)
  (let* ((addr (hey-contact--this))
         (on (hey-notmuch--db-toggle hey-contact-bundle-db addr)))
    ;; The tag is what the Imbox query filters on, so existing mail has to be
    ;; retagged here; the hook applies the same rule to mail that has not
    ;; arrived yet.  Bundling is a display decision — nothing is archived,
    ;; nothing is marked read.
    (notmuch-tag (format "from:%s" addr) (list (if on "+bundled" "-bundled")))
    (hey-contact--render)
    (message "%s %s" (if on "Bundled:" "No longer bundled:") addr)))

;; The screening commands work off "the sender at point", which a contact page
;; has no notion of — so each one is wrapped to act on the page's address
;; instead.  Same functions, same .db writes, same retagging of history.
(defmacro hey-contact--defaction (name args docstring &rest body)
  "Define command NAME taking ARGS, documented DOCSTRING, running BODY.
BODY sees `addr' bound to the page's contact and the page is redrawn after."
  (declare (indent 3) (doc-string 3))
  `(defun ,name ,args
     ,docstring
     (interactive)
     (let ((addr (hey-contact--this)))
       (ignore addr)
       ,@body
       (hey-contact--render))))

(hey-contact--defaction hey-contact-screen-in ()
  "Screen this contact in: their mail belongs in the Imbox."
  (hey-notmuch--tag-by-from '("+screened") addr)
  (hey-notmuch--add-to-db addr "screened.db")
  (message "Screened in → Imbox: %s" addr))

(hey-contact--defaction hey-contact-move-to-feed ()
  "Route this contact to The Feed."
  (hey-notmuch--tag-by-from '("+thefeed" "+archived" "-inbox") addr)
  (hey-notmuch--add-to-db addr "thefeed.db")
  (message "→ The Feed: %s" addr))

(hey-contact--defaction hey-contact-screen-out ()
  "Screen this contact out: trash their mail, now and forever."
  (hey-notmuch--tag-by-from
   '("+spam" "+deleted" "+archived" "-inbox" "-unread" "-screened") addr)
  (hey-notmuch--add-to-db addr "spam.db")
  (message "Screened out: %s" addr))

(defun hey-contact-move-to-papertrail (category)
  "File this contact's mail in the Paper Trail under CATEGORY."
  (interactive "sPaper Trail category: ")
  (let ((addr (hey-contact--this))
        (category (hey-notmuch--sanitize-name category "Category")))
    (hey-notmuch--tag-by-from
     (list (format "+ledger/%s" category) "+archived" "-inbox" "-unread") addr)
    (hey-notmuch--add-to-db (format "%s %s" category addr) "ledger.db")
    (hey-contact--render)
    (message "→ Paper Trail/%s: %s" category addr)))

(defun hey-contact-unscreen ()
  "Undo every routing decision for this contact and re-Screen them."
  (interactive)
  (let ((addr (hey-contact--this)))
    (dolist (db '("screened.db" "thefeed.db" "spam.db" "ledger.db"
                  "autofile.db" "recycle.db"))
      (hey-notmuch--db-remove db (regexp-quote addr)))
    ;; `unread' is deliberately untouched — see `hey-notmuch-unscreen': read
    ;; state belongs to iCloud, and an undo that marks a hundred read messages
    ;; unread is not an undo.
    (notmuch-tag (format "from:%s" addr)
                 '("-screened" "-thefeed" "-spam" "-deleted" "-bubble" "+inbox"))
    (hey-contact--render)
    (message "Un-screened, back in the Screener: %s" addr)))

(defun hey-contact-autofile (label)
  "Auto-apply LABEL to everything this contact sends."
  (interactive "sAuto-label their mail as: ")
  (let ((addr (hey-contact--this))
        (label (hey-notmuch--sanitize-name label "Label")))
    ;; One rule per sender: a second `H A' replaces the first rather than
    ;; stacking, because two autofile lines for one address means the hook
    ;; applies both labels and neither of them is what you meant.
    (hey-notmuch--db-put "autofile.db" addr label)
    (notmuch-tag (format "from:%s" addr) (list (format "+label/%s" label)))
    (hey-contact--render)
    (message "Autofiling %s → label/%s" addr label)))

(defun hey-contact-recycle (days)
  "Auto-trash this contact's mail once it is older than DAYS."
  (interactive (list (completing-read "Recycle their mail after: "
                                      '("30" "90" "730") nil t)))
  (let ((addr (hey-contact--this)))
    (hey-notmuch--db-put "recycle.db" addr days)
    (hey-contact--render)
    (message "Recycling %s after %s days" addr days)))

(defun hey-contact-search ()
  "Show everything from this contact."
  (interactive)
  (notmuch-tree (format "from:%s" (hey-contact--this))))

(defun hey-contact-write ()
  "Start a mail to this contact."
  (interactive)
  (notmuch-mua-mail (hey-contact--this)))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "C") #'hey-contact))

(provide 'hey-contact)
;;; hey-contact.el ends here

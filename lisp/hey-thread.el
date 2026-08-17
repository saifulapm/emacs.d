;;; hey-thread.el --- Seen, mute, rename, merge, and the tracker report  -*- lexical-binding: t; -*-

;; The per-thread things HEY does that notmuch has no opinion about:
;;
;;   Mark Seen      "I have looked at this, it is not news any more" — WITHOUT
;;                  marking it read.  Read state belongs to iCloud and is
;;                  shared with the phone; `seen' is local and means something
;;                  else, so it gets its own tag and its own Imbox section.
;;
;;   Mute           a thread you never want to hear from again.  Out of the
;;                  inbox now, and the post-new hook keeps future replies out
;;                  as they arrive.
;;
;;   Rename         your name for a thread, over the sender's.  "Fwd: Fwd: RE:
;;                  quick question" is not a subject, it is an apology.  The
;;                  mail is never modified: the override is local, keyed by
;;                  thread id, and applied at display time.
;;
;;   Merge          two conversations that are really one.  notmuch threads by
;;                  References and cannot be told otherwise, so merging is a
;;                  tag both threads share plus a command that opens them
;;                  together.
;;
;;   Trackers       what was in the mail that wanted to report back.  Remote
;;                  images are blocked outright by the notmuch config, so
;;                  nothing here has to prevent anything — this only tells you
;;                  what was blocked, and by whom.

;;; Code:

(require 'hey-notmuch)
(require 'subr-x)
(require 'cl-lib)                       ; cl-pushnew, in the tracker scan

(declare-function notmuch-show "notmuch-show")
(declare-function notmuch-tag "notmuch-tag")
(declare-function notmuch-sanitize "notmuch-lib")
(declare-function notmuch-show-strip-re "notmuch-show")
(declare-function notmuch-call-notmuch-sexp "notmuch-lib")
(declare-function hey-files--parts "hey-files")
(declare-function hey-files--forest-messages "hey-files")
(defvar notmuch-command)
(defvar notmuch-show-thread-id)
(defvar notmuch-search-result-format)
(defvar notmuch-tree-result-format)
(defvar notmuch-unthreaded-result-format)
(defvar notmuch-tree-previous-subject)

;; ══════════════════════════ Mark Seen ═══════════════════════════════
;;;###autoload
(defun hey-thread-mark-seen ()
  "Mark the selected thread(s) seen — or, if already seen, new again.

Seen is not read.  `unread' is mirrored into the maildir filename and
pushed to iCloud by mbsync, so clearing it here would mark the mail read
on your phone as well; `seen' is a local tag that only moves the thread
from the Imbox's \"New for You\" to its \"Previously Seen\" (the `J y'
box).  You glanced at it, you have not dealt with it, and it should stop
shouting."
  (interactive)
  (let* ((ids (hey-notmuch--region-thread-ids))
         (seen (and ids (> (hey-notmuch--count
                            (format "thread:%s and tag:seen" (car ids)))
                           0))))
    (unless ids (user-error "No thread at point"))
    (dolist (tid ids)
      (notmuch-tag (concat "thread:" tid) (list (if seen "-seen" "+seen"))))
    (message "%s %d thread%s" (if seen "No longer seen:" "Seen:")
             (length ids) (if (= 1 (length ids)) "" "s")))
  (hey-notmuch--advance))

;; ════════════════════════════ Mute ══════════════════════════════════
;;;###autoload
(defun hey-thread-mute ()
  "Mute the selected thread(s): out of the inbox, and staying out.

The tag is the durable half — the post-new hook drops future messages in
a muted thread out of the inbox as they arrive, so muting a thread that
is still going is worth something.  `unread' is deliberately left alone:
`a' (archive) does not touch it either, and one keystroke that marks
fifty messages read on the server is not a thing to have."
  (interactive)
  (let ((ids (hey-notmuch--region-thread-ids)))
    (unless ids (user-error "No thread at point"))
    (dolist (tid ids)
      (notmuch-tag (concat "thread:" tid) '("+muted" "-inbox")))
    (message "Muted %d thread%s" (length ids) (if (= 1 (length ids)) "" "s")))
  (hey-notmuch--advance))

;;;###autoload
(defun hey-thread-unmute ()
  "Unmute the selected thread(s) and put them back in the inbox."
  (interactive)
  (let ((ids (hey-notmuch--region-thread-ids)))
    (unless ids (user-error "No thread at point"))
    (dolist (tid ids)
      (notmuch-tag (concat "thread:" tid) '("-muted" "+inbox")))
    (message "Unmuted %d thread%s" (length ids) (if (= 1 (length ids)) "" "s"))))

;; ═══════════════════════════ Rename ═════════════════════════════════
;; subjects.db is `<thread-id> <your subject>'.  Display-time only: the
;; message on disk and on iCloud keeps whatever the sender called it, so a
;; rename can never confuse a reply, a search, or the phone.

(defconst hey-thread-subject-db "subjects.db"
  "File in `hey-notmuch-db-dir' holding local subject overrides.")

(defcustom hey-thread-rename-ttl 60
  "Seconds a renamed thread's message list is trusted before being rebuilt.

Tree views know only the message under point, never its thread, so
showing a renamed subject there means holding a message-id → subject map.
Rebuilding it costs one `notmuch search' per renamed thread, which is why
it is rebuilt on a timer rather than per line — and why the whole
mechanism costs exactly nothing when you have renamed nothing."
  :type 'integer
  :group 'hey-notmuch)

(defface hey-thread-renamed
  '((t :inherit notmuch-search-subject :slant italic))
  "Face for a subject you have renamed."
  :group 'hey-notmuch)

(defvar hey-thread--renames nil "Alist of thread id → your subject.")
(defvar hey-thread--rename-messages nil "Hash of message id → your subject.")
(defvar hey-thread--rename-stamp 0 "When the maps above were last built.")

(defun hey-thread--load-renames (&optional force)
  "Rebuild the rename maps if they are stale, or if FORCE."
  (when (or force
            (> (- (float-time) hey-thread--rename-stamp) hey-thread-rename-ttl))
    (setq hey-thread--rename-stamp (float-time)
          hey-thread--renames
          (delq nil
                (mapcar (lambda (line)
                          (let ((space (string-search " " line)))
                            (when space
                              (cons (substring line 0 space)
                                    (string-trim (substring line space))))))
                        (hey-notmuch--db-lines hey-thread-subject-db))))
    (setq hey-thread--rename-messages
          (when hey-thread--renames
            (let ((map (make-hash-table :test #'equal)))
              (dolist (entry hey-thread--renames map)
                (dolist (id (or (ignore-errors
                                  (process-lines notmuch-command "search"
                                                 "--output=messages"
                                                 (concat "thread:" (car entry))))
                                nil))
                  (puthash (string-remove-prefix "id:" id) (cdr entry) map)))))))
  hey-thread--renames)

(defun hey-thread-subject (tid)
  "Your subject for thread TID, or nil."
  (cdr (assoc tid (hey-thread--load-renames))))

;;;###autoload
(defun hey-thread-rename (subject)
  "Give the thread at point your own SUBJECT.  Empty input restores the real one."
  (interactive
   (list (read-string "Call this thread: "
                      (or (hey-thread-subject (or (hey-notmuch--thread-id) ""))
                          (hey-notmuch--subject)))))
  (let ((tid (hey-notmuch--thread-id)))
    (unless tid (user-error "No thread at point"))
    (hey-notmuch--db-remove hey-thread-subject-db (concat "\\`" (regexp-quote tid) " "))
    (if (string-empty-p (string-trim subject))
        (message "Back to the sender's subject")
      ;; A newline in the value would split one override into two garbage
      ;; lines in a file the whole feature reads line by line.
      (hey-notmuch--add-to-db (format "%s %s" tid
                                      (replace-regexp-in-string "[\n\r]+" " " subject))
                              hey-thread-subject-db)
      (message "Renamed: %s" subject))
    (hey-thread--load-renames t)
    (hey-notmuch--refresh)))

(defun hey-thread-search-subject-field (format-string result)
  "Subject field for `notmuch-search-result-format', honouring renames."
  (let* ((tid (plist-get result :thread))
         (mine (and tid (hey-thread-subject tid))))
    (propertize (format format-string
                        (notmuch-sanitize (or mine (plist-get result :subject))))
                'face (if mine 'hey-thread-renamed 'notmuch-search-subject))))

(defun hey-thread-tree-subject-field (format-string msg)
  "Subject field for `notmuch-tree-result-format', honouring renames.

Mirrors notmuch's own tree subject field, including the \" ...\" elision
of a repeated subject — a renamed thread should still collapse the way
every other thread in the list does."
  (let* ((headers (plist-get msg :headers))
         (match (plist-get msg :match))
         (mine (and hey-thread--rename-messages
                    (gethash (plist-get msg :id) hey-thread--rename-messages)))
         (bare-subject (or mine
                           (notmuch-sanitize
                            (notmuch-show-strip-re (plist-get headers :Subject)))))
         (previous-subject notmuch-tree-previous-subject)
         (face (cond (mine 'hey-thread-renamed)
                     (match 'notmuch-tree-match-subject-face)
                     (t 'notmuch-tree-no-match-subject-face))))
    (setq notmuch-tree-previous-subject bare-subject)
    (propertize (format format-string
                        (if (string= previous-subject bare-subject) " ..." bare-subject))
                'face face)))

(defun hey-thread--install-subject-field (format-list search)
  "Replace the \"subject\" entry of FORMAT-LIST with ours.

Rewritten rather than replaced wholesale so a user who has customised
their columns keeps them; only the one cell that draws a subject changes,
and its format string is left exactly as it was."
  (mapcar (lambda (spec)
            (cond
             ((and (consp spec) (equal (car spec) "subject"))
              (cons (if search
                        #'hey-thread-search-subject-field
                      #'hey-thread-tree-subject-field)
                    (cdr spec)))
             ;; The tree format nests: (((\"tree\" . \"%s\") (\"subject\" . \"%s\")) . \" %-54s \")
             ((and (consp spec) (consp (car spec)) (consp (caar spec)))
              (cons (hey-thread--install-subject-field (car spec) search) (cdr spec)))
             (t spec)))
          format-list))

;; ═══════════════════════════ Merge ══════════════════════════════════
;; notmuch computes threads from References and In-Reply-To and will not be
;; argued with, so "merged" is a tag the threads share.  Nothing is rewritten,
;; nothing is lost, and unmerging is `H C-j' away.

(defun hey-thread--merge-groups (query)
  "Merge group names present on QUERY."
  (hey-notmuch--tags-in-namespace "merge/" query))

;;;###autoload
(defun hey-thread-merge ()
  "Merge the selected threads: from now on they open together.

Select two or more threads (a region in any list) and press `H j'.  If
one of them is already in a merge group the others join it, so a
conversation can be assembled a piece at a time."
  (interactive)
  (let* ((ids (hey-notmuch--region-thread-ids))
         (query (mapconcat (lambda (tid) (concat "thread:" tid)) ids " or "))
         (existing (and ids (hey-thread--merge-groups query))))
    (unless (and ids (cdr ids))
      (user-error "Select at least two threads to merge"))
    (when (cdr existing)
      (user-error "Those threads are in %d different merge groups already" (length existing)))
    (let ((group (or (car existing)
                     ;; The group id has to be unique across everything ever
                     ;; merged, and is never shown, so it is simply when it
                     ;; was made plus a little noise.
                     (format "%s-%04x" (format-time-string "%Y%m%d%H%M%S") (random 65536)))))
      (dolist (tid ids)
        (notmuch-tag (concat "thread:" tid) (list (concat "+merge/" group))))
      (message "Merged %d threads%s" (length ids)
               (if existing " into the existing group" "")))))

;;;###autoload
(defun hey-thread-merged-open ()
  "Open every thread merged with the one at point, in one buffer."
  (interactive)
  (let* ((tid (hey-notmuch--thread-id))
         (group (car (and tid (hey-thread--merge-groups (concat "thread:" tid))))))
    (unless tid (user-error "No thread at point"))
    (unless group (user-error "This thread is not merged with anything"))
    (notmuch-show (format "tag:merge/%s" group) nil nil nil
                  (format "*HEY merged: %s*" group))))

;;;###autoload
(defun hey-thread-unmerge ()
  "Take the thread at point out of its merge group."
  (interactive)
  (let* ((tid (hey-notmuch--thread-id))
         (groups (and tid (hey-thread--merge-groups (concat "thread:" tid)))))
    (unless groups (user-error "This thread is not merged with anything"))
    (notmuch-tag (concat "thread:" tid)
                 (mapcar (lambda (g) (concat "-merge/" g)) groups))
    (message "Unmerged")))

;; ═══════════════════════ The tracker report ═════════════════════════
;; Remote images are already blocked outright (`notmuch-show-text/html-blocked-images'
;; is "." in hey-notmuch.el), so no request is ever made and nothing here
;; protects you.  What this adds is the part HEY makes visible: WHO was
;; watching.  A mail with a Mailchimp beacon in it is a mail whose sender
;; expected to learn when you read it, and that is worth knowing about the
;; sender, not just about the message.

(defcustom hey-thread-tracker-domains
  '("list-manage.com" "mcsv.net" "exct.net"          ; Mailchimp, Salesforce
    "sendgrid.net" "sendgrid.com" "sparkpostmail.com"
    "mailgun.org" "pstmrk.it" "awstrack.me"          ; Mailgun, Postmark, SES
    "hubspotemail.net" "hs-sites.com" "klaviyomail.com"
    "braze.com" "customeriomail.com" "intercom-mail.com"
    "rs6.net" "createsend.com" "cmail19.com"         ; Constant Contact, Campaign Monitor
    "emltrk.com" "mailtrack.io" "bananatag.com" "yesware.com"
    "google-analytics.com" "facebook.com/tr" "mixpanel.com"
    "omnisend.com" "activehosted.com" "getdrip.com")
  "Domains whose images exist to report that you opened the mail.

Not a blocklist — nothing is loaded either way.  This is the list that
decides whether a blocked image gets called a tracker or just an image."
  :type '(repeat string)
  :group 'hey-notmuch)

(defcustom hey-thread-tracker-patterns
  '("/open" "open\\?" "track" "pixel" "beacon" "/o/" "utm_" "\\.gif\\?"
    "email_open" "trk" "/wf/open")
  "URL fragments that mark an image as a tracker whoever is serving it.

Small pixels served from the sender's own domain are the common case;
naming the pattern catches those without needing every marketing
platform's hostname."
  :type '(repeat string)
  :group 'hey-notmuch)

(defface hey-thread-tracker
  '((t :inherit warning))
  "Face for the tracker report in a show buffer."
  :group 'hey-notmuch)

(defvar hey-thread--tracker-cache (make-hash-table :test #'equal)
  "Thread id → (TRACKER-DOMAINS . OTHER-IMAGE-COUNT), so re-reading is free.")

(defun hey-thread--tracker-p (url)
  "Non-nil if URL looks like it exists to report that you opened the mail."
  (or (seq-some (lambda (d) (string-search d url)) hey-thread-tracker-domains)
      (seq-some (lambda (p) (string-match-p p url)) hey-thread-tracker-patterns)))

(defun hey-thread--url-domain (url)
  "Registrable-ish domain of URL — enough to name a tracker by."
  (if (string-match "\\`https?://\\([^/:]+\\)" url)
      (let ((host (match-string 1 url)))
        ;; Two labels is right for example.com and wrong for co.uk; the report
        ;; says "who", not "which host", and a wrong-but-recognisable answer
        ;; beats a full public-suffix list living in a mail client.
        (string-join (last (split-string host "\\.") 2) "."))
    url))

(defun hey-thread--scan-trackers (tid)
  "Scan thread TID's HTML for remote images.  Return (DOMAINS . OTHERS)."
  (or (gethash tid hey-thread--tracker-cache)
      (puthash
       tid
       (let ((trackers nil)
             (others 0))
         (dolist (msg (hey-files--forest-messages
                       (ignore-errors
                         ;; --include-html is required: without it notmuch
                         ;; reports the html part's length and omits its
                         ;; content, and there is nothing to scan.
                         (notmuch-call-notmuch-sexp
                          "show" "--format=sexp" "--format-version=5"
                          "--body=true" "--include-html" "--entire-thread=false"
                          (concat "thread:" tid)))))
           (dolist (part (mapcan #'hey-files--parts (copy-sequence (plist-get msg :body))))
             (when (and (equal (plist-get part :content-type) "text/html")
                        (stringp (plist-get part :content)))
               (let ((html (plist-get part :content))
                     (start 0))
                 (while (string-match "<img[^>]+src=[\"']?\\(https?://[^\"'> ]+\\)"
                                      html start)
                   (let ((url (match-string 1 html)))
                     (setq start (match-end 0))
                     (if (hey-thread--tracker-p url)
                         (cl-pushnew (hey-thread--url-domain url) trackers :test #'equal)
                       (setq others (1+ others)))))))))
         (cons (nreverse trackers) others))
       hey-thread--tracker-cache)))

(defun hey-thread-show-trackers ()
  "Report what was blocked, at the top of the show buffer."
  (when (derived-mode-p 'notmuch-show-mode)
    (remove-overlays (point-min) (point-max) 'hey-thread-trackers t)
    (let* ((tid (and (boundp 'notmuch-show-thread-id)
                     (string-remove-prefix "thread:" (or notmuch-show-thread-id ""))))
           (scan (and tid (not (string-empty-p tid)) (hey-thread--scan-trackers tid)))
           (trackers (car scan))
           (others (cdr scan)))
      (when (and scan (or trackers (> others 0)))
        (let ((ov (make-overlay (point-min) (point-min))))
          (overlay-put ov 'hey-thread-trackers t)
          (overlay-put
           ov 'before-string
           (propertize
            (concat "  "
                    (if trackers
                        (format "%d spy tracker%s blocked — %s"
                                (length trackers) (if (= 1 (length trackers)) "" "s")
                                (string-join trackers ", "))
                      "no trackers")
                    (when (> others 0)
                      (format " · %d other remote image%s not loaded"
                              others (if (= 1 others) "" "s")))
                    "\n\n")
            'face 'hey-thread-tracker)))))))

;;;###autoload
(defun hey-thread-trackers-report ()
  "Say who was watching this thread, in the echo area."
  (interactive)
  (let* ((tid (or (hey-notmuch--thread-id) (user-error "No thread at point")))
         (scan (hey-thread--scan-trackers tid)))
    (message "%s · %d other remote image%s"
             (if (car scan)
                 (format "%d tracker%s: %s" (length (car scan))
                         (if (= 1 (length (car scan))) "" "s")
                         (string-join (car scan) ", "))
               "No trackers")
             (cdr scan) (if (= 1 (cdr scan)) "" "s"))))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (require 'hey-files)
  (define-key hey-notmuch-map (kbd "v")   #'hey-thread-mark-seen)
  (define-key hey-notmuch-map (kbd "m")   #'hey-thread-mute)
  (define-key hey-notmuch-map (kbd "M")   #'hey-thread-unmute)
  (define-key hey-notmuch-map (kbd "S")   #'hey-thread-rename)
  (define-key hey-notmuch-map (kbd "j")   #'hey-thread-merge)
  (define-key hey-notmuch-map (kbd "C-j") #'hey-thread-merged-open)
  (define-key hey-notmuch-map (kbd "J")   #'hey-thread-unmerge)
  (define-key hey-notmuch-map (kbd "b")   #'hey-thread-trackers-report)
  ;; Renames are applied where subjects are drawn.  Done here, after notmuch
  ;; has set its own defaults, so the user's customisation of the OTHER
  ;; columns survives.
  (setq notmuch-search-result-format
        (hey-thread--install-subject-field notmuch-search-result-format t))
  (setq notmuch-tree-result-format
        (hey-thread--install-subject-field notmuch-tree-result-format nil))
  (setq notmuch-unthreaded-result-format
        (hey-thread--install-subject-field notmuch-unthreaded-result-format nil)))

(with-eval-after-load 'notmuch-show
  (add-hook 'notmuch-show-hook #'hey-thread-show-trackers))

(provide 'hey-thread)
;;; hey-thread.el ends here

;;; hey-compose.el --- Snippets, Name Tag, Away, Reply to Everyone, big files  -*- lexical-binding: t; -*-

;; Everything HEY does on the WRITING side of mail.
;;
;;   Snippets           text you send often, kept somewhere better than your
;;                      own sent folder.  `C-c s' while composing.
;;
;;   Name Tag           HEY's name for the block that goes at the bottom of
;;                      your mail.  One file, edited with `H , n', inserted by
;;                      message-mode as the signature.
;;
;;   Away               an out-of-office reply.  There is no server to do this
;;                      for us — iCloud has a vacation setting we cannot reach
;;                      from here, and msmtp only sends — so the post-new hook
;;                      sends it, under heavy guard: screened-in senders only,
;;                      once per address ever, never to a list, never to an
;;                      auto-submitted message, and never to a no-reply
;;                      address.  Those guards are the feature; an
;;                      autoresponder without them is a way to mail-bomb a
;;                      mailing list with your own address as the return path.
;;
;;   Reply to Everyone  reply to every human who has appeared in the thread,
;;                      not only to the recipients of the last message.  On a
;;                      thread that has been forwarded around, those are
;;                      different sets, and the second one is usually what you
;;                      meant.
;;
;;   Big files          attachments too big to attach.  The file goes into the
;;                      directory the dufs server already publishes
;;                      (~/.dotfiles/bin/dufs-serve, $HOME over HTTP on port
;;                      5000) and the mail carries a link.  LAN-only and
;;                      password-gated, so this is for the other machines in
;;                      the house and for yourself — it is not HEY's
;;                      upload-to-the-cloud feature and does not pretend to be.

;;; Code:

(require 'hey-notmuch)
(require 'hey-notes)
(require 'subr-x)

(declare-function notmuch-mua-new-reply "notmuch-mua")
(declare-function message-goto-body "message")
(declare-function message-fetch-field "message")
(declare-function message-position-on-field "message")
(declare-function message-remove-header "message")
(declare-function org-read-date "org")
(declare-function notmuch-user-emails "notmuch-lib")
(defvar notmuch-command)
(defvar message-signature)

;; ══════════════════════════ Snippets ════════════════════════════════
(defcustom hey-compose-snippets-file
  (expand-file-name "snippets.org" hey-notmuch-db-dir)
  "Org file holding reusable snippets: one heading per snippet."
  :type 'file
  :group 'hey-notmuch)

(defun hey-compose--snippets ()
  "Alist of snippet name → text."
  (mapcar (lambda (entry) (cons (plist-get entry :title) (plist-get entry :body)))
          (hey-notes-entries hey-compose-snippets-file)))

;;;###autoload
(defun hey-compose-snippet (name)
  "Insert snippet NAME at point."
  (interactive
   (let ((snippets (hey-compose--snippets)))
     (unless snippets
       (user-error "No snippets yet — select some text and use `%s'"
                   (substitute-command-keys "\\[hey-compose-snippet-save]")))
     (list (completing-read "Snippet: " (mapcar #'car snippets) nil t))))
  (let ((text (cdr (assoc name (hey-compose--snippets)))))
    (unless text (user-error "No snippet called %s" name))
    ;; Plain `insert', not `insert-and-inherit': a snippet dropped into a
    ;; quoted region should not silently become part of the quote.
    (insert text)))

;;;###autoload
(defun hey-compose-snippet-save (start end name)
  "Save the region from START to END as a snippet called NAME."
  (interactive
   (progn
     (unless (use-region-p) (user-error "Select the text to save first"))
     (list (region-beginning) (region-end) (read-string "Save snippet as: "))))
  (when (string-empty-p (string-trim name)) (user-error "A snippet needs a name"))
  (hey-notes-append-entry hey-compose-snippets-file
                          (string-trim name)
                          (list (cons "HEY_SNIPPET" (format-time-string "[%Y-%m-%d %a %H:%M]")))
                          (buffer-substring-no-properties start end))
  (deactivate-mark)
  (message "Saved snippet: %s" name))

;;;###autoload
(defun hey-compose-snippets-browse ()
  "Open snippets.org itself."
  (interactive)
  (find-file hey-compose-snippets-file))

;; ══════════════════════════ Name Tag ════════════════════════════════
(defconst hey-compose-nametag-file "nametag"
  "File in `hey-notmuch-db-dir' holding your signature block.")

(defun hey-compose-nametag ()
  "Your Name Tag, or nil if you have not written one."
  (hey-notmuch--file-string hey-compose-nametag-file))

(defun hey-compose--apply-nametag ()
  "Use the Name Tag as this message's signature.

Set per message in `message-setup-hook' rather than once at load: the
file is meant to be edited, and a signature captured at startup would go
on being the old one until Emacs restarted."
  (setq-local message-signature (or (hey-compose-nametag) nil)))

(add-hook 'message-setup-hook #'hey-compose--apply-nametag)

;;;###autoload
(defun hey-compose-nametag-edit ()
  "Write or change your Name Tag — the block at the bottom of your mail."
  (interactive)
  (hey-compose--edit-file
   (hey-notmuch--db-path hey-compose-nametag-file)
   "Name Tag"
   (or (hey-compose-nametag) "")
   (lambda (text)
     (if (string-empty-p (string-trim text))
         (progn (delete-file (hey-notmuch--db-path hey-compose-nametag-file))
                (message "Name Tag removed"))
       (hey-notmuch--file-set hey-compose-nametag-file text)
       (message "Name Tag saved")))))

;; A tiny shared editor for the one-value settings files.  Same shape as the
;; note editor in hey-notes.el and deliberately so: two settings that behave
;; differently for no reason are two settings you have to remember separately.
(defvar-local hey-compose--save-function nil)
(defvar-local hey-compose--return nil)

(defvar hey-compose-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'hey-compose-edit-save)
    (define-key map (kbd "C-c C-k") #'hey-compose-edit-cancel)
    map)
  "Keymap for the small HEY settings editor.")

(define-minor-mode hey-compose-edit-mode
  "Edit a one-value HEY setting.
\\{hey-compose-edit-mode-map}"
  :lighter " HEY-edit"
  :keymap hey-compose-edit-mode-map)

(defun hey-compose--edit-file (_file title initial save-function)
  "Edit INITIAL under TITLE; on save, call SAVE-FUNCTION with the text."
  (let ((buffer (get-buffer-create (format "*HEY %s*" title)))
        (config (current-window-configuration)))
    (with-current-buffer buffer
      (erase-buffer)
      (insert initial)
      (text-mode)
      (hey-compose-edit-mode 1)
      (setq hey-compose--save-function save-function
            hey-compose--return config
            header-line-format
            (substitute-command-keys
             (format " %s — \\[hey-compose-edit-save] save · \\[hey-compose-edit-cancel] cancel · empty to clear"
                     title)))
      (goto-char (point-max)))
    (select-window (display-buffer-in-side-window buffer '((side . bottom) (window-height . 12))))))

(defun hey-compose-edit-save ()
  "Save this setting."
  (interactive)
  (let ((fn hey-compose--save-function)
        (config hey-compose--return)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (unless fn (user-error "Not editing a HEY setting"))
    (quit-window t)
    (when config (set-window-configuration config))
    (funcall fn text)))

(defun hey-compose-edit-cancel ()
  "Abandon this edit."
  (interactive)
  (let ((config hey-compose--return))
    (quit-window t)
    (when config (set-window-configuration config)))
  (message "Unchanged"))

;; ════════════════════════════ Away ══════════════════════════════════
(defconst hey-compose-away-file "away"
  "File in `hey-notmuch-db-dir' holding the away message.

Format, because the post-new hook parses the same file in bash:

    until: 2026-08-25
    subject: Away until Monday

    the message body

The `until:' line is mandatory — an autoresponder with no end date is one
you will still be running at Christmas.  Everything after the first blank
line is the body.")

(defconst hey-compose-away-replied-db "away-replied.db"
  "Addresses already sent an away reply.  Never sent a second one.")

(defun hey-compose-away-status ()
  "Description of the away autoresponder's state."
  (let ((text (hey-notmuch--file-string hey-compose-away-file)))
    (if (null text)
        "off"
      (if (string-match "^until:[ \t]*\\(.*\\)$" text)
          (let* ((until (string-trim (match-string 1 text)))
                 (time (ignore-errors (date-to-time (concat until " 23:59:59")))))
            (cond ((null time) (format "on, until %s (unparseable date)" until))
                  ((time-less-p time (current-time)) (format "expired on %s" until))
                  (t (format "on, until %s" until))))
        "on, but with no until: line — the hook will not send it"))))

;;;###autoload
(defun hey-compose-away ()
  "Turn the away autoresponder on, change it, or turn it off.

Saving an empty buffer turns it off and forgets who has already been
replied to, so the next time you go away everyone hears from you once
again."
  (interactive)
  (let* ((existing (hey-notmuch--file-string hey-compose-away-file))
         (until (unless existing
                  (require 'org)
                  (format-time-string "%Y-%m-%d"
                                      (org-read-date t t nil "Away until? "))))
         (initial (or existing
                      (format "until: %s\nsubject: Away until %s\n\n%s\n"
                              until until
                              "I'm away and not reading mail — I'll reply when I'm back."))))
    (message "Away is currently %s" (hey-compose-away-status))
    (hey-compose--edit-file
     (hey-notmuch--db-path hey-compose-away-file)
     "Away message" initial
     (lambda (text)
       (if (string-empty-p (string-trim text))
           (progn
             (when (file-exists-p (hey-notmuch--db-path hey-compose-away-file))
               (delete-file (hey-notmuch--db-path hey-compose-away-file)))
             ;; Clearing the "already replied" list on the way OUT, not on the
             ;; way in: the list has to survive the whole time you are away,
             ;; and it must not survive into the next trip.
             (when (file-exists-p (hey-notmuch--db-path hey-compose-away-replied-db))
               (delete-file (hey-notmuch--db-path hey-compose-away-replied-db)))
             (message "Away is off"))
         (unless (string-match-p "^until:" text)
           (user-error "The away message needs an `until:' line"))
         (hey-notmuch--file-set hey-compose-away-file (string-trim text))
         (message "Away is %s" (hey-compose-away-status)))))))

;; ═══════════════════════ Reply to Everyone ══════════════════════════
(defun hey-compose--thread-addresses (tid)
  "Every address that has appeared in thread TID, yours removed.

\"Yours\" is every address notmuch knows about — `user.primary_email'
plus `user.other_email' — not just the one you send from.  Mail to this
mailbox arrives at more than one address (a domain address forwarding
into iCloud), and cc-ing yourself at the forwarding address on every
reply is both silly and a way to double every thread."
  (let* ((raw (or (ignore-errors
                    (process-lines notmuch-command "address"
                                   "--output=sender" "--output=recipients"
                                   "--deduplicate=address"
                                   (concat "thread:" tid)))
                  nil))
         (mine (mapcar #'downcase (notmuch-user-emails))))
    (seq-remove (lambda (a)
                  (let ((addr (downcase (or (cadr (mail-extract-address-components a)) a))))
                    (or (string-empty-p addr) (member addr mine))))
                raw)))

;;;###autoload
(defun hey-compose-reply-everyone ()
  "Reply to everyone who has taken part in this thread.

`R' (reply-all) answers the recipients of ONE message.  This answers the
thread: anyone who wrote, was written to, or was copied at any point,
minus you.  On a thread that has been forwarded on, that difference is
the colleague who joined at message four and would otherwise be dropped."
  (interactive)
  (let* ((tid (or (hey-notmuch--thread-id) (user-error "No thread at point")))
         (msgid (or (hey-notmuch--message-id) (user-error "No message at point")))
         (everyone (hey-compose--thread-addresses tid)))
    (notmuch-mua-new-reply (concat "id:" msgid) nil t)
    (let* ((existing (downcase (concat (or (message-fetch-field "To") "") ", "
                                       (or (message-fetch-field "Cc") ""))))
           (missing (seq-remove
                     (lambda (a)
                       (let ((addr (downcase (or (cadr (mail-extract-address-components a)) a))))
                         (string-search addr existing)))
                     everyone)))
      (when missing
        (save-excursion
          (message-position-on-field "Cc")
          (let ((current (string-trim (or (message-fetch-field "Cc") ""))))
            (unless (string-empty-p current) (insert ", "))
            (insert (string-join missing ", ")))))
      (message-goto-body)
      (message "Replying to %d participant%s%s"
               (+ (length everyone))
               (if (= 1 (length everyone)) "" "s")
               (if missing (format " (%d added)" (length missing)) "")))))

;; ═════════════════════════ Big files ════════════════════════════════
(defcustom hey-compose-bigfile-dir
  (expand-file-name "~/Public/hey-mail")
  "Directory big attachments are copied into.

Must be somewhere the dufs server publishes.  dufs serves $HOME
(bin/dufs-serve), so anywhere under it works; ~/Public is the
conventional place to put things meant to be fetched, and keeping mail
files in their own subdirectory means one `rm -r' cleans up after a
year of sending."
  :type 'directory
  :group 'hey-notmuch)

(defcustom hey-compose-bigfile-url
  (format "http://%s.local:5000" (system-name))
  "Base URL of the dufs server, as the recipient will type it.

`.local' because that is what mDNS answers on this network; dufs binds
0.0.0.0 and the firewall opens 5000 to the LAN, so this reaches other
machines in the house and nothing beyond it."
  :type 'string
  :group 'hey-notmuch)

(defun hey-compose--dufs-running-p ()
  "Non-nil if the dufs user unit is active."
  (eq 0 (call-process "systemctl" nil nil nil "--user" "is-active" "--quiet" "dufs.service")))

;;;###autoload
(defun hey-compose-attach-big-file (file)
  "Publish FILE through dufs and put a link to it in this message.

For anything an IMAP server will refuse: iCloud caps a message at 20MB,
and a link that works costs less than an attachment that bounces."
  (interactive "fBig file to send: ")
  (unless (file-readable-p file) (user-error "Cannot read %s" file))
  (make-directory hey-compose-bigfile-dir t)
  (let* ((name (file-name-nondirectory file))
         (target (expand-file-name name hey-compose-bigfile-dir))
         (size (file-attribute-size (file-attributes file))))
    (when (and (file-exists-p target)
               (not (yes-or-no-p (format "%s is already published — replace it? " name))))
      (user-error "Not published"))
    (copy-file file target t)
    (unless (hey-compose--dufs-running-p)
      (if (yes-or-no-p "The dufs server is not running — start it? ")
          (call-process "systemctl" nil nil nil "--user" "start" "dufs.service")
        (message "Published, but nobody can fetch it until dufs is running")))
    (let ((url (format "%s/%s/%s"
                       (string-trim-right hey-compose-bigfile-url "/")
                       (string-trim (file-relative-name hey-compose-bigfile-dir
                                                        (expand-file-name "~")))
                       ;; A space in a filename would end the URL early in
                       ;; every mail client there is.
                       (url-hexify-string name))))
      (when (derived-mode-p 'message-mode) (message-goto-body))
      ;; The `iec' flavour, because the bare one renders 14 bytes as "14" —
      ;; a number with no unit next to a download link reads as a price.
      (insert (format "%s\n(%s, %s — you will need the file-server password)\n"
                      url name (file-size-human-readable size 'iec " ")))
      (kill-new url)
      (message "Published %s (%s) — link inserted and copied"
               name (file-size-human-readable size 'iec " ")))))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "E") #'hey-compose-reply-everyone)
  (define-key hey-notmuch-settings-map (kbd "n") #'hey-compose-nametag-edit)
  (define-key hey-notmuch-settings-map (kbd "a") #'hey-compose-away)
  (define-key hey-notmuch-settings-map (kbd "S") #'hey-compose-snippets-browse))

;; `C-c <letter>' is the space Emacs reserves for the user, and message-mode
;; leaves all of it free — checked: C-c a/b/e/f/g/h/j/k/l/n/p/q/s/t/u/v/x/y/z
;; are all unbound there.
(with-eval-after-load 'message
  (define-key message-mode-map (kbd "C-c s") #'hey-compose-snippet)
  (define-key message-mode-map (kbd "C-c S") #'hey-compose-snippet-save)
  (define-key message-mode-map (kbd "C-c f") #'hey-compose-attach-big-file)
  (define-key message-mode-map (kbd "C-c n") #'hey-compose-nametag-edit))

(provide 'hey-compose)
;;; hey-compose.el ends here

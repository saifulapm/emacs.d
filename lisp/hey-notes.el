;;; hey-notes.el --- Notes on threads, contacts and yourself  -*- lexical-binding: t; -*-

;; HEY has three kinds of note, and they are three different things:
;;
;;   * a note ON A THREAD     — "waiting on the invoice, chased 2 Aug"
;;   * a note ON A CONTACT    — "always cc's the wrong address"
;;   * a note TO YOURSELF     — which HEY drops into your Imbox as if it
;;                              were mail, because that is where you will
;;                              look for it
;;
;; The first two are annotations on someone else's mail, so they live in an
;; org file outside the mail store: notes.org in `hey-notmuch-db-dir', which
;; is neither in this public repo nor inside ~/Mail (wiping the maildir to
;; re-sync from scratch must not take your notes with it).
;;
;; The third is not an annotation at all — it is a message you wrote to
;; yourself — so it is delivered as one, with `notmuch insert' into a
;; local-only maildir.  That means it shows up in the Imbox, in searches, in
;; `notmuch count', and it can be archived, replied to and screened like
;; anything else, without a line of special-case code anywhere.
;;
;; Thread and contact notes are shown at the top of the show buffer for the
;; thread or the sender they belong to, because a note you have to go and ask
;; for is a note you will forget you wrote.

;;; Code:

(require 'hey-notmuch)
(require 'subr-x)

(declare-function org-mode "org")
(declare-function org-back-to-heading "org")
(declare-function org-end-of-subtree "org")
(declare-function notmuch-show-get-from "notmuch-show")
(declare-function notmuch-refresh-all-buffers "notmuch-lib")
(declare-function rfc2047-encode-string "rfc2047")
(defvar notmuch-show-thread-id)
(defvar notmuch-command)

(defcustom hey-notes-file
  (expand-file-name "notes.org" hey-notmuch-db-dir)
  "Org file holding thread and contact notes.

One top-level heading per note, keyed by a `HEY_KEY' property rather than
by the heading text, so renaming a subject (or a person) never orphans
what you wrote about them.  Plain org, so it opens in agenda views, greps
like anything else, and outlives this file."
  :type 'file
  :group 'hey-notmuch)

(defcustom hey-notes-maildir "notes"
  "Maildir folder, relative to the notmuch mail root, for notes to yourself.

Local-only on purpose: ~/.mbsyncrc's MaildirStore is rooted at
~/Mail/icloud/, so a folder beside it is indexed by notmuch and never
seen by mbsync.  Notes to yourself therefore never leave the machine and
can never collide with an IMAP UID."
  :type 'string
  :group 'hey-notmuch)

(defface hey-notes-banner
  '((t :inherit font-lock-doc-face :extend t))
  "Face for the note shown at the top of a thread."
  :group 'hey-notmuch)

;; ─────────────────────── the org file, read side ────────────────────
;; Reading is done with a regexp over a temp buffer rather than through org:
;; this runs on `notmuch-show-hook', i.e. every time you open a thread, and
;; pulling in org (and its parser) to fish out a paragraph would put a visible
;; pause on the most common keystroke in the client.

(defconst hey-notes--key-property "HEY_KEY"
  "Org property that keys a note to a thread id or an address.")

(defun hey-notes--unescape (text)
  "Undo the org escaping applied by `hey-notes--escape' in TEXT."
  (replace-regexp-in-string "^,\\(,*[*#]\\)" "\\1" text))

(defun hey-notes--escape (text)
  "Comma-escape lines of TEXT that org would otherwise read as structure.
A note beginning \"* remember to…\" is a sentence, not a heading; org's
own convention for saying so is a leading comma."
  (replace-regexp-in-string "^\\(,*[*#]\\)" ",\\1" text))

(defun hey-notes--read (key)
  "Body text of the note stored under KEY, or nil if there is none."
  (when (file-readable-p hey-notes-file)
    (with-temp-buffer
      (insert-file-contents hey-notes-file)
      (goto-char (point-min))
      (when (re-search-forward
             (format "^[ \t]*:%s:[ \t]+%s[ \t]*$"
                     hey-notes--key-property (regexp-quote key))
             nil t)
        ;; Body starts after the property drawer's :END: and runs to the next
        ;; top-level heading (or the end of the file).
        (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
          (forward-line 1)
          (let* ((start (point))
                 (end (if (re-search-forward "^\\* " nil t)
                          (match-beginning 0)
                        (point-max)))
                 (text (string-trim (buffer-substring-no-properties start end))))
            (unless (string-empty-p text)
              (hey-notes--unescape text))))))))

;; ─────────────────────── the org file, write side ───────────────────
(defun hey-notes--write (key title text)
  "Store TEXT as the note for KEY, titled TITLE.

An empty TEXT deletes the note outright: a note you have cleared should
leave no heading behind to make the file look like it still has one."
  (with-current-buffer (find-file-noselect hey-notes-file)
    (save-excursion
      (goto-char (point-min))
      (let ((found (re-search-forward
                    (format "^[ \t]*:%s:[ \t]+%s[ \t]*$"
                            hey-notes--key-property (regexp-quote key))
                    nil t)))
        (when found
          ;; Delete the whole existing entry — heading, drawer and body — and
          ;; re-write it below, so one code path builds every note and the
          ;; drawer can never drift out of the shape `hey-notes--read' expects.
          (goto-char (match-beginning 0))
          (re-search-backward "^\\* " nil t)
          (let ((start (point)))
            (forward-line 1)
            (delete-region start (if (re-search-forward "^\\* " nil t)
                                     (match-beginning 0)
                                   (point-max))))))
      (unless (string-empty-p (string-trim text))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* %s\n:PROPERTIES:\n:%s: %s\n:HEY_UPDATED: %s\n:END:\n%s\n\n"
                        (or title key)
                        hey-notes--key-property key
                        (format-time-string "[%Y-%m-%d %a %H:%M]")
                        (hey-notes--escape (string-trim text))))))
    (save-buffer)))

;; ─────────────── the same file format, for other things ─────────────
;; Clips and snippets are the same shape as a note — a heading, a property
;; drawer, a body — so they share the reader and the writer rather than each
;; growing its own org parser.  Regexp-based for the same reason as above:
;; these run when a list is drawn, and org's parser is not cheap.

(defun hey-notes-entries (file)
  "Parse FILE as HEY org entries.

Returns a list of plists, oldest first: :title, :body and :props (an
alist of the property drawer, keys upcased strings)."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((entries nil))
        (while (re-search-forward "^\\* +\\(.*\\)$" nil t)
          (let* ((title (match-string 1))
                 (start (point))
                 (end (save-excursion
                        (if (re-search-forward "^\\* " nil t)
                            (match-beginning 0)
                          (point-max))))
                 (chunk (buffer-substring-no-properties start end))
                 (props nil)
                 (body chunk))
            (when (string-match "\\`[ \t\n]*:PROPERTIES:\n\\(\\(?:.*\n\\)*?\\):END:[ \t]*\n" chunk)
              (let ((drawer (match-string 1 chunk)))
                (setq body (substring chunk (match-end 0)))
                (dolist (line (split-string drawer "\n" t))
                  (when (string-match "\\`[ \t]*:\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                    (push (cons (upcase (match-string 1 line))
                                (string-trim (match-string 2 line)))
                          props)))))
            (push (list :title title
                        :props (nreverse props)
                        :body (hey-notes--unescape (string-trim body)))
                  entries)
            (goto-char end)))
        (nreverse entries)))))

(defun hey-notes-append-entry (file title props body)
  "Append an entry to FILE with TITLE, PROPS (an alist) and BODY."
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (when (file-readable-p file)
      (insert-file-contents file))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* %s\n:PROPERTIES:\n" title))
    (dolist (p props)
      (insert (format ":%s: %s\n" (car p) (cdr p))))
    (insert ":END:\n" (hey-notes--escape (string-trim body)) "\n\n")
    (write-region (point-min) (point-max) file nil 'silent)))

(defun hey-notes-delete-entry (file property value)
  "Delete the entry in FILE whose PROPERTY is VALUE.  Return non-nil if one was."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward (format "^[ \t]*:%s:[ \t]+%s[ \t]*$"
                                       (regexp-quote property) (regexp-quote value))
                               nil t)
        (re-search-backward "^\\* " nil t)
        (let ((start (point)))
          (forward-line 1)
          (delete-region start (if (re-search-forward "^\\* " nil t)
                                   (match-beginning 0)
                                 (point-max))))
        (write-region (point-min) (point-max) file nil 'silent)
        t))))

;; ──────────────────────────── editing ───────────────────────────────
;; A dedicated little buffer rather than dropping you into notes.org: the note
;; you are writing is about the thread you are looking at, and sending you off
;; to navigate an org file loses that thread — literally, since the window
;; showing it is the one org would take.

(defvar-local hey-notes--key nil "Note key being edited in this buffer.")
(defvar-local hey-notes--title nil "Heading to file this note under.")
(defvar-local hey-notes--return nil "Window configuration to restore on exit.")

(defvar hey-notes-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'hey-notes-save)
    (define-key map (kbd "C-c C-k") #'hey-notes-cancel)
    map)
  "Keymap while editing a HEY note.")

(define-minor-mode hey-notes-edit-mode
  "Minor mode for the HEY note editing buffer.
\\{hey-notes-edit-mode-map}"
  :lighter " Note"
  :keymap hey-notes-edit-mode-map)

(defun hey-notes--edit (key title)
  "Edit the note stored under KEY, titled TITLE, in a window below."
  (let ((buffer (get-buffer-create (format "*HEY note: %s*" title)))
        (config (current-window-configuration))
        (existing (hey-notes--read key)))
    (with-current-buffer buffer
      (erase-buffer)
      (when existing (insert existing "\n"))
      ;; text-mode, not org-mode: this is a paragraph about a person, and
      ;; loading org here would cost a second the first time for folding and
      ;; agenda machinery that a three-line note has no use for.  The file it
      ;; lands in is still org.
      (text-mode)
      (hey-notes-edit-mode 1)
      (setq hey-notes--key key
            hey-notes--title title
            hey-notes--return config)
      (setq header-line-format
            (substitute-command-keys
             (format " Note on %s — \\[hey-notes-save] save, \\[hey-notes-cancel] cancel" title)))
      (goto-char (point-max)))
    ;; A short window: a note is a couple of lines, and stealing half the
    ;; frame for it would make writing one feel like a context switch.
    (select-window (display-buffer-in-side-window buffer '((side . bottom) (window-height . 10))))))

(defun hey-notes-save ()
  "Save the note being edited and go back to what you were reading."
  (interactive)
  (unless hey-notes--key (user-error "Not editing a note"))
  (let ((key hey-notes--key)
        (title hey-notes--title)
        (config hey-notes--return)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (hey-notes--write key title text)
    (quit-window t)
    (when config (set-window-configuration config))
    (hey-notes-show-banner)
    (message (if (string-empty-p (string-trim text)) "Note cleared" "Note saved"))))

(defun hey-notes-cancel ()
  "Abandon the note being edited."
  (interactive)
  (let ((config hey-notes--return))
    (quit-window t)
    (when config (set-window-configuration config)))
  (message "Note unchanged"))

;; ───────────────────────── entry points ─────────────────────────────
(defun hey-notes--thread-key (&optional tid)
  "Note key for thread TID (or the thread at point)."
  (let ((tid (or tid (hey-notmuch--thread-id))))
    (and tid (concat "thread:" tid))))

(defun hey-notes--contact-key (&optional addr)
  "Note key for ADDR (or the sender at point)."
  (let ((addr (or addr (hey-notmuch--from-address))))
    (and addr (concat "contact:" addr))))

;;;###autoload
(defun hey-notes-thread ()
  "Write (or edit) a note on the thread at point."
  (interactive)
  (let ((key (hey-notes--thread-key))
        (subject (or (hey-notmuch--subject) "this thread")))
    (unless key (user-error "No thread at point"))
    (hey-notes--edit key subject)))

;;;###autoload
(defun hey-notes-contact (&optional addr)
  "Write (or edit) a note on ADDR, or on the sender at point."
  (interactive)
  (let ((key (hey-notes--contact-key addr)))
    (unless key (user-error "No sender address at point"))
    (hey-notes--edit key (string-remove-prefix "contact:" key))))

;;;###autoload
(defun hey-notes-browse ()
  "Open notes.org itself — every note you have written, in one file."
  (interactive)
  (find-file hey-notes-file)
  (when (fboundp 'org-mode) (org-mode)))

;; ───────────────── the banner in the show buffer ────────────────────
(defun hey-notes--banner-text (label text)
  "Render TEXT under LABEL as one indented block for the show buffer."
  (concat
   (propertize (format "  ┌ %s\n" label) 'face 'hey-notes-banner)
   (mapconcat (lambda (line)
                (propertize (format "  │ %s\n" line) 'face 'hey-notes-banner))
              (split-string text "\n")
              "")
   (propertize "  └────\n\n" 'face 'hey-notes-banner)))

(defun hey-notes-show-banner ()
  "Show the notes for this thread and its sender at the top of the buffer.

An overlay, not inserted text: a notmuch show buffer is rebuilt from the
database on every refresh and is read-only in between, so anything
written into it would be either clobbered or in the way of `n'/`p'."
  (when (derived-mode-p 'notmuch-show-mode)
    (remove-overlays (point-min) (point-max) 'hey-notes t)
    (let* ((tid (and (boundp 'notmuch-show-thread-id) notmuch-show-thread-id))
           (thread-note (and tid (hey-notes--read
                                  (concat "thread:" (string-remove-prefix "thread:" tid)))))
           (addr (save-excursion (goto-char (point-min))
                                 (ignore-errors (hey-notmuch--from-address))))
           (contact-note (and addr (hey-notes--read (concat "contact:" addr))))
           (text (concat (and thread-note (hey-notes--banner-text "Note on this thread" thread-note))
                         (and contact-note (hey-notes--banner-text
                                            (format "Note on %s" addr) contact-note)))))
      (unless (string-empty-p text)
        (let ((ov (make-overlay (point-min) (point-min))))
          (overlay-put ov 'hey-notes t)
          (overlay-put ov 'before-string text))))))

;; Inside `with-eval-after-load', not at top level: `notmuch-show-hook' is a
;; defcustom, and `add-hook' on a not-yet-bound variable gives it a value —
;; after which notmuch-show.el's own defcustom declines to set the default and
;; its `notmuch-show-turn-on-visual-line-mode' is silently lost.
(with-eval-after-load 'notmuch-show
  (add-hook 'notmuch-show-hook #'hey-notes-show-banner))

;; ──────────────────── a note to yourself, as mail ───────────────────
(defvar hey-notes-self-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'hey-notes-self-file)
    (define-key map (kbd "C-c C-k") #'hey-notes-cancel)
    map)
  "Keymap while writing a note to yourself.")

(define-minor-mode hey-notes-self-mode
  "Minor mode for writing a note that lands in your own Imbox.
\\{hey-notes-self-mode-map}"
  :lighter " Note→Imbox"
  :keymap hey-notes-self-mode-map)

;;;###autoload
(defun hey-notes-inbox ()
  "Write a note to yourself.  It arrives in your Imbox like any other mail."
  (interactive)
  (let ((buffer (get-buffer-create "*HEY note to self*"))
        (config (current-window-configuration)))
    (with-current-buffer buffer
      (erase-buffer)
      (text-mode)
      (hey-notes-self-mode 1)
      (setq hey-notes--return config)
      (setq header-line-format
            (substitute-command-keys
             " First line is the subject — \\[hey-notes-self-file] file it, \\[hey-notes-cancel] cancel"))
      (auto-fill-mode -1))
    (select-window (display-buffer-in-side-window buffer '((side . bottom) (window-height . 12))))))

(defun hey-notes--message-id ()
  "A Message-Id for a locally delivered note.
Never leaves this machine, but still has to be globally unique: notmuch
keys the whole database on it, and a collision would merge two notes into
one thread."
  (format "<hey-note-%s-%04x@%s>"
          (format-time-string "%Y%m%d%H%M%S")
          (random 65536)
          (system-name)))

(defun hey-notes--rfc822 (subject body)
  "Build the note as an RFC 822 message from you, to you.

Written by hand rather than through message-mode because nothing is being
sent: this goes straight to `notmuch insert', so there is no envelope, no
msmtp, no network, and the only requirements are the headers notmuch
needs in order to index and thread it."
  (require 'rfc2047)
  (let ((me (format "%s <%s>" (or user-full-name "") user-mail-address))
        ;; %a and %b are locale-dependent; RFC 822 dates are not.  A German
        ;; locale would emit "Mo, 17 Aug" and notmuch would fail to parse the
        ;; date, leaving the note stamped with the epoch.
        (date (let ((system-time-locale "C"))
                (format-time-string "%a, %d %b %Y %H:%M:%S %z"))))
    (concat "From: " me "\n"
            "To: " me "\n"
            "Subject: " (rfc2047-encode-string subject) "\n"
            "Date: " date "\n"
            "Message-ID: " (hey-notes--message-id) "\n"
            "MIME-Version: 1.0\n"
            "Content-Type: text/plain; charset=utf-8\n"
            "Content-Transfer-Encoding: 8bit\n"
            "X-HEY-Note: self\n"
            "\n"
            body
            (if (string-suffix-p "\n" body) "" "\n"))))

(defun hey-notes-self-file ()
  "Deliver the note being written into your own Imbox."
  (interactive)
  (let* ((raw (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (lines (split-string raw "\n"))
         (subject (string-trim (or (car lines) "")))
         (body (string-join (cdr lines) "\n"))
         (config hey-notes--return))
    (when (string-empty-p subject) (user-error "A note needs at least one line"))
    (let ((errors (generate-new-buffer " *hey-notes-insert*")))
      (unwind-protect
          (with-temp-buffer
            (insert (hey-notes--rfc822 subject body))
            ;; The message declares charset=utf-8, so it had better be written
            ;; as utf-8 whatever the ambient default is; -unix because a
            ;; stray CR would end up inside the body notmuch indexes.
            (let* ((coding-system-for-write 'utf-8-unix)
                   (status (apply #'call-process-region (point-min) (point-max)
                                  notmuch-command nil errors nil
                                  (list "insert" "--create-folder"
                                        (concat "--folder=" hey-notes-maildir)
                                        ;; new.tags gives unread+inbox+new.
                                        ;; Keeping unread and inbox is the
                                        ;; point — the note sits in the Imbox
                                        ;; until dealt with.  `new' is dropped
                                        ;; because that tag means "the post-new
                                        ;; hook has not looked at this yet",
                                        ;; and no hook is running here: leaving
                                        ;; it set would have the next real sync
                                        ;; count the note as newly arrived mail
                                        ;; and pop a notification for it.
                                        ;; `screened' because you are,
                                        ;; obviously, screened in.
                                        "+note" "+screened" "-new"))))
              (unless (eq status 0)
                (user-error "notmuch insert failed (exit %s): %s" status
                            (string-trim (with-current-buffer errors (buffer-string)))))))
        (kill-buffer errors)))
    (quit-window t)
    (when config (set-window-configuration config))
    (hey-notmuch--refresh)
    (message "Note filed in your Imbox: %s" subject)))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "n") #'hey-notes-thread)
  (define-key hey-notmuch-map (kbd "N") #'hey-notes-contact)
  ;; `y' for yourself: the third note is the one you write TO yourself, and it
  ;; is common enough in HEY to deserve a letter rather than a settings entry.
  (define-key hey-notmuch-map (kbd "y") #'hey-notes-inbox)
  (define-key hey-notmuch-settings-map (kbd "N") #'hey-notes-browse))

(provide 'hey-notes)
;;; hey-notes.el ends here

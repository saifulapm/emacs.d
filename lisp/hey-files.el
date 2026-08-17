;;; hey-files.el --- Every attachment you have ever been sent  -*- lexical-binding: t; -*-

;; HEY's Files screen: all the attachments in one list, so finding a document
;; never starts with remembering which thread it came in on.  You remember the
;; invoice; you do not remember that it arrived under "Re: Fwd: quick one".
;;
;; There is no separate index and nothing to keep in sync — `notmuch show'
;; already reports every MIME part of every message, so the list is built by
;; asking the database and walking the part tree.  Measured on this mailbox:
;; 46 messages carry `tag:attachment', 43 named attachments come back, and the
;; whole scan takes 20ms.  That is why it is done live on every `g' rather
;; than cached into yet another file that could go stale.  (The three messages
;; that produce nothing have parts with no filename — an inline image, or a
;; multipart/related body — and a row with no name is not a file you could
;; have gone looking for.)
;;
;; The part-walking here is also what the contact page uses for its "recent
;; files" block (hey-contact.el).

;;; Code:

(require 'hey-notmuch)
(require 'tabulated-list)
(require 'subr-x)

(declare-function notmuch-show "notmuch-show")
(declare-function notmuch-call-notmuch-sexp "notmuch-lib")
(defvar notmuch-command)

;; ─────────────────────── walking the part tree ──────────────────────
;; `notmuch show --format=sexp' returns a forest: a list of threads, each a
;; list of trees, each tree a two-element (MESSAGE REPLIES) list.  Nothing in
;; notmuch.el exposes that as a flat list of messages outside its own show
;; buffer, so it is unpicked here.

(defun hey-files--tree-messages (tree)
  "Every message plist in TREE, a (MESSAGE REPLIES) pair from notmuch show."
  (let ((msg (car tree))
        (replies (cadr tree)))
    (append (when (plist-get msg :id) (list msg))
            (mapcan #'hey-files--tree-messages (copy-sequence replies)))))

(defun hey-files--forest-messages (forest)
  "Every message plist in FOREST, notmuch show's nested output."
  (mapcan #'hey-files--tree-messages
          (apply #'append (mapcar #'copy-sequence forest))))

(defun hey-files--parts (part)
  "PART and, recursively, the parts inside it."
  (cons part
        (let ((content (plist-get part :content)))
          ;; :content is a STRING for text parts, a list of parts for
          ;; multipart, and a list of whole messages for message/rfc822 —
          ;; which has no :content-type of its own, hence the check rather
          ;; than a bare `listp'.
          (when (and (consp content) (plist-get (car content) :content-type))
            (mapcan #'hey-files--parts (copy-sequence content))))))

(defun hey-files-attachments (query &optional limit)
  "Attachments of the messages matching QUERY, newest first.

Each entry is a plist: :filename :content-type :bytes :part :message-id
:subject :from :timestamp :date.  LIMIT, if given, is a maximum number of
MESSAGES to look at (not attachments) — the contact page wants the last
handful, the Files screen wants all of them."
  (let* ((ids (when limit
                (ignore-errors
                  (process-lines notmuch-command "search" "--output=messages"
                                 "--sort=newest-first" (format "--limit=%d" limit)
                                 (format "(%s) and tag:attachment" query)))))
         ;; With a limit we ask about exactly those messages; without one we
         ;; hand the whole query over and let notmuch do the matching.
         (effective (cond ((and limit (null ids)) nil)
                          (limit (mapconcat #'identity ids " or "))
                          (t (format "(%s) and tag:attachment" query))))
         (forest (and effective
                      (ignore-errors
                        (notmuch-call-notmuch-sexp
                         "show" "--format=sexp" "--format-version=5"
                         "--body=true" "--entire-thread=false" effective))))
         (found nil))
    (dolist (msg (hey-files--forest-messages forest))
      (let ((headers (plist-get msg :headers)))
        (dolist (part (mapcan #'hey-files--parts (copy-sequence (plist-get msg :body))))
          ;; A filename is what makes a part an attachment: the text and HTML
          ;; bodies have a content-length too, and listing those would bury
          ;; the one PDF you were looking for under 3000 message bodies.
          (when (plist-get part :filename)
            (push (list :filename (plist-get part :filename)
                        :content-type (plist-get part :content-type)
                        :bytes (plist-get part :content-length)
                        :part (plist-get part :id)
                        :message-id (plist-get msg :id)
                        :subject (or (plist-get headers :Subject) "")
                        :from (or (plist-get headers :From) "")
                        :timestamp (or (plist-get msg :timestamp) 0)
                        :date (or (plist-get msg :date_relative) ""))
                  found)))))
    (sort found (lambda (a b) (> (plist-get a :timestamp) (plist-get b :timestamp))))))

;; ───────────────────────── extracting one ───────────────────────────
(defun hey-files--extract (entry destination)
  "Write ENTRY's attachment to DESTINATION.  Return DESTINATION.

`notmuch show --part' with the raw format hands back the DECODED bytes —
verified on a base64 invoice, where the 62872-byte encoded part came out
as a 46540-byte file that `file' calls a PDF — so nothing here has to
know about transfer encodings."
  (let ((status (with-temp-buffer
                  (let ((coding-system-for-read 'binary)
                        (coding-system-for-write 'binary))
                    (prog1 (call-process notmuch-command nil t nil
                                         "show" "--format=raw"
                                         (format "--part=%s" (plist-get entry :part))
                                         (concat "id:" (plist-get entry :message-id)))
                      (write-region (point-min) (point-max) destination nil 'silent))))))
    (unless (eq status 0)
      (user-error "Could not extract %s (notmuch exit %s)"
                  (plist-get entry :filename) status))
    destination))

(defun hey-files--safe-name (name)
  "NAME with anything that would let it escape its directory removed."
  (replace-regexp-in-string "[/\\]" "_" (or name "attachment")))

;; ─────────────────────────── the screen ─────────────────────────────
(defcustom hey-files-query "*"
  "Default query behind the Files screen.

\"*\" means every attachment you have, which is the HEY behaviour and the
reason the screen is worth having.  Narrow it with `/' once you are
there, or with a prefix argument when opening it."
  :type 'string
  :group 'hey-notmuch)

(defvar-local hey-files--query nil "Query this Files buffer is showing.")
(defvar-local hey-files--count 0
  "How many rows the last render produced.
Kept here because `tabulated-list-entries' holds the generator FUNCTION,
not the list, so there is nothing to take the length of afterwards.")

(defun hey-files--human-size (bytes)
  "BYTES as something you can read at a glance."
  (cond ((null bytes) "")
        ((< bytes 1024) (format "%dB" bytes))
        ((< bytes (* 1024 1024)) (format "%.0fK" (/ bytes 1024.0)))
        (t (format "%.1fM" (/ bytes (* 1024.0 1024.0))))))

(defun hey-files--entries ()
  "Tabulated-list entries for `hey-files--query'."
  (let ((entries
         (mapcar (lambda (a)
                   (list a
                         (vector (plist-get a :date)
                                 (hey-files--human-size (plist-get a :bytes))
                                 (plist-get a :filename)
                                 ;; The display name if there is one, the
                                 ;; address if there is not — `split-string'
                                 ;; on "<" leaves "Cloudflare " or, for a bare
                                 ;; address, the address itself.
                                 (string-trim (car (split-string (plist-get a :from) "<" t "[ \t\"]+")))
                                 (plist-get a :subject))))
                 (hey-files-attachments (or hey-files--query hey-files-query)))))
    (setq hey-files--count (length entries))
    entries))

(defvar hey-files-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hey-files-open)
    (define-key map (kbd "s")   #'hey-files-save)
    (define-key map (kbd "x")   #'hey-files-open-external)
    (define-key map (kbd "m")   #'hey-files-show-message)
    (define-key map (kbd "/")   #'hey-files-filter)
    map)
  "Keymap for the HEY Files screen.")

(define-derived-mode hey-files-mode tabulated-list-mode "HEY files"
  "Every attachment in the mailbox, newest first.
\\{hey-files-mode-map}"
  (setq tabulated-list-format
        [("Date" 14 t)
         ("Size" 6 (lambda (a b) (< (or (plist-get (car a) :bytes) 0)
                                    (or (plist-get (car b) :bytes) 0))))
         ("File" 36 t)
         ("From" 22 t)
         ("Subject" 0 t)]
        ;; Nothing: the list arrives newest-first from `hey-files-attachments'
        ;; and re-sorting on a column is a click away.  Sorting by Date here
        ;; would sort the *rendered* relative dates ("Today", "Fri.") as
        ;; strings, which is not chronological in any calendar.
        tabulated-list-sort-key nil
        tabulated-list-entries #'hey-files--entries)
  (tabulated-list-init-header))

;;;###autoload
(defun hey-files (&optional query)
  "Browse every attachment in the mailbox.  With a prefix arg, ask for a QUERY."
  (interactive (list (when current-prefix-arg
                       (read-string "Files matching query: " hey-files-query))))
  (let ((buffer (get-buffer-create "*HEY files*")))
    (with-current-buffer buffer
      (hey-files-mode)
      (setq hey-files--query (or query hey-files-query))
      (setq mode-line-process (format " %s" hey-files--query))
      (tabulated-list-print))
    (pop-to-buffer buffer)
    (message "%d attachment%s" hey-files--count (if (= 1 hey-files--count) "" "s"))))

(defun hey-files--entry ()
  "The attachment on this line."
  (or (tabulated-list-get-id) (user-error "No file on this line")))

(defun hey-files-open ()
  "Open this attachment in Emacs."
  (interactive)
  (let* ((entry (hey-files--entry))
         (dir (expand-file-name "hey-mail-parts" temporary-file-directory))
         (path (progn (make-directory dir t)
                      (expand-file-name (hey-files--safe-name (plist-get entry :filename)) dir))))
    (hey-files--extract entry path)
    ;; Read-only: this is a copy of a part of a message, and editing it would
    ;; save changes into a temp file nobody will ever look at again.
    (find-file-read-only path)))

(defun hey-files-open-external ()
  "Hand this attachment to the desktop (xdg-open)."
  (interactive)
  (let* ((entry (hey-files--entry))
         (opener (executable-find "xdg-open")))
    (unless opener (user-error "No xdg-open on PATH"))
    (let* ((dir (expand-file-name "hey-mail-parts" temporary-file-directory))
           (path (progn (make-directory dir t)
                        (expand-file-name (hey-files--safe-name (plist-get entry :filename)) dir))))
      (hey-files--extract entry path)
      (call-process opener nil 0 nil path)
      (message "Opened %s" (plist-get entry :filename)))))

(defun hey-files-save (destination)
  "Save this attachment to DESTINATION."
  (interactive
   (let ((entry (hey-files--entry)))
     (list (read-file-name "Save attachment to: " nil nil nil
                           (hey-files--safe-name (plist-get entry :filename))))))
  (let ((entry (hey-files--entry)))
    (when (and (file-exists-p destination)
               (not (yes-or-no-p (format "%s exists — overwrite? " destination))))
      (user-error "Not saved"))
    (hey-files--extract entry destination)
    (message "Saved %s" destination)))

(defun hey-files-show-message ()
  "Open the message this attachment arrived on."
  (interactive)
  (notmuch-show (concat "id:" (plist-get (hey-files--entry) :message-id))))

(defun hey-files-filter (query)
  "Narrow the Files screen to QUERY."
  (interactive (list (read-string "Files matching query: " hey-files--query)))
  (setq hey-files--query query
        mode-line-process (format " %s" query))
  (tabulated-list-print t)
  (message "%d attachment%s" hey-files--count (if (= 1 hey-files--count) "" "s")))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "D") #'hey-files))

(provide 'hey-files)
;;; hey-files.el ends here

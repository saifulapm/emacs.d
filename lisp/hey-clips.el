;;; hey-clips.el --- Keep the useful paragraph, not the whole mail  -*- lexical-binding: t; -*-

;; HEY's Clips: highlight a bit of a message, clip it, and it joins a library
;; you can search — with a way back to the message it came from.  The point is
;; that most mail is worth nothing and one paragraph of it is worth keeping:
;; the door code, the account number, the sentence where they agreed to the
;; price.  Archiving the whole thread to find that paragraph again is what
;; clipping replaces.
;;
;; Clips live in clips.org in `hey-notmuch-db-dir' — same shape as notes, same
;; reader (`hey-notes-entries'), same reason for being outside this public
;; repo: the contents are other people's words about your business.
;;
;; The way back is a Message-Id, stored as a property.  Not a thread id: mail
;; gets re-threaded when a stray reply arrives, and a clip should point at the
;; sentence's own message forever.

;;; Code:

(require 'hey-notmuch)
(require 'hey-notes)
(require 'tabulated-list)
(require 'subr-x)

(declare-function notmuch-show "notmuch-show")
(declare-function notmuch-show-get-from "notmuch-show")
(defvar notmuch-command)

(defcustom hey-clips-file
  (expand-file-name "clips.org" hey-notmuch-db-dir)
  "Org file holding the clip library."
  :type 'file
  :group 'hey-notmuch)

;; ──────────────────────────── clipping ──────────────────────────────
(defun hey-clips--title (text)
  "A one-line title for TEXT: enough of it to recognise in a list."
  (let ((line (string-trim (car (split-string (string-trim text) "\n" t)))))
    (if (> (length line) 60)
        (concat (substring line 0 57) "…")
      (or (and (not (string-empty-p line)) line) "clip"))))

;;;###autoload
(defun hey-clips-save (start end)
  "Clip the region from START to END into the library.

Meant for a show buffer, where the region is a paragraph of somebody's
mail; it works anywhere, and clipping from a draft you are writing is a
perfectly good way to keep a sentence you may want again."
  (interactive "r")
  (unless (use-region-p) (user-error "Select the text to clip first"))
  (let* ((text (buffer-substring-no-properties start end))
         (msgid (ignore-errors (hey-notmuch--message-id)))
         (from (or (ignore-errors
                     (pcase major-mode
                       ('notmuch-show-mode (notmuch-show-get-from))
                       (_ (hey-notmuch--from-address))))
                   ""))
         (subject (or (ignore-errors (hey-notmuch--subject)) ""))
         ;; The clip's own identity, so it can be deleted later without
         ;; guessing which of three clips off the same message you meant.
         (id (format "%s-%04x" (format-time-string "%Y%m%d%H%M%S") (random 65536))))
    (hey-notes-append-entry
     hey-clips-file
     (hey-clips--title text)
     (append (list (cons "HEY_CLIP" id))
             (when msgid (list (cons "HEY_MESSAGE" msgid)))
             (list (cons "HEY_FROM" from)
                   (cons "HEY_SUBJECT" subject)
                   (cons "HEY_SAVED" (format-time-string "[%Y-%m-%d %a %H:%M]"))))
     text)
    (deactivate-mark)
    (message "Clipped %d character%s" (length text) (if (= 1 (length text)) "" "s"))))

;; ───────────────────────── the library ──────────────────────────────
(defvar-local hey-clips--filter nil "Text the clip list is filtered by.")
(defvar-local hey-clips--count 0 "Rows the last render produced.")

(defun hey-clips--all ()
  "Every clip, newest first."
  (reverse (hey-notes-entries hey-clips-file)))

(defun hey-clips--matches (clip filter)
  "Non-nil if CLIP matches FILTER, which may be nil."
  (or (null filter)
      (string-empty-p filter)
      (let ((needle (regexp-quote filter)))
        (or (string-match-p needle (plist-get clip :body))
            (string-match-p needle (plist-get clip :title))
            (string-match-p needle (or (cdr (assoc "HEY_FROM" (plist-get clip :props))) ""))
            (string-match-p needle (or (cdr (assoc "HEY_SUBJECT" (plist-get clip :props))) ""))))))

(defun hey-clips--entries ()
  "Tabulated-list entries for the clip library."
  (let ((entries
         (mapcar
          (lambda (clip)
            (let ((props (plist-get clip :props)))
              (list clip
                    (vector (or (cdr (assoc "HEY_SAVED" props)) "")
                            (let ((from (or (cdr (assoc "HEY_FROM" props)) "")))
                              (string-trim (car (split-string from "<" t "[ \t\"]+"))))
                            (plist-get clip :title)))))
          (seq-filter (lambda (c) (hey-clips--matches c hey-clips--filter))
                      (hey-clips--all)))))
    (setq hey-clips--count (length entries))
    entries))

(defvar hey-clips-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hey-clips-show)
    (define-key map (kbd "w")   #'hey-clips-copy)
    (define-key map (kbd "m")   #'hey-clips-show-message)
    (define-key map (kbd "d")   #'hey-clips-delete)
    (define-key map (kbd "/")   #'hey-clips-filter)
    (define-key map (kbd "e")   #'hey-clips-edit-file)
    map)
  "Keymap for the clip library.")

(define-derived-mode hey-clips-mode tabulated-list-mode "HEY clips"
  "Everything you have clipped out of your mail.
\\{hey-clips-mode-map}"
  (setq tabulated-list-format [("Saved" 20 t) ("From" 22 t) ("Clip" 0 t)]
        tabulated-list-sort-key nil
        tabulated-list-entries #'hey-clips--entries)
  (tabulated-list-init-header))

;;;###autoload
(defun hey-clips (&optional filter)
  "Open the clip library.  With a prefix argument, FILTER it as you open."
  (interactive (list (when current-prefix-arg (read-string "Clips matching: "))))
  (let ((buffer (get-buffer-create "*HEY clips*")))
    (with-current-buffer buffer
      (hey-clips-mode)
      (setq hey-clips--filter filter)
      (tabulated-list-print))
    (pop-to-buffer buffer)
    (when (zerop hey-clips--count)
      (message "No clips yet — select text in a message and press `H x'"))))

(defun hey-clips--this ()
  "The clip on this line."
  (or (tabulated-list-get-id) (user-error "No clip on this line")))

(defun hey-clips-show ()
  "Show this clip in full."
  (interactive)
  (let* ((clip (hey-clips--this))
         (props (plist-get clip :props))
         (buffer (get-buffer-create "*HEY clip*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" (or (cdr (assoc "HEY_SUBJECT" props)) ""))
                            'face 'bold)
                (propertize (format "%s · %s\n\n"
                                    (or (cdr (assoc "HEY_FROM" props)) "")
                                    (or (cdr (assoc "HEY_SAVED" props)) ""))
                            'face 'shadow)
                (plist-get clip :body) "\n")
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)))

(defun hey-clips-copy ()
  "Put this clip on the kill ring."
  (interactive)
  (let ((text (plist-get (hey-clips--this) :body)))
    (kill-new text)
    (message "Copied %d character%s" (length text) (if (= 1 (length text)) "" "s"))))

(defun hey-clips-show-message ()
  "Open the message this clip came from."
  (interactive)
  (let ((msgid (cdr (assoc "HEY_MESSAGE" (plist-get (hey-clips--this) :props)))))
    (unless msgid (user-error "This clip did not come from a message"))
    ;; `notmuch-show' returns nil rather than signalling when nothing matches,
    ;; which is exactly what happens to a clip whose message you later
    ;; deleted — say so instead of leaving an empty window.
    (unless (notmuch-show (concat "id:" msgid))
      (user-error "That message is no longer in the database"))))

(defun hey-clips-delete ()
  "Delete this clip from the library."
  (interactive)
  (let* ((clip (hey-clips--this))
         (id (cdr (assoc "HEY_CLIP" (plist-get clip :props)))))
    (unless id (user-error "This clip has no id — edit clips.org by hand (`e')"))
    (when (yes-or-no-p (format "Delete clip \"%s\"? " (plist-get clip :title)))
      (hey-notes-delete-entry hey-clips-file "HEY_CLIP" id)
      (tabulated-list-print t)
      (message "Deleted"))))

(defun hey-clips-filter (filter)
  "Show only clips matching FILTER."
  (interactive (list (read-string "Clips matching: " hey-clips--filter)))
  (setq hey-clips--filter filter)
  (tabulated-list-print t)
  (message "%d clip%s" hey-clips--count (if (= 1 hey-clips--count) "" "s")))

(defun hey-clips-edit-file ()
  "Open clips.org itself."
  (interactive)
  (find-file hey-clips-file))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "x") #'hey-clips-save)
  (define-key hey-notmuch-map (kbd "X") #'hey-clips))

(provide 'hey-clips)
;;; hey-clips.el ends here

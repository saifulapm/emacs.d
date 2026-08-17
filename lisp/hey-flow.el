;;; hey-flow.el --- Power Through, Focus & Reply, Read Together  -*- lexical-binding: t; -*-

;; The three HEY screens that are about MOVING through mail rather than
;; storing it, plus the bundling that keeps a prolific sender from filling the
;; Imbox on their own.
;;
;;   Power Through New   one unread thread at a time, one key per decision,
;;                       automatic advance.  The Screener with the friction
;;                       taken out.
;;
;;   Focus & Reply       every thread you owe a reply to, in ONE buffer, each
;;                       already open for typing into.  HEY calls this a game
;;                       changer and they are right: the cost of replying to
;;                       nine mails is nine context switches, not nine
;;                       replies, and this deletes eight of them.
;;
;;   Read Together       several threads stitched into one scrollable buffer,
;;                       for the morning where four people mailed you about
;;                       the same thing.
;;
;;   Bundling            a sender collapsed to a single Imbox row.  The rule
;;                       lives on the contact page (hey-contact.el); the row
;;                       is drawn here, on the hello screen.

;;; Code:

(require 'hey-notmuch)
(require 'hey-contact)
(require 'subr-x)

(declare-function notmuch-show "notmuch-show")
(declare-function notmuch-tree "notmuch-tree")
(declare-function notmuch-search "notmuch")
(declare-function notmuch-tag "notmuch-tag")
(declare-function notmuch-show-archive-thread "notmuch-show")
(declare-function notmuch-show-reply "notmuch-show")
(declare-function notmuch-mua-new-reply "notmuch-mua")
(declare-function notmuch-mua-send-and-exit "notmuch-mua")
(declare-function notmuch-call-notmuch-sexp "notmuch-lib")
(declare-function message-goto-body "message")
(declare-function widget-insert "wid-edit")
(declare-function widget-create "wid-edit")
(defvar notmuch-command)
(defvar notmuch-search-query-string)
(defvar notmuch-tree-basic-query)

;; ═════════════════════════ Read Together ════════════════════════════
;; Nearly free: `notmuch show' accepts any query and renders every thread it
;; matches, so an OR of thread ids is already the feature.  Verified on this
;; mailbox — two thread ids in one query produced one buffer with both
;; threads' messages open.

;;;###autoload
(defun hey-flow-read-together ()
  "Open the selected threads in one buffer, to be read in one go.

Selection is the region if there is one, otherwise the thread at point —
so this is: mark a few lines in the Imbox, `H r'."
  (interactive)
  (let ((ids (hey-notmuch--region-thread-ids)))
    (unless ids (user-error "No threads selected"))
    (notmuch-show (mapconcat (lambda (tid) (format "thread:%s" tid)) ids " or ")
                  nil nil nil
                  (format "*HEY read together (%d)*" (length ids)))
    (message "%d thread%s, one buffer" (length ids) (if (= 1 (length ids)) "" "s"))))

;; ═════════════════════ Power Through New ════════════════════════════
;; One thread on screen, one key per decision, advance.  The state is global
;; rather than buffer-local because each step REPLACES the show buffer (that
;; is what `notmuch-show' does), and buffer-local state would die with it.
;; One power-through at a time is also all anyone can actually do.

(defvar hey-flow--power-threads nil "Thread ids left to power through.")
(defvar hey-flow--power-index 0 "Position within `hey-flow--power-threads'.")
(defvar hey-flow--power-query nil "Query this run came from.")
(defvar hey-flow--power-config nil "Window configuration to restore on quit.")

(defconst hey-flow-power-buffer "*HEY power through*"
  "Buffer name reused for every thread in a power-through run.")

(defun hey-flow--power-act (fn)
  "Run FN on the current thread, then advance.
Wrapped so every action key is one line and they all behave the same."
  (lambda ()
    (interactive)
    (funcall fn)
    (hey-flow-power-next)))

(defvar hey-power-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Same letters as under `H', deliberately: the actions are the actions,
    ;; and power-through only removes the prefix.  `b' is back rather than `p'
    ;; because `p' is Paper Trail here, exactly as it is under `H'.
    (define-key map (kbd "i") (hey-flow--power-act #'hey-notmuch-screen-in))
    (define-key map (kbd "f") (hey-flow--power-act #'hey-notmuch-move-to-feed))
    (define-key map (kbd "p") (hey-flow--power-act #'hey-notmuch-move-to-papertrail))
    (define-key map (kbd "o") (hey-flow--power-act #'hey-notmuch-screen-out))
    (define-key map (kbd "u") (hey-flow--power-act #'hey-notmuch-unscreen))
    (define-key map (kbd "l") (hey-flow--power-act #'hey-notmuch-reply-later))
    (define-key map (kbd "a") (hey-flow--power-act #'hey-notmuch-set-aside))
    (define-key map (kbd "z") (hey-flow--power-act #'hey-notmuch-bubble-up))
    (define-key map (kbd "e") (hey-flow--power-act #'notmuch-show-archive-thread))
    (define-key map (kbd "r") #'notmuch-show-reply)
    (define-key map (kbd "n") #'hey-flow-power-next)
    (define-key map (kbd "SPC") #'hey-flow-power-next)
    (define-key map (kbd "b") #'hey-flow-power-previous)
    (define-key map (kbd "DEL") #'hey-flow-power-previous)
    (define-key map (kbd "q") #'hey-flow-power-quit)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap active while powering through new mail.")

(define-minor-mode hey-power-mode
  "Burn through unread mail one thread at a time.

Every key is one decision and every decision advances, so a Screener with
two hundred senders in it is two hundred keystrokes rather than two
hundred keystrokes plus two hundred navigations.

\\{hey-power-mode-map}"
  :lighter " Power"
  :keymap hey-power-mode-map)

(defun hey-flow--power-header ()
  "Header line for the power-through buffer: where you are, and what the keys do."
  (concat
   (propertize (format " %d/%d  "
                       (1+ hey-flow--power-index) (length hey-flow--power-threads))
               'face 'mode-line-emphasis)
   (propertize "i imbox · f feed · p paper · o out · u undo │ l later · a aside · z bubble · e archive │ r reply · n next · b back · q quit"
               'face 'shadow)))

(defun hey-flow--power-show ()
  "Draw the thread at `hey-flow--power-index'."
  (let ((tid (nth hey-flow--power-index hey-flow--power-threads)))
    (when-let* ((old (get-buffer hey-flow-power-buffer)))
      (kill-buffer old))
    (if (null tid)
        (hey-flow-power-quit)
      (let ((buffer (notmuch-show (concat "thread:" tid) nil nil nil hey-flow-power-buffer)))
        (if (null buffer)
            ;; The thread matched when the run started and does not now —
            ;; screened out from another window, deleted, retagged.  Skip it
            ;; rather than stopping: a run that dies on a stale id is a run
            ;; you cannot trust to finish.
            (progn (setq hey-flow--power-index (1+ hey-flow--power-index))
                   (hey-flow--power-show))
          (with-current-buffer buffer
            (hey-power-mode 1)
            (setq header-line-format (hey-flow--power-header))))))))

;;;###autoload
(defun hey-flow-power-through (query)
  "Power through every thread matching QUERY, one key per decision.

Called from a notmuch list, QUERY defaults to that list's own query, so
`H P' in the Screener powers through the Screener.  Everywhere else it
defaults to the Screener itself, which is the pile this is for."
  (interactive
   (list (let ((default (pcase major-mode
                          ('notmuch-search-mode notmuch-search-query-string)
                          ('notmuch-tree-mode notmuch-tree-basic-query)
                          (_ "tag:inbox and tag:unread and not tag:screened"))))
           (if current-prefix-arg
               (read-string "Power through: " default)
             default))))
  (let ((ids (mapcar (lambda (s) (string-remove-prefix "thread:" s))
                     (or (ignore-errors
                           (process-lines notmuch-command "search" "--output=threads"
                                          "--sort=oldest-first" query))
                         nil))))
    (unless ids (user-error "Nothing matches %s" query))
    (setq hey-flow--power-threads ids
          hey-flow--power-index 0
          hey-flow--power-query query
          ;; Snapshot BEFORE the first thread is shown, so quitting puts you
          ;; back where you pressed the key rather than in whatever window
          ;; layout the last thread happened to produce.
          hey-flow--power-config (current-window-configuration))
    (hey-flow--power-show)
    (message "Powering through %d thread%s" (length ids) (if (= 1 (length ids)) "" "s"))))

(defun hey-flow-power-next ()
  "Next thread in the power-through run."
  (interactive)
  (if (>= (1+ hey-flow--power-index) (length hey-flow--power-threads))
      (progn (message "That was the last one") (hey-flow-power-quit))
    (setq hey-flow--power-index (1+ hey-flow--power-index))
    (hey-flow--power-show)))

(defun hey-flow-power-previous ()
  "Previous thread in the power-through run."
  (interactive)
  (if (<= hey-flow--power-index 0)
      (message "Already at the first one")
    (setq hey-flow--power-index (1- hey-flow--power-index))
    (hey-flow--power-show)))

(defun hey-flow-power-quit ()
  "Stop powering through and go back where you started."
  (interactive)
  (let ((done (1+ hey-flow--power-index))
        (total (length hey-flow--power-threads)))
    (when-let* ((buffer (get-buffer hey-flow-power-buffer)))
      (kill-buffer buffer))
    (when hey-flow--power-config
      (set-window-configuration hey-flow--power-config))
    (setq hey-flow--power-threads nil
          hey-flow--power-index 0
          hey-flow--power-config nil)
    (message "Powered through %d of %d" (min done total) total)))

;; ═══════════════════════ Focus & Reply ══════════════════════════════
;; Every Reply Later thread in one buffer, each with its own reply box.  The
;; quoted mail is read-only text; the boxes are not.  `C-c C-c' in a box turns
;; it into a real reply through notmuch's own compose path (so Fcc, the
;; identity, In-Reply-To and References all come from the same place as any
;; other reply) and sends it.

(defcustom hey-flow-focus-query "tag:replylater"
  "Which threads Focus & Reply gathers."
  :type 'string
  :group 'hey-notmuch)

(defcustom hey-flow-focus-quote-lines 25
  "How many lines of each message to show before cutting it off.

Enough to remember what was asked, short enough that nine of them still
scroll like one screen.  `C-c C-o' opens the real thread when the rest
matters."
  :type 'integer
  :group 'hey-notmuch)

(defface hey-flow-focus-rule
  '((t :inherit font-lock-comment-face))
  "Face for the rules separating one thread from the next."
  :group 'hey-notmuch)

(defface hey-flow-focus-header
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the From/Subject line of a thread in Focus & Reply."
  :group 'hey-notmuch)

(defface hey-flow-focus-quote
  '((t :inherit font-lock-string-face))
  "Face for the quoted message text in Focus & Reply."
  :group 'hey-notmuch)

(defun hey-flow--last-message (tid)
  "Plist of the newest message in thread TID, with its text body."
  (let* ((id (car (ignore-errors
                    (process-lines notmuch-command "search" "--output=messages"
                                   "--sort=newest-first" "--limit=1"
                                   (concat "thread:" tid)))))
         (forest (and id (ignore-errors
                           (notmuch-call-notmuch-sexp
                            "show" "--format=sexp" "--format-version=5"
                            "--body=true" "--entire-thread=false" id)))))
    (car (hey-files--forest-messages forest))))

(defun hey-flow--plain-text (msg)
  "Readable text of MSG, or a note saying why there is none."
  (let* ((parts (mapcan #'hey-files--parts (copy-sequence (plist-get msg :body))))
         (plain (seq-find (lambda (p)
                            (and (equal (plist-get p :content-type) "text/plain")
                                 (stringp (plist-get p :content))))
                          parts)))
    (cond
     (plain (plist-get plain :content))
     ;; HTML-only mail is normally a newsletter, and a newsletter is not
     ;; something you owe a reply to — so rather than dragging shr in to
     ;; render it here, say so and let `C-c C-o' open the real thread, where
     ;; notmuch already renders HTML with images blocked.
     ((seq-find (lambda (p) (equal (plist-get p :content-type) "text/html")) parts)
      "[HTML message — C-c C-o opens the thread]")
     (t "[no text part]"))))

(defun hey-flow--trim (text lines)
  "First LINES lines of TEXT, with a note if anything was cut."
  (let* ((all (split-string (string-trim-right text) "\n"))
         (kept (seq-take all lines)))
    (concat (string-join kept "\n")
            (when (> (length all) lines)
              (format "\n… %d more line%s" (- (length all) lines)
                      (if (= 1 (- (length all) lines)) "" "s"))))))

(defvar hey-flow-focus-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'hey-flow-focus-send)
    (define-key map (kbd "C-c C-d") #'hey-flow-focus-done)
    (define-key map (kbd "C-c C-o") #'hey-flow-focus-open)
    (define-key map (kbd "C-c C-n") #'hey-flow-focus-next)
    (define-key map (kbd "C-c C-p") #'hey-flow-focus-previous)
    (define-key map (kbd "C-c C-k") #'hey-flow-focus-quit)
    map)
  "Keymap for the Focus & Reply buffer.")

(define-minor-mode hey-flow-focus-mode
  "Reply to everything you owe, without leaving the buffer.
\\{hey-flow-focus-mode-map}"
  :lighter " Focus"
  :keymap hey-flow-focus-mode-map)

(defun hey-flow--focus-fixed (start end)
  "Make START..END part of the page rather than part of the reply.

`read-only' as a text property, not a buffer flag, because the reply
boxes in between must stay editable.  `rear-nonsticky' matters as much as
the property itself: `self-insert-command' inserts WITH inheritance, so
without it the first character you typed at the top of a box would
inherit read-only from the rule above and the box would seize up.

What this buys is that the quoted mail cannot be edited or deleted —
verified: `delete-char' inside it signals `text-read-only'.  Text can
still be inserted at the very top of the buffer, before any protected
character; that text belongs to no box, is never sent, and is not worth
the extra machinery to forbid."
  (add-text-properties start end
                       '(read-only t front-sticky nil rear-nonsticky (read-only))))

(defun hey-flow--focus-insert (tid)
  "Insert the block for thread TID: the mail, then a box to answer it in."
  (let* ((msg (hey-flow--last-message tid))
         (headers (plist-get msg :headers))
         (from (or (plist-get headers :From) "?"))
         (subject (or (plist-get headers :Subject) "(no subject)"))
         (date (or (plist-get msg :date_relative) ""))
         (start (point)))
    (insert (propertize (concat (make-string 78 ?═) "\n") 'face 'hey-flow-focus-rule))
    (insert (propertize (format "%s\n" subject) 'face 'hey-flow-focus-header))
    (insert (propertize (format "%s · %s\n" from date) 'face 'shadow))
    (insert (propertize (concat (make-string 78 ?─) "\n") 'face 'hey-flow-focus-rule))
    (insert (propertize (concat (hey-flow--trim (hey-flow--plain-text msg)
                                                hey-flow-focus-quote-lines)
                                "\n")
                        'face 'hey-flow-focus-quote))
    (insert (propertize "──── your reply ──────────────────────────────────────────────────────────\n"
                        'face 'hey-flow-focus-rule))
    (hey-flow--focus-fixed start (point))
    ;; The box itself: one blank line, owned by the thread through a text
    ;; property so `C-c C-c' can find which reply it is in no matter how much
    ;; you have typed or deleted.
    (let ((box-start (point)))
      (insert "\n\n")
      ;; front-sticky lists ALL THREE properties: `self-insert-command'
      ;; inserts with inheritance, and text typed at the very top of an empty
      ;; box takes its properties from the character after it.  Leave
      ;; hey-focus-subject out and the first thing you type lands in a box
      ;; that knows its thread but not what it is called, so `C-c C-c'
      ;; reports "Replied: nil".
      (add-text-properties box-start (point)
                           (list 'hey-focus-thread tid
                                 'hey-focus-message (plist-get msg :id)
                                 'hey-focus-subject subject
                                 'rear-nonsticky nil
                                 'front-sticky '(hey-focus-thread
                                                 hey-focus-message
                                                 hey-focus-subject))))))

;;;###autoload
(defun hey-flow-focus-reply ()
  "Open every Reply Later thread in one buffer, each ready to answer."
  (interactive)
  (let ((ids (mapcar (lambda (s) (string-remove-prefix "thread:" s))
                     (or (ignore-errors
                           (process-lines notmuch-command "search" "--output=threads"
                                          "--sort=oldest-first" hey-flow-focus-query))
                         nil))))
    (unless ids (user-error "Nothing in Reply Later — nothing to focus on"))
    (let ((buffer (get-buffer-create "*HEY focus & reply*"))
          (config (current-window-configuration)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (text-mode)
          (hey-flow-focus-mode 1)
          (setq-local hey-flow--focus-return config)
          (dolist (tid ids)
            (hey-flow--focus-insert tid))
          (setq header-line-format
                (substitute-command-keys
                 (format " %d to answer — \\[hey-flow-focus-send] send · \\[hey-flow-focus-done] done without replying · \\[hey-flow-focus-open] open thread · \\[hey-flow-focus-next]/\\[hey-flow-focus-previous] move · \\[hey-flow-focus-quit] quit"
                         (length ids))))
          (goto-char (point-min))
          (hey-flow-focus-next)))
      (pop-to-buffer buffer))))

(defvar-local hey-flow--focus-return nil
  "Window configuration to restore when Focus & Reply is done.")

(defun hey-flow--focus-block ()
  "The reply box point is in, as (THREAD MESSAGE-ID SUBJECT START END)."
  (let ((tid (or (get-text-property (point) 'hey-focus-thread)
                 (and (> (point) (point-min))
                      (get-text-property (1- (point)) 'hey-focus-thread)))))
    (unless tid (user-error "Point is not in a reply box"))
    (let* ((pos (if (get-text-property (point) 'hey-focus-thread) (point) (1- (point))))
           (start (or (previous-single-property-change (1+ pos) 'hey-focus-thread)
                      (point-min)))
           (end (or (next-single-property-change pos 'hey-focus-thread)
                    (point-max))))
      (list tid
            (get-text-property pos 'hey-focus-message)
            (get-text-property pos 'hey-focus-subject)
            start end))))

(defun hey-flow-focus-next ()
  "Move to the next reply box."
  (interactive)
  (let ((pos (next-single-property-change (point) 'hey-focus-thread)))
    ;; Two boundaries per box (in and out), so a box you are already inside
    ;; needs one more hop to reach the NEXT one.
    (when (and pos (not (get-text-property pos 'hey-focus-thread)))
      (setq pos (next-single-property-change pos 'hey-focus-thread)))
    (if pos
        (goto-char pos)
      (goto-char (point-max))
      (message "No more replies below"))))

(defun hey-flow-focus-previous ()
  "Move to the previous reply box."
  (interactive)
  (let ((pos (previous-single-property-change (point) 'hey-focus-thread)))
    (when (and pos (not (get-text-property (max (point-min) (1- pos)) 'hey-focus-thread)))
      (setq pos (previous-single-property-change pos 'hey-focus-thread)))
    (if pos
        (goto-char (max (point-min) (1- pos)))
      (goto-char (point-min))
      (message "No replies above"))))

(defun hey-flow--focus-remove-block (start end)
  "Take the answered block from START to END out of the buffer."
  (let ((inhibit-read-only t))
    ;; Back up over the block's own quoted mail, which starts at the previous
    ;; ═ rule — the box knows its own extent, but the reader wants the whole
    ;; entry gone, not a headless reply box.
    (save-excursion
      (goto-char start)
      (let ((block-start (if (re-search-backward "^═+$" nil t)
                             (match-beginning 0)
                           (point-min))))
        (delete-region block-start (min (point-max) end))))))

(defun hey-flow-focus-send (&optional reply-all)
  "Send the reply point is in.  With a prefix argument, REPLY-ALL.

The text is handed to notmuch's own reply composer rather than assembled
here, so the headers, the identity, the Fcc into Sent and the quoting
convention are all the ones every other reply in this client uses."
  (interactive "P")
  (pcase-let ((`(,tid ,msgid ,subject ,start ,end) (hey-flow--focus-block)))
    (let ((text (string-trim (buffer-substring-no-properties start end)))
          (focus (current-buffer)))
      (when (string-empty-p text)
        (user-error "Nothing typed — `C-c C-d' files it away without replying"))
      (save-window-excursion
        (notmuch-mua-new-reply (concat "id:" msgid) nil reply-all)
        (message-goto-body)
        (insert text "\n\n")
        (notmuch-mua-send-and-exit))
      ;; Only once the send has actually returned: a reply that failed to go
      ;; out must leave the thread in Reply Later, or it is lost.
      (notmuch-tag (concat "thread:" tid) '("-replylater"))
      (with-current-buffer focus
        (hey-flow--focus-remove-block start end)
        (when (= (point-min) (point-max))
          (hey-flow-focus-quit)))
      (message "Replied: %s" subject))))

(defun hey-flow-focus-done ()
  "File this thread away without replying — out of Reply Later, out of the buffer."
  (interactive)
  (pcase-let ((`(,tid ,_msgid ,subject ,start ,end) (hey-flow--focus-block)))
    (notmuch-tag (concat "thread:" tid) '("-replylater"))
    (hey-flow--focus-remove-block start end)
    (when (= (point-min) (point-max))
      (hey-flow-focus-quit))
    (message "Cleared from Reply Later: %s" subject)))

(defun hey-flow-focus-open ()
  "Open the full thread this reply box belongs to."
  (interactive)
  (pcase-let ((`(,tid ,_msgid ,_subject ,_start ,_end) (hey-flow--focus-block)))
    (notmuch-show (concat "thread:" tid))))

(defun hey-flow-focus-quit ()
  "Leave Focus & Reply.  Anything unsent stays in Reply Later."
  (interactive)
  (let ((config hey-flow--focus-return))
    (quit-window t)
    (when config (set-window-configuration config))))

;; ═══════════════════════════ Bundling ═══════════════════════════════
;; A bundled sender's threads are excluded from the Imbox query (see
;; `notmuch-saved-searches') and shown here instead: one line per sender, with
;; the count.  That is what "collapse to one row" means — the mail is not
;; archived, not marked read, not hidden; it is just not allowed to be twenty
;; rows.

(defun hey-flow-insert-bundles ()
  "Draw the Bundles section on the notmuch hello screen."
  (let ((addresses (hey-notmuch--db-lines hey-contact-bundle-db)))
    (when addresses
      (let* ((queries (mapcar (lambda (a)
                                (format "from:%s and tag:inbox and tag:unread" a))
                              addresses))
             (counts (hey-notmuch--count-batch queries)))
        (widget-insert "\nBundles\n")
        (seq-mapn
         (lambda (addr count)
           (widget-insert (format "%8d  " count))
           (widget-create 'link
                          :notify (lambda (widget &rest _)
                                    (notmuch-tree (widget-get widget :hey-query)))
                          :hey-query (format "from:%s and tag:inbox" addr)
                          :button-prefix "" :button-suffix ""
                          addr)
           (widget-insert "\n"))
         addresses counts)))))

(add-hook 'hey-notmuch-hello-section-functions #'hey-flow-insert-bundles)

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "r") #'hey-flow-read-together)
  (define-key hey-notmuch-map (kbd "P") #'hey-flow-power-through)
  (define-key hey-notmuch-map (kbd "F") #'hey-flow-focus-reply))

(provide 'hey-flow)
;;; hey-flow.el ends here

;;; hey-notmuch.el --- HEY.com-style email with notmuch  -*- lexical-binding: t; -*-

;; Phase 1 of a HEY-style workflow on top of notmuch + mbsync + msmtp.
;; Backend lives outside Emacs: ~/.mbsyncrc (sync), ~/.notmuch-config (index),
;; ~/.msmtprc (send), and ~/Mail/.notmuch/hooks/{pre,post}-new (the tagging
;; engine + the screened/thefeed/ledger/spam sender databases).
;;
;; The HEY idea: every sender is screened ONCE, and that decision routes all
;; their future mail into a box. Here a "box" is just a notmuch tag, and the
;; screening keys below both retag existing mail AND append the sender to the
;; matching .db file so the post-new hook keeps routing them automatically.

;;; Code:

(defvar hey-notmuch-hooks-dir (expand-file-name "~/Mail/.notmuch/hooks")
  "Directory holding the HEY sender .db files (read by the post-new hook).")

;; ─────────────────────────── notmuch core ───────────────────────────
(use-package notmuch
  :ensure t
  :commands (notmuch notmuch-search notmuch-tree notmuch-mua-new-mail)
  :bind (("C-c m" . notmuch)
         ("C-x m" . notmuch-mua-new-mail))
  :custom
  ;; HEY boxes as saved searches. `J' (bound below) jumps to one by its key.
  (notmuch-saved-searches
   '((:name "Imbox"      :query "tag:inbox and tag:screened and tag:unread"     :key "i" :search-type tree)
     (:name "Screener"   :query "tag:inbox and tag:unread and not tag:screened" :key "s" :search-type tree)
     (:name "The Feed"   :query "tag:thefeed and tag:unread"                    :key "f" :search-type tree)
     (:name "Paper Trail":query "tag:/ledger/"                                  :key "p")
     (:name "Seen"       :query "tag:screened and not tag:unread"               :key "I")
     (:name "All Inbox"  :query "tag:inbox"                                     :key "x")
     (:name "Sent"       :query "tag:sent"                                      :key "t")))
  ;; Always show every HEY box, even empty ones (fixed HEY-style layout).
  (notmuch-show-empty-saved-searches t)
  ;; Minimal hello screen: just the HEY boxes, nothing else. No search box
  ;; needed — `s' runs notmuch-search from any notmuch buffer, `z' searches in
  ;; tree view, `j'/`J' jump to a box.
  (notmuch-hello-sections '(notmuch-hello-insert-saved-searches))
  (notmuch-hello-thousands-separator "")   ; 1465, not "1 465"
  (notmuch-show-logo nil)
  (notmuch-search-oldest-first nil)
  (notmuch-archive-tags '("-inbox" "+archived"))
  ;; File sent mail into each account's Sent maildir (mbsync pushes it up).
  (notmuch-fcc-dirs
   '(("saiful.apm@gmail.com"    . "gmail/[Gmail]/Sent Mail")
     ("saiful.apm@icloud.com" . "icloud/Sent Messages")))
  ;; Privacy: block ALL remote images so tracking pixels never load.
  (notmuch-show-text/html-blocked-images ".")
  (mm-text-html-renderer 'shr)
  :hook ((notmuch-message-mode . turn-off-auto-fill)
         (notmuch-message-mode . flyspell-mode))
  :config
  ;; `J' = jump to a HEY box from anywhere in notmuch (HEY's "jump").
  (define-key notmuch-search-mode-map (kbd "J") #'notmuch-jump-search)
  (define-key notmuch-tree-mode-map   (kbd "J") #'notmuch-jump-search)
  (define-key notmuch-hello-mode-map  (kbd "J") #'notmuch-jump-search))

;; ───────────────────────────── sending ──────────────────────────────
(with-eval-after-load 'message
  (setq message-send-mail-function 'message-send-mail-with-sendmail
        sendmail-program (executable-find "msmtp")
        message-sendmail-envelope-from 'header
        message-sendmail-f-is-evil nil
        message-kill-buffer-on-exit t
        user-full-name "Saiful Islam"
        user-mail-address "saiful.apm@gmail.com")
  ;; Pick the msmtp account (-a gmail|icloud) from the From: header.
  (defun hey-notmuch--choose-msmtp-account ()
    (when (message-mail-p)
      (let ((from (or (message-fetch-field "from") "")))
        (setq-local message-sendmail-extra-arguments
                    (list "-a" (if (string-match-p "icloud\\.com" from) "icloud" "gmail"))))))
  (add-hook 'message-send-mail-hook #'hey-notmuch--choose-msmtp-account))

;; ──────────────────── HEY screening / routing ───────────────────────
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

(defun hey-notmuch--tag-by-from (tag-changes &optional addr)
  "Apply TAG-CHANGES to all mail from ADDR (or the sender at point). Return ADDR."
  (let ((addr (or addr (hey-notmuch--from-address))))
    (unless addr (user-error "No sender address at point"))
    (notmuch-tag (format "from:%s" addr) tag-changes)
    addr))

(defun hey-notmuch--add-to-db (line db)
  "Append LINE to DB file in `hey-notmuch-hooks-dir'."
  (append-to-file (concat line "\n") nil (expand-file-name db hey-notmuch-hooks-dir)))

(defun hey-notmuch--advance ()
  "Move to the next message/thread after acting."
  (pcase major-mode
    ('notmuch-tree-mode   (notmuch-tree-next-matching-message))
    ('notmuch-search-mode (notmuch-search-next-thread))))

(defun hey-notmuch-screen-in ()
  "Screen the sender IN: their mail belongs in the Imbox from now on."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from '("+screened"))))
    (hey-notmuch--add-to-db addr "screened.db")
    (message "Screened in → Imbox: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-move-to-feed ()
  "Route the sender to The Feed (newsletters / low-priority reading)."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from '("+thefeed" "+archived" "-inbox"))))
    (hey-notmuch--add-to-db addr "thefeed.db")
    (message "→ The Feed: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-move-to-papertrail (category)
  "Route the sender to The Paper Trail under CATEGORY (e.g. amazon, uber)."
  (interactive "sPaper Trail category: ")
  (let ((addr (hey-notmuch--tag-by-from
               (list (format "+ledger/%s" category) "+archived" "-inbox" "-unread"))))
    (hey-notmuch--add-to-db (format "%s %s" category addr) "ledger.db")
    (message "→ Paper Trail/%s: %s" category addr))
  (hey-notmuch--advance))

(defun hey-notmuch-screen-out ()
  "Screen the sender OUT: trash everything from them, now and forever."
  (interactive)
  (let ((addr (hey-notmuch--tag-by-from
               '("+spam" "+deleted" "+archived" "-inbox" "-unread" "-screened"))))
    (hey-notmuch--add-to-db addr "spam.db")
    (message "Screened out: %s" addr))
  (hey-notmuch--advance))

(defun hey-notmuch-filter-by-from ()
  "Narrow the current view to just the sender at point."
  (interactive)
  (let ((addr (hey-notmuch--from-address)))
    (pcase major-mode
      ('notmuch-search-mode (notmuch-search-filter (format "from:%s" addr)))
      (_ (notmuch-search (format "from:%s" addr))))))

;; HEY routing lives under the `H' prefix in search/tree lists, so it never
;; clobbers notmuch's own keys:  H i / H f / H p / H o  +  H l (filter sender).
(with-eval-after-load 'notmuch
  (dolist (map (list notmuch-search-mode-map notmuch-tree-mode-map))
    (define-key map (kbd "H i") #'hey-notmuch-screen-in)
    (define-key map (kbd "H f") #'hey-notmuch-move-to-feed)
    (define-key map (kbd "H p") #'hey-notmuch-move-to-papertrail)
    (define-key map (kbd "H o") #'hey-notmuch-screen-out)
    (define-key map (kbd "H l") #'hey-notmuch-filter-by-from)))

(provide 'hey-notmuch)
;;; hey-notmuch.el ends here

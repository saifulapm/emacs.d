;;; hey-labels.el --- Labels, Collections and Workflows  -*- lexical-binding: t; -*-

;; Three ways HEY lets you group threads, and they are genuinely different
;; ideas even though all three are notmuch tags underneath:
;;
;;   label/<x>            a word you stuck on a thread.  Many per thread.
;;   collection/<x>       a named pile you are building — "japan-trip",
;;                        "flat-purchase".  Also many per thread, but the
;;                        name is a THING rather than an adjective, so it is
;;                        worth its own namespace and its own browser.
;;   wf/<name>/<stage>    a thread somewhere in a named process.  Exactly ONE
;;                        stage per workflow per thread — that is the whole
;;                        point, and the reason moving a thread on has to
;;                        clear the stage it came from rather than just add
;;                        the one it went to.
;;
;; The namespaces are what make this work as tags: `tag:/^label\//' is a
;; browsable set, `tag:wf/hiring/interview' is a board column, and none of
;; them can collide with `inbox' or `screened' or a future HEY box.
;;
;; The autofile rule in hey-notmuch.el (`H A') writes label/<x> too, and the
;; post-new hook applies it to mail that has not arrived yet — so a label is
;; never only a thing you did by hand.

;;; Code:

(require 'hey-notmuch)
(require 'subr-x)

(declare-function notmuch-tag "notmuch-tag")
(declare-function notmuch-search "notmuch")
(declare-function notmuch-tree "notmuch-tree")
(declare-function notmuch-tag-completions "notmuch-tag")
(declare-function notmuch-show "notmuch-show")
(defvar notmuch-command)

;; ────────────────────── picking a name, with counts ──────────────────
(defun hey-labels--annotated (prefix names)
  "Alist of NAME → \"n threads\" for NAMES in the PREFIX namespace.
One batched count for the whole list; see `hey-notmuch--count-batch'."
  (let ((counts (hey-notmuch--count-batch
                 (mapcar (lambda (n) (format "tag:%s%s" prefix n)) names)
                 'threads)))
    (seq-mapn (lambda (n c) (cons n c)) names counts)))

(defun hey-labels--read (prompt prefix &optional require-match)
  "Read a bare name in the PREFIX namespace, showing how full each one is.

With REQUIRE-MATCH the answer must be one that already exists — right for
browsing (offering to visit an empty label is offering nothing) and wrong
for applying, where the whole point is that the first use creates it."
  (let* ((names (hey-notmuch--tags-in-namespace prefix))
         (annotations (hey-labels--annotated prefix names))
         (completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (let ((n (cdr (assoc name annotations))))
                    (when n (format "   %d thread%s" n (if (= n 1) "" "s"))))))))
    (when (and require-match (null names))
      (user-error "Nothing tagged %s yet" prefix))
    (completing-read prompt names nil require-match)))

;; ─────────────────────────── applying ───────────────────────────────
(defun hey-labels--apply (prefix name remove)
  "Add — or with REMOVE non-nil, take away — PREFIX/NAME on the selected threads.

\"Selected\" is the region if there is one, otherwise the thread at point,
so labelling ten threads is select-then-one-key rather than ten keys."
  (let ((ids (hey-notmuch--region-thread-ids))
        (tag (format "%s%s%s" (if remove "-" "+") prefix name)))
    (unless ids (user-error "No thread at point"))
    ;; One notmuch call per thread rather than a single `thread:a or thread:b'
    ;; query: `notmuch tag' takes one query, and an OR chain of forty thread
    ;; ids is both slower to parse and harder to read in a log than forty
    ;; small queries.
    (dolist (tid ids)
      (notmuch-tag (concat "thread:" tid) (list tag)))
    ;; No refresh here on purpose.  A label does not move a thread between
    ;; boxes, and `notmuch-refresh-all-buffers' rebuilds every open search
    ;; asynchronously — which empties the buffer under you for as long as the
    ;; query takes, so labelling three threads in a row would mean three
    ;; disappearing lists.  The tag change is in the database either way; the
    ;; view catches up on `=' or on the next delivery.
    (message "%s %s%s on %d thread%s"
             (if remove "Removed" "Applied") prefix name
             (length ids) (if (= 1 (length ids)) "" "s"))
    (length ids)))

(defun hey-labels--present (prefix)
  "Names in the PREFIX namespace actually present on the selected threads."
  (let* ((ids (hey-notmuch--region-thread-ids))
         (query (mapconcat (lambda (tid) (format "thread:%s" tid)) ids " or ")))
    (unless ids (user-error "No thread at point"))
    (hey-notmuch--tags-in-namespace prefix query)))

;;;###autoload
(defun hey-labels-add (name)
  "Label the selected thread(s) NAME."
  (interactive (list (hey-labels--read "Label: " "label/")))
  (hey-labels--apply "label/" (hey-notmuch--sanitize-name name "Label") nil))

;;;###autoload
(defun hey-labels-remove (name)
  "Take label NAME off the selected thread(s)."
  (interactive
   (list (completing-read "Remove label: " (hey-labels--present "label/") nil t)))
  (hey-labels--apply "label/" name t))

;;;###autoload
(defun hey-labels-browse (name)
  "Show everything labelled NAME."
  (interactive (list (hey-labels--read "Browse label: " "label/" t)))
  (notmuch-tree (format "tag:label/%s" name)))

;;;###autoload
(defun hey-collections-add (name)
  "Add the selected thread(s) to collection NAME, creating it on first use."
  (interactive (list (hey-labels--read "Collection: " "collection/")))
  (hey-labels--apply "collection/" (hey-notmuch--sanitize-name name "Collection") nil))

;;;###autoload
(defun hey-collections-remove (name)
  "Take the selected thread(s) out of collection NAME."
  (interactive
   (list (completing-read "Out of collection: " (hey-labels--present "collection/") nil t)))
  (hey-labels--apply "collection/" name t))

;;;###autoload
(defun hey-collections-browse (name)
  "Open collection NAME."
  (interactive (list (hey-labels--read "Open collection: " "collection/" t)))
  (notmuch-tree (format "tag:collection/%s" name)))

;; ──────────────────────────── workflows ─────────────────────────────
;; A workflow is a name and an ordered list of stages, remembered in
;; workflows.db as `<name> <stage>,<stage>,…'.  The ORDER is the reason the
;; file exists at all: the tags themselves are a set, and a board that showed
;; "done, doing, todo" because that is alphabetical would be useless.

(defconst hey-labels-workflow-db "workflows.db"
  "File in `hey-notmuch-db-dir' remembering each workflow's stage order.")

(defun hey-labels--workflows ()
  "Alist of workflow name → ordered list of stage names."
  (mapcar (lambda (line)
            (let* ((parts (split-string line "[ \t]+" t))
                   (name (car parts))
                   (stages (split-string (or (cadr parts) "") "," t "[ \t]+")))
              (cons name stages)))
          (hey-notmuch--db-lines hey-labels-workflow-db)))

(defun hey-labels--workflow-stages (name)
  "Ordered stages of workflow NAME, or nil."
  (cdr (assoc name (hey-labels--workflows))))

(defun hey-labels--workflow-remember (name stages)
  "Record that workflow NAME has STAGES, in that order."
  (hey-notmuch--db-put hey-labels-workflow-db name (string-join stages ",")))

(defun hey-labels--read-workflow (&optional require-match)
  "Read a workflow name, offering the ones already defined."
  (let ((names (or (mapcar #'car (hey-labels--workflows))
                   ;; A workflow can also exist purely as tags — restored from
                   ;; a `notmuch dump', or created on another machine before
                   ;; workflows.db came across — so the database has the final
                   ;; say on what exists.
                   nil)))
    (setq names (delete-dups
                 (append names
                         (mapcar (lambda (tag) (car (split-string tag "/")))
                                 (hey-notmuch--tags-in-namespace "wf/")))))
    (when (and require-match (null names))
      (user-error "No workflows yet — `H w' starts one"))
    (hey-notmuch--sanitize-name
     (completing-read "Workflow: " names nil require-match) "Workflow")))

;;;###autoload
(defun hey-labels-workflow-set (workflow stage)
  "Move the selected thread(s) to STAGE of WORKFLOW.

Moving means exactly that: every other stage of the same workflow comes
off the thread.  A thread that is in two stages at once is a board you
cannot read and a question — \"where is this?\" — you cannot answer."
  (interactive
   (let* ((workflow (hey-labels--read-workflow))
          (known (hey-labels--workflow-stages workflow))
          (stage (completing-read (format "Stage of %s: " workflow) known nil nil)))
     (list workflow stage)))
  (let* ((stage (hey-notmuch--sanitize-name stage "Stage"))
         (known (hey-labels--workflow-stages workflow))
         (prefix (format "wf/%s/" workflow))
         (ids (hey-notmuch--region-thread-ids)))
    (unless ids (user-error "No thread at point"))
    ;; A stage nobody has used yet joins the end of the order — the natural
    ;; place, since a stage invented while moving a thread onwards is almost
    ;; always the next one.
    (unless (member stage known)
      (hey-labels--workflow-remember workflow (append known (list stage))))
    (dolist (tid ids)
      (let* ((query (concat "thread:" tid))
             (current (hey-notmuch--tags-in-namespace prefix query))
             (changes (append (mapcar (lambda (s) (concat "-" prefix s))
                                      (remove stage current))
                              (list (concat "+" prefix stage)))))
        (notmuch-tag query changes)))
    (message "%s → %s (%d thread%s)" workflow stage
             (length ids) (if (= 1 (length ids)) "" "s"))))

;;;###autoload
(defun hey-labels-workflow-clear (workflow)
  "Take the selected thread(s) out of WORKFLOW entirely."
  (interactive (list (hey-labels--read-workflow t)))
  (let ((prefix (format "wf/%s/" workflow))
        (ids (hey-notmuch--region-thread-ids)))
    (unless ids (user-error "No thread at point"))
    (dolist (tid ids)
      (let* ((query (concat "thread:" tid))
             (current (hey-notmuch--tags-in-namespace prefix query)))
        (when current
          (notmuch-tag query (mapcar (lambda (s) (concat "-" prefix s)) current)))))
    (message "Out of %s: %d thread%s" workflow
             (length ids) (if (= 1 (length ids)) "" "s"))))

;; ─────────────────────────── the board ──────────────────────────────
;; Emacs has no columns worth the trouble, so the board is stages stacked
;; vertically — which is what a kanban board degenerates to on a laptop
;; screen anyway, and it keeps every thread's subject readable at full width
;; instead of clipped to a card.

(defvar-local hey-labels-board-workflow nil
  "Workflow this board is showing.")

(defface hey-labels-board-stage
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a stage heading on the workflow board."
  :group 'hey-notmuch)

(defface hey-labels-board-empty
  '((t :inherit shadow :slant italic))
  "Face for an empty stage on the workflow board."
  :group 'hey-notmuch)

(defvar hey-labels-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'hey-labels-board-open)
    (define-key map (kbd "m")   #'hey-labels-board-move)
    (define-key map (kbd "g")   #'hey-labels-board-refresh)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    map)
  "Keymap for the workflow board.")

(define-derived-mode hey-labels-board-mode special-mode "HEY board"
  "Stages of one workflow, and the threads sitting in each.
\\{hey-labels-board-mode-map}"
  (setq truncate-lines t))

(defun hey-labels--board-insert-stage (workflow stage)
  "Insert STAGE of WORKFLOW and the threads in it."
  (let* ((query (format "tag:wf/%s/%s" workflow stage))
         (threads (hey-notmuch--search query "--sort=newest-first")))
    (insert (propertize (format "── %s (%d) %s\n" stage (length threads)
                                (make-string (max 0 (- 60 (length stage))) ?─))
                        'face 'hey-labels-board-stage))
    (if (null threads)
        (insert (propertize "     nothing here\n" 'face 'hey-labels-board-empty))
      (dolist (thread threads)
        (insert
         (propertize
          (format "  %-12s  %-40s  %s\n"
                  (plist-get thread :date_relative)
                  (truncate-string-to-width (or (plist-get thread :subject) "") 40)
                  (truncate-string-to-width (or (plist-get thread :authors) "") 30))
          'hey-thread (plist-get thread :thread)
          'hey-subject (plist-get thread :subject)))))
    (insert "\n")))

(defun hey-labels--board-render ()
  "Draw the board for `hey-labels-board-workflow' in the current buffer."
  (let* ((workflow hey-labels-board-workflow)
         (inhibit-read-only t)
         (line (line-number-at-pos))
         ;; Stages the database knows about but workflows.db does not go at
         ;; the end rather than being dropped: a thread parked in a stage the
         ;; board refuses to draw is a thread you have lost.
         (stages (delete-dups
                  (append (hey-labels--workflow-stages workflow)
                          (mapcar (lambda (tag) (cadr (split-string tag "/")))
                                  (seq-filter (lambda (tag)
                                                (string-prefix-p (concat workflow "/") tag))
                                              (hey-notmuch--tags-in-namespace "wf/")))))))
    (erase-buffer)
    (insert (propertize (format "Workflow: %s\n" workflow)
                        'face 'notmuch-search-matching-authors)
            (propertize "RET open · m move · g refresh · q quit\n\n" 'face 'shadow))
    (if (null stages)
        (insert "No stages yet — put a thread in one with `H w'.\n")
      (dolist (stage stages)
        (hey-labels--board-insert-stage workflow stage)))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;###autoload
(defun hey-labels-workflow-board (workflow)
  "Show WORKFLOW as a board: one section per stage."
  (interactive (list (hey-labels--read-workflow t)))
  (let ((buffer (get-buffer-create (format "*HEY workflow: %s*" workflow))))
    (with-current-buffer buffer
      (hey-labels-board-mode)
      (setq hey-labels-board-workflow workflow)
      (hey-labels--board-render))
    (pop-to-buffer buffer)))

(defun hey-labels-board-refresh ()
  "Redraw the board."
  (interactive)
  (unless (derived-mode-p 'hey-labels-board-mode) (user-error "Not a board"))
  (hey-labels--board-render))

(defun hey-labels-board-open ()
  "Open the thread on this line."
  (interactive)
  (let ((tid (get-text-property (point) 'hey-thread)))
    (unless tid (user-error "No thread on this line"))
    (notmuch-show tid)))

(defun hey-labels-board-move ()
  "Move the thread on this line to another stage."
  (interactive)
  (let* ((tid (get-text-property (point) 'hey-thread))
         (workflow hey-labels-board-workflow)
         (stages (hey-labels--workflow-stages workflow)))
    (unless tid (user-error "No thread on this line"))
    (let* ((stage (hey-notmuch--sanitize-name
                   (completing-read (format "Move to stage of %s: " workflow) stages nil nil)
                   "Stage"))
           (prefix (format "wf/%s/" workflow))
           (query (concat "thread:" tid))
           (current (hey-notmuch--tags-in-namespace prefix query)))
      (unless (member stage stages)
        (hey-labels--workflow-remember workflow (append stages (list stage))))
      (notmuch-tag query (append (mapcar (lambda (s) (concat "-" prefix s))
                                         (remove stage current))
                                 (list (concat "+" prefix stage))))
      (hey-labels--board-render)
      (message "→ %s" stage))))

;; ───────────────────────────── keys ─────────────────────────────────
(with-eval-after-load 'notmuch
  (define-key hey-notmuch-map (kbd "t") #'hey-labels-add)
  (define-key hey-notmuch-map (kbd "T") #'hey-labels-remove)
  (define-key hey-notmuch-map (kbd "L") #'hey-labels-browse)
  (define-key hey-notmuch-map (kbd "k") #'hey-collections-add)
  (define-key hey-notmuch-map (kbd "K") #'hey-collections-browse)
  (define-key hey-notmuch-map (kbd "C-k") #'hey-collections-remove)
  (define-key hey-notmuch-map (kbd "w") #'hey-labels-workflow-set)
  (define-key hey-notmuch-map (kbd "W") #'hey-labels-workflow-board)
  (define-key hey-notmuch-map (kbd "C-w") #'hey-labels-workflow-clear))

(provide 'hey-labels)
;;; hey-labels.el ends here

;;; init.el -*- lexical-binding: t; -*-
(use-package use-package
  :no-require
  :custom
  (use-package-enable-imenu-support t))

(use-package early-init
  :no-require
  :unless (featurep 'early-init)
  :config
  (load-file (locate-user-emacs-file "early-init.el")))

;; Belt-and-braces PATH: `emacs.service' is session-tied so it starts after
;; niri-session has imported the login-shell environment, but a daemon started
;; any other way (plain `systemctl --user start emacs', a manual
;; `emacs --fg-daemon') inherits the user manager's bare PATH and then can't
;; find ~/.local/bin, the mise shims, hunspell or intelephense.  Run
;; unconditionally (don't gate on `window-system') — a `--fg-daemon' has no
;; window system but still needs the tools.
(use-package exec-path-from-shell
  :ensure t
  :custom
  ;; Login shell only — skip the interactive `-i' pass that sources the
  ;; whole fish config on every startup (~1000ms -> ~50ms).
  (exec-path-from-shell-arguments '("-l"))
  (exec-path-from-shell-check-startup-files nil)
  :init
  (exec-path-from-shell-initialize))

(use-package delight
  :ensure t)

(use-package local-config
	:no-require
	:preface
	(defgroup local-config ()
    "Customization group for local settings."
    :prefix "local-config-"
    :group 'emacs)
	(defcustom local-config-dark-theme 'modus-vivendi
    "Dark theme to use."
    :tag "Dark theme"
    :type 'symbol
    :group 'local-config)
	(defcustom local-config-light-theme 'modus-operandi
    "Light theme to use."
    :tag "Light theme"
    :type 'symbol
    :group 'local-config)
	(defcustom no-hscroll-modes '(term-mode)
    "Major modes to disable horizontal scrolling."
    :tag "Modes to disable horizontal scrolling"
    :type '(repeat symbol)
    :group 'local-config)
	(provide 'local-config))

(use-package functions
  :no-require
	:functions (dbus-color-scheme)
  :preface
  (defun gsettings-color-scheme-dark-p ()
    "Return non-nil when GSettings reports a dark color-scheme.
Fallback for `dark-mode-enabled-p' when the XDG desktop portal can't
answer.  Under systemd, `emacs.service' and `xdg-desktop-portal.service'
routinely activate in the same second, and the portal spends a moment
picking a Settings backend before it will serve a `Read' — so a daemon
launched at login asks too early, the D-Bus call errors, and we'd
otherwise fall through to the light theme.  `gsettings' reads dconf
directly with no service to race."
    (string-match-p
     "prefer-dark"
     (or (ignore-errors
           (shell-command-to-string
            "gsettings get org.gnome.desktop.interface color-scheme"))
         "")))
  (defun dark-mode-enabled-p ()
    "Check if dark mode is enabled."
    (cond ((file-exists-p (expand-file-name "~/.dark-mode")) t)
          ;; `dbus-color-scheme' answers nil when the portal *failed*, as
          ;; opposed to when it said light — the two must not collapse into
          ;; the same "not dark", or a startup race silently means light.
          ((featurep 'dbus)
           (pcase (dbus-color-scheme)
             ('dark t)
             ('light nil)
             (_ (gsettings-color-scheme-dark-p))))
          (t nil)))
  (defun memoize (fn)
    "Return a memoized version of FN.
FN must be referentially transparent.  Results are cached by `equal' on args."
    (let ((memo (make-hash-table :test 'equal)))
      (lambda (&rest args)
        ;; `memo' is used as a singleton sentinel to detect absent values.
        (let ((value (gethash args memo memo)))
          (if (eq value memo)
              (puthash args (apply fn args) memo)
            value)))))
  (provide 'functions))

(use-package defaults
  :no-require
  :preface
  (setq-default
   indent-tabs-mode nil
   tab-width 4
   load-prefer-newer t
   truncate-lines t
   bidi-paragraph-direction 'left-to-right
   bidi-inhibit-bpa t
   ;; Project-aware frame title (à la emacs-solo): show the project name when
   ;; inside one, else the buffer name.
   frame-title-format
   '(:eval
     (let ((project (project-current)))
       (if project
           (concat "Emacs - [p] " (project-name project))
         (concat "Emacs - " (buffer-name)))))
   auto-window-vscroll nil
   mouse-highlight t
   hscroll-step 1
   hscroll-margin 1
   scroll-margin 0
   scroll-conservatively 101
   scroll-preserve-screen-position nil)
  (when (window-system)
    (setq-default
     x-gtk-use-system-tooltips nil
     cursor-type 'box
     cursor-in-non-selected-windows nil))
  (setq
   ring-bell-function 'ignore
   mode-line-percent-position nil
   redisplay-skip-fontification-on-input t
   fast-but-imprecise-scrolling t
   enable-recursive-minibuffers t
   ;; Default 64KB throttles subprocess throughput; 1MB helps eglot/intelephense.
   read-process-output-max (* 1024 1024))
  (provide 'defaults))

(use-package jit-lock
  :custom
  (jit-lock-defer-time 0))

(use-package window
  ;; Native window-layout commands (Emacs 31+): `C-x w t' transpose, `C-x w r'
  ;; rotate, `C-x w f h/v' flip — these replace the external `transpose-frame'
  ;; package.  Keep the `C-x 4 t' muscle-memory key on the built-in transpose.
  :bind ( :map ctl-x-4-map
          ("t" . window-layout-transpose))
  :config
  (add-to-list 'display-buffer-alist '("\\*Calendar*" (display-buffer-at-bottom))))

(use-package winner
  :hook (after-init . winner-mode))

(use-package windmove
  :bind (("S-<left>"  . windmove-left)
         ("S-<right>" . windmove-right)
         ("S-<up>"    . windmove-up)
         ("S-<down>"  . windmove-down)))

(use-package mouse
  :hook (after-init . context-menu-mode)
  :bind (("<mode-line> <mouse-2>" . nil)
         ("<mode-line> <mouse-3>" . nil)))

(use-package no-blink-cursor
  :no-require
  ;; Solid, non-blinking cursor (pure-Kakoune feel; kao shows a box in normal
  ;; state, a bar in insert).  `blink-cursor-mode' is ON by default.  Disabling
  ;; it must NOT sit behind a `(window-system)' guard: a `--fg-daemon' has no
  ;; window-system at init, so such a guard silently skips it (the bug — `M-x'
  ;; worked only because a client frame existed by then).  Like the font setup
  ;; below, emacsclient frames are created after startup, so re-assert on each
  ;; server frame (when `M-x blink-cursor-mode' would take effect); `after-init'
  ;; covers a non-daemon launch.
  :hook ((after-init . my/disable-cursor-blink)
         (server-after-make-frame . my/disable-cursor-blink))
  :preface
  (defun my/disable-cursor-blink (&rest _)
    "Turn off `blink-cursor-mode' for a solid cursor."
    (blink-cursor-mode -1)))

(use-package font
  :no-require
  ;; In daemon mode `after-init-hook` fires before any frame exists, so
  ;; `find-font` (and thus `font-installed-p`) returns nil for every family
  ;; and `setup-fonts` silently no-ops — leaving the first GUI client to
  ;; inherit fontconfig's default monospace (Maple Mono Normal NF) instead
  ;; of `Maple Mono`. `server-after-make-frame-hook` fires once per
  ;; emacsclient connect, so we re-apply there too; the face just gets
  ;; re-set to the same value, which is harmless.
  :hook ((after-init . setup-fonts)
         (server-after-make-frame . setup-fonts))
  :preface
  (defun font-installed-p (font-name)
    "Check if a font with FONT-NAME is available."
    (find-font (font-spec :name font-name)))
  (defvar nerd-icons-fontset-size 13
    "Point size used when mapping Nerd-Font ranges into the global fontset.
Default `15' (the Maple Mono size) renders icon glyphs at their native
width, which is *wider* than Maple Mono's cell — the glyph overflows
into the next cell, the trailing space `eza --icons' emits gets eaten,
and icons look heavier/blockier than the same bytes rendered in a
real terminal (which scales the fallback glyph to the cell).
Setting this 1-2pt below the default face size shrinks the glyph to
sit cleanly inside one Maple Mono cell, matching the terminal's look.
Bump up if icons look too small; drop further if they still overflow.")
  (defun setup-nerd-icons-fontset ()
    "Route Nerd-Font codepoint ranges to `Symbols Nerd Font Mono'.
Without this, glyphs in the Private Use Area (Devicons, Codicons,
Material Design, Powerline, etc.) fall back to whatever Emacs picks
\\=— usually tofu \\=— because Maple Mono ships none of them.  Mapping
on the global fontset (`t') means the rule applies everywhere:
modeline, dired, vertico/marginalia, ghostel shell prompts (starship,
lsd, eza --icons), and any future buffer, without per-face fiddling.
`prepend' ensures Symbols Nerd Font Mono wins over any earlier rule
the theme or another package might have installed for these ranges.
The fontset entry is a `font-spec' rather than a bare family name so
we can pin `:size' to `nerd-icons-fontset-size' \\=— Emacs would
otherwise render the fallback glyph at its native 15pt advance, which
overflows Maple Mono's narrower cell.  Ranges come from the Nerd
Fonts cheat-sheet \\=— keep them in sync with `nerd-icons-data-*'
when upgrading the package."
    (when (font-installed-p "Symbols Nerd Font Mono")
      (let ((spec (font-spec :family "Symbols Nerd Font Mono"
                             :size nerd-icons-fontset-size)))
        (dolist (range '((#x23fb  . #x23fe)    ; IEC power symbols
                         (#x2665  . #x2665)    ; Octicons heart
                         (#x26a1  . #x26a1)    ; Octicons zap
                         (#x2b58  . #x2b58)    ; IEC power circle
                         (#xe000  . #xe00a)    ; Pomicons
                         (#xe0a0  . #xe0d4)    ; Powerline + Powerline Extra
                         (#xe200  . #xe2a9)    ; Font Awesome Extension
                         (#xe300  . #xe3e3)    ; Weather
                         (#xe5fa  . #xe6b7)    ; Seti-UI + Custom
                         (#xe700  . #xe8ef)    ; Devicons
                         (#xea60  . #xebeb)    ; Codicons
                         (#xed00  . #xefce)    ; Font Awesome
                         (#xf000  . #xf2ff)    ; Font Awesome
                         (#xf300  . #xf372)    ; Font Logos
                         (#xf400  . #xf533)    ; Octicons
                         (#xf500  . #xfd46)    ; Material Design (BMP)
                         (#xf0001 . #xf1af0))) ; Material Design (SMP)
          (set-fontset-font t range spec nil 'prepend)))))
  (defun setup-fonts ()
    ;; Mirror ghostty: font-size = 15pt, adjust-cell-height = 50%.
    ;; Emacs `:height' is 1/10 pt -> 150.
    ;; `line-spacing' as (above . below) cons (Emacs 31+) splits the 50% so
    ;; text sits vertically centered in each row, matching ghostty exactly.
    ;; A single float (e.g. 0.5) puts all extra space below, gluing text to
    ;; the top of each line. On Emacs ≤30 the cons form trips
    ;; `default-line-height' (wrong-type-argument number-or-marker-p) and
    ;; breaks vertico's resize math, so fall back to the float there.
    (setq-default line-spacing
                  (if (>= emacs-major-version 31) '(0.25 . 0.25) 0.5))
    ;; Prefer `Maple Mono Ghostty' — the bake-frozen variant produced by
    ;; `scripts/bake-maple-mono.sh' with my curated cv*/zero subset already
    ;; substituted into the GSUB table. Emacs's HarfBuzz shaper only applies
    ;; `calt/liga/clig/rlig/mark/mkmk' by default and silently ignores
    ;; fontconfig's `:fontfeatures=' token, so feature toggling at the spec
    ;; level doesn't work — the features have to live in the font file.
    ;; Falls back to plain `Maple Mono' (variable, no features baked) and
    ;; then `JetBrains Mono' when the bake hasn't been run yet.
    (let ((mono (cond ((font-installed-p "Maple Mono Ghostty") "Maple Mono Ghostty")
                      ((font-installed-p "Maple Mono") "Maple Mono")
                      ((font-installed-p "JetBrains Mono") "JetBrains Mono")))
          (height 120))
      (when mono
        ;; Maple Mono everywhere: default, fixed-pitch AND variable-pitch all
        ;; use the same mono family (so headings/prose stay monospace too).
        (set-face-attribute 'default nil :font mono :height height :width 'normal :weight 'normal)
        (set-face-attribute 'fixed-pitch nil :font mono)
        (set-face-attribute 'variable-pitch nil :font mono)))
    (setup-nerd-icons-fontset))
  (provide 'font))

(use-package ligature
  :ensure t
  :hook (after-init . global-ligature-mode)
  :config
  ;; Enable Maple Mono / JetBrains Mono programming ligatures everywhere.
  ;; This drives the `calt' OpenType feature — Emacs composes the character
  ;; sequences below, then HarfBuzz substitutes the ligature glyphs. The
  ;; `cv*' and `ss*' families are toggled separately via `:fontfeatures='
  ;; in `setup-fonts' above.
  ;; Canonical Maple Mono `calt' ligature set, sourced from
  ;; https://github.com/subframe7536/maple-font/blob/variable/source/features/README.md
  ;; Italic letter-pair ligatures (`ff' `tt' `ll' `al' `cl' …) are deliberately
  ;; omitted because they would composite parts of identifiers like `cell',
  ;; `full', `effect' in code.
  (ligature-set-ligatures
   't
   '(;; Arrows
     "->" "<-" "-->" "<--" "->>" "<<-" ">->" "<-<" "|->" "<-|" "<->" "<-->"
     "-------" ">--" "--<" "<#--" "<!--->"
     ;; Equality / comparison
     "==" "===" "=======" "!=" "!==" "=/=" "=!=" ">=<"
     "<=" ">=" "<=|" "|=>" "<==" "==>" "=>" "<==>" "=<=>" "=>=" "<=>" ">=>"
     ":=" "=:" ":=:" "=:="
     ;; ss09 / ss10 / ss11 — extra ligature packs from your ghostty config
     "~=" "=~" "!~"
     "|=" "/=" "?=" "&="
     ;; Comparison brackets / pipes
     "|>" "<|" "<|>" "<||" "||>" "<|||" "|||>"
     "{|" "|}" "[|" "|]" "{{" "}}" "{{--" "{{!--" "--}}"
     ;; Bit / shift
     "<<" "<<<" ">>" ">>>"
     ;; Logic / functional
     "<*" "*>" "<*>" "<+" "+>" "<+>" "<$" "<$>"
     ;; Tilde / approx
     "<~" "~>" "~~" "<~>" "<~~" "~~>" "-~" "~-" "~@" "~~~~~~~"
     ;; Slashes / comments
     "//" "///" "/*" "/**" "*/" "</" "/>" "</>" "<>" "<!--"
     ;; Plus / dot / question / colon families
     "++" "+++" "**" "***"
     ";;" ";;;" ".." "..." ".?" "?." "..<" ".="
     "::" ":::" "?:" ":?" ":?>" "<:" ":>" ":<" "<:<" ">:>"
     "??" "???" "&&" "&&&" "||" "!!"
     ;; Hashes
     "##" "###" "####" "#####" "######" "#######"
     "#{" "#[" "#(" "#?" "#!" "#:" "#=" "#_" "#__" "#_(" "]#"
     ;; Misc
     "__" "_|_" "--" "---"
     "\\."
     ;; Maple Mono's signature: bracketed log-keyword ligatures
     "[TRACE]" "[DEBUG]" "[INFO]" "[WARN]" "[WARNING]"
     "[ERROR]" "[EROR]" "[FATAL]"
     "[TODO]" "[FIXME]" "[NOTE]" "[HACK]" "[MARK]"
     ;; Keyword + double-close-paren — Maple Mono renders these as the
     ;; same icon glyphs as the bracketed forms above. Lowercase only:
     ;; the font's `calt' table is case-insensitive but Emacs's
     ;; `ligature.el' composition isn't, so `FixMe))' / `TODO))' won't
     ;; trigger — add the casings you actually type if you need them.
     "trace))" "debug))" "info))" "warn))" "warning))"
     "error))" "eror))" "fatal))"
     "todo))" "fixme))" "note))" "hack))" "mark))")))

(use-package nerd-icons
  :ensure t
  ;; Glyph lookup API (`nerd-icons-icon-for-file', `nerd-icons-faicon',
  ;; `nerd-icons-codicon', …) used by the integration packages below
  ;; and available everywhere for custom modeline / dashboard snippets.
  ;; The font itself is wired into the global fontset by
  ;; `setup-nerd-icons-fontset' in the `font' block above, so we do
  ;; NOT call `nerd-icons-install-fonts' here — the font is already
  ;; installed system-wide (check with
  ;; `fc-list | grep "Symbols Nerd Font Mono"').
  :custom
  (nerd-icons-font-family "Symbols Nerd Font Mono"))

(use-package cus-edit
  :custom
  (custom-file (locate-user-emacs-file "custom.el"))
  :init
  (load custom-file :noerror))

(use-package novice
  :preface
  (defvar disabled-commands (locate-user-emacs-file "disabled.el")
    "File to store disabled commands, that were enabled permanently.")
  (define-advice enable-command (:around (fn command) use-disabled-file)
    (let ((user-init-file disabled-commands))
      (funcall fn command)))
  :init
  (load disabled-commands 'noerror))

(use-package files
  :preface
  (defvar user-cache-directory
    (locate-user-emacs-file ".cache/")
    "Location where files created by emacs are placed.")
  (defvar backup-dir
    (locate-user-emacs-file ".cache/backups")
    "Directory to store backups.")
  (defvar auto-save-dir
    (locate-user-emacs-file ".cache/auto-save/")
    "Directory to store auto-save files.")
  :custom
  (backup-by-copying t)
  (create-lockfiles nil)
  (delete-by-moving-to-trash t)
  (backup-directory-alist
   `(("." . ,backup-dir)))
  (auto-save-file-name-transforms
   `((".*" ,auto-save-dir t)))
  (auto-save-no-message t)
  (auto-save-interval 100)
  (require-final-newline t)
  :bind ("<f5>" . revert-buffer-quick)
  :init
  (unless (file-exists-p auto-save-dir)
    (make-directory auto-save-dir t)))

(use-package face-remap
  :bind ([remap text-scale-pinch] . ignore))

(use-package savehist
  :hook (after-init . savehist-mode)
  :custom
  (history-length 300)
  (history-delete-duplicates t)
  (savehist-additional-variables '(kill-ring search-ring regexp-search-ring)))

(use-package recentf
  :hook (after-init . recentf-mode)
  :custom
  (recentf-max-saved-items 300)
  (recentf-auto-cleanup 'never)
  (recentf-exclude '("/tmp/" "/ssh:" "\\.cache/" "/elpa/")))

(use-package saveplace
  :hook (after-init . save-place-mode))

(use-package mule-cmds
  :no-require
  :custom
  (default-input-method 'bengali-probhat)
  :init
  (prefer-coding-system 'utf-8))

(use-package select
  :no-require
  :when (display-graphic-p)
  :custom
  (x-select-request-type '(UTF8_STRING COMPOUND_TEXT TEXT STRING)))

(use-package simple
  :bind (("M-z" . zap-up-to-char)
         ("M-S-z" . zap-to-char)
         ("C-x k" . kill-current-buffer)
         ("C-h C-f" . describe-face)
         ([remap undo] . undo-only)
         ;; dwim case ops: act on the region when active, else the next word
         ("M-u" . upcase-dwim)
         ("M-l" . downcase-dwim)
         ("M-c" . capitalize-dwim)
         ;; duplicate the current line, or the region when one is active
         ("C-," . duplicate-dwim))
  :hook ((before-save . delete-trailing-whitespace)
         (overwrite-mode . overwrite-mode-set-cursor-shape)
         (after-init . column-number-mode)
         (after-init . line-number-mode))
  :custom
  (yank-excluded-properties t)
  (save-interprogram-paste-before-kill t)
  (mouse-yank-at-point t)
  (blink-matching-delay 0)
  (blink-matching-paren t)
  (copy-region-blink-delay 0)
  (shell-command-default-error-buffer "*Shell Command Errors*")
  ;; C-u C-SPC, then C-SPC C-SPC… keeps popping the mark ring
  (set-mark-command-repeat-pop t)
  ;; C-w with no active region kills the previous word instead of erroring
  ;; (Emacs 31+).  Only affects insert-state C-w; kao's modal d/c are untouched.
  (kill-region-dwim 'emacs-word)
  ;; After `delete-pair', push a mark so C-x C-x selects what was inside (Emacs 31+).
  (delete-pair-push-mark t)
  :config
  (defun overwrite-mode-set-cursor-shape ()
    (when (display-graphic-p)
      (setq cursor-type (if overwrite-mode 'hollow 'box))))
  :preface
  (unless (fboundp 'minibuffer-keyboard-quit)
    (autoload #'minibuffer-keyboard-quit "delsel" nil t))
  (define-advice keyboard-quit
      (:around (quit) quit-current-context)
    "Quit the current context.

When there is an active minibuffer and we are not inside it close
it.  When we are inside the minibuffer use the regular
`minibuffer-keyboard-quit' which quits any active region before
exiting.  When there is no minibuffer `keyboard-quit' unless we
are defining or executing a macro."
    (if (active-minibuffer-window)
        (if (minibufferp)
            (minibuffer-keyboard-quit)
          (abort-recursive-edit))
      (unless (or defining-kbd-macro
                  executing-kbd-macro)
        (funcall-interactively quit)))))

(use-package delsel
  :hook (after-init . delete-selection-mode))

(use-package subword
  :delight subword-mode
  :hook (after-init . global-subword-mode))

(use-package minibuffer
  :bind ( :map minibuffer-inactive-mode-map
          ("<mouse-1>" . ignore))
  :custom
  (completion-styles '(orderless basic flex))
	(completion-category-defaults nil)
  (read-buffer-completion-ignore-case t)
  ;; (read-file-name-completion-ignore-case t)
  :custom-face
  (completions-first-difference ((t (:inherit unspecified)))))

;; Show recursion depth in the prompt (you enable `enable-recursive-minibuffers').
(use-package mb-depth
  :hook (after-init . minibuffer-depth-indicate-mode))

(use-package bindings
  :bind ( :map ctl-x-map
          ("DEL" . nil)
          ("C-d" . dired-jump))
  :init
  (setq mode-line-end-spaces nil))

(use-package mode-line
  :no-require
  :preface
  (defvar mode-line-interactive-position
    `(line-number-mode
      (:propertize "%l:%C"
                   help-echo "mouse-1: Goto line"
                   mouse-face mode-line-highlight
                   local-map ,(let ((map (make-sparse-keymap)))
                                (define-key map [mode-line down-mouse-1] 'goto-line)
                                map)))
    "Mode line position with goto-line binding.")
  (put 'mode-line-interactive-position 'risky-local-variable t)
  (defvar mode-line-vc
    '(:eval (when vc-mode
              ;; `vc-display-status' = `no-backend' strips the backend name but
              ;; leaves the separator dash; trim it so we read " main" not " -main".
              (replace-regexp-in-string "\\` ?-" " " vc-mode)))
    "VC info with the leading separator removed.")
  (put 'mode-line-vc 'risky-local-variable t)
  (fset 'abbreviate-file-name-memo (memoize #'abbreviate-file-name))
  (defun mode-line--buffer-display-name ()
    "Project-relative path if visiting a file inside a project,
abbreviated absolute path if visiting a file outside one,
buffer name otherwise."
    (if-let* ((file (buffer-file-name)))
        (or (when-let* ((proj (project-current))
                        (root (project-root proj)))
              (file-relative-name file root))
            (abbreviate-file-name-memo file))
      (buffer-name)))
  (defvar mode-line-buffer-file-name
    '(:eval (propertize (mode-line--buffer-display-name)
                        'help-echo (or (buffer-file-name) (buffer-name))
                        'face (when (and (buffer-file-name) (buffer-modified-p))
                                'font-lock-builtin-face)))
    "Show project-relative file path, falling back to abbreviated path or buffer name.
Modified file-backed buffers get `font-lock-builtin-face' applied to the name.")
  (put 'mode-line-buffer-file-name 'risky-local-variable t)
  (setq-default mode-line-format
                '(" " mode-line-buffer-file-name " " mode-line-modes
                  mode-line-format-right-align mode-line-misc-info
                  " " mode-line-interactive-position
                  mode-line-vc))
  :config
  (defun my/mode-line-pad (&rest _)
    "Pad mode-line vertically via an invisible :box matching the theme bg.
Symmetric `:line-width' — Emacs 32 dev rejects the cons form; using an integer
keeps the modeline padded vertically while accepting a small bit of horizontal
padding that blends into the background.  Re-runs on theme change.

Skips when the face background is `unspecified' (i.e. before any theme has
loaded) — otherwise `set-face-attribute' rejects the `:box :color' as invalid
and pollutes daemon stderr."
    (dolist (face '(mode-line mode-line-active mode-line-inactive))
      (when (facep face)
        (let ((bg (face-attribute face :background nil t)))
          (unless (eq bg 'unspecified)
            (set-face-attribute face nil
                                :box `(:line-width 8 :color ,bg)))))))
  (add-hook 'enable-theme-functions #'my/mode-line-pad)
  (my/mode-line-pad)
  (provide 'mode-line))

(use-package ibuffer
  :bind ([remap list-buffers] . ibuffer)
  :custom
  ;; Show buffer sizes as KB/MB instead of raw byte counts (Emacs 31+).
  (ibuffer-human-readable-size t))

(use-package frame
  ;; Frame-level "winner": `C-x 5 u' restores an accidentally-closed frame.
  :hook (after-init . undelete-frame-mode)
  :bind (("C-z" . ignore)
         ("C-x C-z" . ignore)))

(use-package startup
  :no-require
  :custom
  (inhibit-splash-screen t))

(use-package menu-bar
  :config
  (menu-bar-mode -1)
  ;; `menu-bar-mode -1' hides the menu globally, but creating a GUI frame on a
  ;; daemon can re-enable it, so later text-terminal frames (`emacsclient -t')
  ;; come up WITH a menu bar.  The old `:unless (display-graphic-p)' guard can't
  ;; help — on a daemon it runs once, with no frame to test.  Force the menu off
  ;; per TTY frame instead; a no-op on GUI frames.
  (defun my/menu-bar-hide-on-tty (&optional frame)
    "Remove the menu bar on FRAME when it is a text terminal."
    (unless (display-graphic-p frame)
      (set-frame-parameter frame 'menu-bar-lines 0)))
  (add-hook 'after-make-frame-functions #'my/menu-bar-hide-on-tty)
  (mapc #'my/menu-bar-hide-on-tty (frame-list)))

(use-package tooltip
  :when (window-system)
  :custom
  (tooltip-x-offset 0)
  (tooltip-y-offset (line-pixel-height))
  (tooltip-frame-parameters
   `((name . "tooltip")
     (internal-border-width . 2)
     (border-width . 1)
     (no-special-glyphs . t))))

(use-package dbus
  :when (featurep 'dbusbind)
  :demand t
  :requires (functions local-config)
  :commands (dbus-register-signal dbus-call-method)
  :preface
  (defun color-scheme-changed (path var value)
    "DBus handler to detect when the color-scheme has changed."
    (when (and (string-equal path "org.freedesktop.appearance")
               (string-equal var "color-scheme"))
      (if (equal (car value) '1)
          (load-theme local-config-dark-theme t)
        (load-theme local-config-light-theme t))))
  (defun dbus-color-scheme ()
    "Return the portal's color-scheme as `dark', `light', or nil.
nil means \"couldn't ask\" — the portal isn't up yet or the call
errored — which is deliberately distinct from `light', so callers can
fall back instead of quietly treating a failed probe as a light desktop.
Per the XDG appearance spec: 0 = no preference, 1 = prefer dark,
2 = prefer light."
    (pcase (caar (dbus-ignore-errors
                   (dbus-call-method
                    :session
                    "org.freedesktop.portal.Desktop"
                    "/org/freedesktop/portal/desktop"
                    "org.freedesktop.portal.Settings"
                    "Read"
                    "org.freedesktop.appearance"
                    "color-scheme")))
      (1 'dark)
      ((or 0 2) 'light)
      (_ nil)))
  :config
  (dbus-ignore-errors
   (dbus-register-signal :session
                         "org.freedesktop.portal.Desktop"
                         "/org/freedesktop/portal/desktop"
                         "org.freedesktop.portal.Settings"
                         "SettingChanged"
                         #'color-scheme-changed)))

(use-package modus-themes
  :ensure t
  :requires (local-config)
  :custom
  (modus-themes-org-blocks nil)
  ;; Gentle heading hierarchy — kept in the mono font, mostly weight with only
  ;; a small size bump (H1 ~15% over body).  Set every height to 1.0 for fully
  ;; flat, body-size headings.
  (modus-themes-headings
   '((0 . (light 1.2))                     ; #+title
     (1 . (semibold 1.1))
     (2 . (semibold 1.05))
     (3 . (medium 1.0))
     (4 . (medium 1.0))
     (t . (1.0))))
  (modus-themes-completions
   '((matches . (intense bold))
     (selection . (intense))))
  (modus-operandi-palette-overrides
   '((bg-main "#fbfbfb")
     (string "#702f00")
     (bg-line-number-active "#f0f0f0")))
  (modus-vivendi-palette-overrides
   `((bg-main "#181818")
     (bg-line-number-active "#1e1e1e")
     (string "#f5aa80")))
  :custom-face
  (region ((t :extend nil))))

(use-package modus-themes
  :after modus-themes
  ;; In daemon mode `after-init' runs while the session is still coming up, so
  ;; the color-scheme probe can lose the race against `xdg-desktop-portal'
  ;; (see `gsettings-color-scheme-dark-p') and settle on the wrong theme for
  ;; the life of the daemon.  Re-assert per client frame, like `setup-fonts'
  ;; and `my/disable-cursor-blink' above: by the time you open a frame the
  ;; portal has long been answering.  `load-modus' is a no-op when the right
  ;; theme is already enabled, so this costs nothing on subsequent connects.
  :hook ((after-init . load-modus)
         (server-after-make-frame . load-modus))
  :no-require
  :custom
  (modus-themes-common-palette-overrides
   `(;; syntax
     (builtin magenta-faint)
     (keyword cyan-faint)
     (comment fg-dim)
     (constant blue-faint)
     (docstring fg-dim)
     (docmarkup fg-dim)
     (fnname magenta-faint)
     (preprocessor cyan-faint)
     (string red-faint)
     (type magenta-cooler)
     (variable blue-faint)
     (rx-construct magenta-faint)
     (rx-backslash blue-faint)
     ;; misc
     (bg-paren-match bg-ochre)
     (bg-region bg-inactive)
     (fg-region unspecified)
     ;; line-numbers
     (fg-line-number-active fg-main)
     (bg-line-number-inactive bg-main)
     (fg-line-number-inactive fg-dim)
     ;; modeline
     (border-mode-line-active unspecified)
     (border-mode-line-inactive unspecified)
     ;; links
     (underline-link unspecified)
     (underline-link-visited unspecified)
     (underline-link-symbolic unspecified)
     ,@modus-themes-preset-overrides-faint))
  :config
  (defun load-modus (&rest _)
    "Enable the theme matching the system color-scheme.
Idempotent: returns immediately when that theme is already the enabled
one, so re-running per frame is free.  The counterpart theme is disabled
first — `load-theme' only stacks, and leaving the old one enabled
underneath leaks its faces through wherever the new theme doesn't
override them."
    (let* ((dark (dark-mode-enabled-p))
           (theme (if dark local-config-dark-theme local-config-light-theme))
           (other (if dark local-config-light-theme local-config-dark-theme)))
      (when (memq other custom-enabled-themes)
        (disable-theme other))
      (unless (memq theme custom-enabled-themes)
        (load-theme theme 'no-confirm)))))

(use-package qshell-theme
  :no-require
  :after modus-themes
  ;; Desktop-synced theming (qshell only): the dotfiles' theme system
  ;; renders the active theme's palette to ~/.local/state/qshell/emacs-theme.el,
  ;; and themes/qshell-{dark,light}-theme.el are Modus derivatives that read it.
  ;; Wired only when that file exists, so a machine without the qshell desktop
  ;; (a server, a fresh clone) keeps stock Modus untouched.  Polarity still
  ;; flows through `load-modus' and the portal signal — the desktop flips the
  ;; system color-scheme with each theme, and both qshell themes track it.
  :config
  (defconst qshell-theme-state-file
    (expand-file-name "~/.local/state/qshell/emacs-theme.el")
    "Palette file bin/theme-apply renders from the desktop theme.")
  (defun qshell-theme--wire ()
    "Point the local-config themes at the qshell pair when the palette exists."
    (when (file-exists-p qshell-theme-state-file)
      (setq local-config-dark-theme 'qshell-dark
            local-config-light-theme 'qshell-light)))
  (defun qshell-theme-refresh ()
    "Re-apply the qshell theme after the desktop palette changed.
theme-apply pokes this over emacsclient on every desktop theme switch.
`load-modus' first, for a polarity flip (loading the counterpart theme
re-reads the palette on its way in); then an unconditional `load-theme'
of whichever qshell theme ends up active, because a same-polarity
switch is exactly the case `load-modus' skips as already enabled —
`load-theme', unlike `enable-theme', re-evaluates the theme file."
    (interactive)
    (qshell-theme--wire)
    (load-modus)
    (let ((active (seq-find (lambda (theme) (memq theme '(qshell-dark qshell-light)))
                            custom-enabled-themes)))
      (when active (load-theme active 'no-confirm))))
  (add-to-list 'custom-theme-load-path
               (expand-file-name "themes/" user-emacs-directory))
  (qshell-theme--wire))

(use-package uniquify
  :defer t
  :custom
  (uniquify-buffer-name-style 'forward))

(use-package display-line-numbers
  :hook ((prog-mode             . display-line-numbers-mode)
         (display-line-numbers-mode . toggle-hl-line))
  :custom
  (display-line-numbers-width 4)
  (display-line-numbers-grow-only t)
  (display-line-numbers-width-start t)
  :config
  (defun toggle-hl-line ()
    (hl-line-mode (if display-line-numbers-mode 1 -1))))

(use-package pixel-scroll
  :when (fboundp #'pixel-scroll-precision-mode)
  :hook (after-init . pixel-scroll-precision-mode)
  :custom
  (scroll-margin 0)
  (pixel-scroll-precision-use-momentum nil))

(use-package paren
  :hook (prog-mode . show-paren-mode)
  :custom
  ;; When the matching opener is scrolled off-screen, echo its line in an
  ;; overlay at the top of the window.
  (show-paren-context-when-offscreen 'overlay)
  (show-paren-style 'mixed)
  :config
  ;; `show-paren-mode' is ON globally by default (Emacs 28+), so it also fires in
  ;; Org.  Turn the matching-pair highlight OFF in Org buffers (the brackets in
  ;; links / footnotes / markup are just noise there); prog-mode keeps it.
  (defun my/org-disable-show-paren ()
    "Disable matching-pair highlighting in the current (Org) buffer."
    (show-paren-local-mode -1))
  (add-hook 'org-mode-hook #'my/org-disable-show-paren))

(use-package elec-pair
  :hook (prog-mode . electric-pair-local-mode))

(use-package vc-hooks
  :defer t
  :custom
  (vc-follow-symlinks t)
  (vc-git-print-log-follow t)
  (vc-handled-backends '(Git))
  (vc-display-status 'no-backend))

(use-package tramp
  :defer t
  :custom
  (tramp-default-method "ssh")
  ;; Default verbose 3 floods the echo area with "Tramp: …" chatter on
  ;; every save. 1 = errors only; bump to 6+ to debug a hang.
  (tramp-verbose 1)
  ;; Cache remote file stats for 60s so dired and completion don't
  ;; re-stat on every keystroke. Stale-on-purpose; revert manually.
  (remote-file-name-inhibit-cache 60)
  ;; Lock/auto-save files are useless over ssh and double every write.
  (remote-file-name-inhibit-locks t)
  (remote-file-name-inhibit-auto-save-visited t)
  ;; Files >1MB go through an out-of-band scp instead of inline base64
  ;; copy — orders of magnitude faster for binaries and logs.
  (tramp-copy-size-limit (* 1024 1024))
  (tramp-use-scp-direct-remote-copying t)
  ;; ControlMaster lives in ~/.ssh/config (Host *), so TRAMP shouldn't
  ;; append its own -o ControlMaster=… args and fight with it.
  (tramp-use-ssh-controlmaster-options nil)
  (tramp-persistency-file-name
   (expand-file-name "tramp" user-cache-directory))
  :config
  ;; Run async processes (compile, shell-command, project-find-file)
  ;; directly over the existing ssh socket instead of spawning a new
  ;; PTY per call. Requires the ControlMaster setup in ~/.ssh/config.
  (connection-local-set-profile-variables
   'remote-direct-async-process
   '((tramp-direct-async-process . t)))
  (connection-local-set-profiles
   '(:application tramp :protocol "ssh")
   'remote-direct-async-process)
  (connection-local-set-profiles
   '(:application tramp :protocol "scp")
   'remote-direct-async-process))

(use-package ediff
  :defer t
  :custom
  (ediff-window-setup-function 'ediff-setup-windows-plain)
  (ediff-split-window-function 'split-window-horizontally))

;; HEY.com-style email: notmuch + mbsync + msmtp.  Backend config lives in
;; ~/.mbsyncrc, ~/.notmuch-config, ~/.msmtprc and ~/Mail/.notmuch/hooks/.
(add-to-list 'load-path (locate-user-emacs-file "lisp"))
(load (locate-user-emacs-file "lisp/hey-notmuch") :noerror)

(use-package magit
  :ensure t
  :bind ("C-x g" . magit-status)
  :custom
  ;; Don't warn when a diff has lines past `long-line-threshold' (50000 chars,
  ;; e.g. minified assets/lockfiles); Magit just drops highlighting on them.
  (magit-show-long-lines-warning nil))

(use-package server
  :commands (server-running-p)
  :init
  (unless (server-running-p)
    (server-start)))

(use-package eldoc
  :delight eldoc-mode
  :defer t
  :custom
  (eldoc-echo-area-use-multiline-p nil)
  ;; Auto-show the symbol's doc / flymake diagnostic at point when idle.
  (eldoc-help-at-pt t)
  ;; When a *eldoc* doc buffer is showing, prefer it over the echo area so
  ;; spelunking unfamiliar code stays in the richer view (Emacs 31+).
  (eldoc-echo-area-prefer-doc-buffer t))

(use-package treesit
  :custom
  (treesit-font-lock-level 4)
  (treesit-enabled-modes t)
  (treesit-auto-install-grammar 'ask))

(use-package eglot
  :commands (eglot eglot-ensure)
  :bind ( :map eglot-mode-map
          ("C-h ." . eldoc))
  :hook (eglot-managed-mode . my/eglot-eldoc-compose)
  :preface
  (defun my/eglot-eldoc-compose ()
    "Show eglot docs alongside flymake diagnostics in the echo area."
    (setq eldoc-documentation-strategy 'eldoc-documentation-compose-eagerly))
  :custom
  (eglot-autoshutdown t)         ; kill server when last buffer closes
  (eglot-sync-connect nil)       ; don't block UI while connecting
  (eglot-extend-to-xref t)       ; xref jumps may leave the project
  (eglot-events-buffer-config '(:size 0 :format short)) ; silence event log
  ;; Suppress the inline "code action available here" hints (Emacs 31+); some
  ;; servers (e.g. intelephense) make them noisy.  Actions still run via
  ;; `eglot-code-actions' / M-x.
  (eglot-code-action-indications nil)
  :config
  ;; Eglot's default PHP entry tries phpactor / felixfbecker — override to
  ;; use intelephense (installed via `pnpm i -g intelephense'). Pushed to
  ;; the front of the alist so it wins over the built-in default.
  (add-to-list 'eglot-server-programs
               '((php-mode phps-mode php-ts-mode) . ("intelephense" "--stdio"))))

(use-package consult-eglot
  :ensure t
  ;; Incremental project-wide symbol search (`consult-eglot-symbols'); the
  ;; eglot/consult bridge for kakoune-lsp's `o' = lsp-workspace-symbol-incr.
  ;; Reached via the `SPC c o' code menu (see the kao block).
  :after eglot)

(use-package xref
  ;; Use ripgrep for `xref-find-references' / `xref-find-apropos' (you already
  ;; have rg via consult); much faster than the default grep on large trees.
  :custom
  (xref-search-program 'ripgrep))

(use-package esh-mode
  :custom
  (eshell-scroll-show-maximum-output nil)
  ;; (eshell-prompt-function 'eshell-prompt)
  (eshell-banner-message ""))

(use-package em-term
  :defer t
  :config
  ;; Full-screen TUIs need a real terminal/PTY. Eshell routes commands
  ;; listed here through `eshell-exec-visual'; `ghostel-eshell-visual-
  ;; command-mode' then renders them in a ghostel buffer. (`tmux' is
  ;; already in the default `eshell-visual-commands'.)
  (dolist (cmd '("btop" "tmux" "lazygit" "gitui" "claude" "pi" "yazi"))
    (add-to-list 'eshell-visual-commands cmd)))

(use-package dired
  :bind ( :map dired-mode-map
          ("~" . dired-home-directory)
          ("C-c l" . org-store-link)
          ("<backspace>" . dired-up-directory)
          ("h" . dired-up-directory)
          ("l" . dired-find-file)
          ;; kao-style row navigation: j/k move down/up (what n/p do); the
          ;; default j/k shift up to J/K so nothing is lost.
          ("j" . dired-next-line)
          ("k" . dired-previous-line)
          ("J" . dired-goto-file)        ; was `j'
          ("K" . dired-do-kill-lines))   ; was `k'
  :functions (dired-current-directory)
  :hook (dired-mode . dired-hide-details-mode)
  :preface
  (defvar dired-listing-switches-no-dotfiles
    "-lXhv --group-directories-first")
  (defvar dired-listing-switches-dotfiles
    "-lAXhv --group-directories-first")
  :custom
  (dired-listing-switches dired-listing-switches-dotfiles)
  ;; Quality-of-life behaviour, no extra packages required:
  (dired-dwim-target t)                        ; 2nd visible dired buffer = default copy/move target
  (dired-recursive-copies 'always)             ; don't ask on recursive copy
  (dired-recursive-deletes 'always)            ; don't ask on recursive delete
  (dired-kill-when-opening-new-dired-buffer t) ; descending reuses the buffer (replaces dired-single)
  (dired-auto-revert-buffer #'dired-directory-changed-p) ; refresh listing when the dir changed
  (dired-mouse-drag-files t)                   ; drag rows out to other apps
  (dired-isearch-filenames 'dwim)              ; C-s sticks to filenames when on one
  (dired-vc-rename-file t)                      ; renames go through VC so history follows
  (dired-create-destination-dirs 'ask)         ; offer to mkdir missing copy/move targets
  (dired-clean-confirm-killing-deleted-buffers nil)
  ;; Drop the absolute directory path from the header under hide-details (Emacs 31+).
  (dired-hide-details-hide-absolute-location t)
  :config
  (defun dired-home-directory ()
    (interactive)
    (dired (expand-file-name "~/")))
  (defun dired-toggle-dotfiles ()
    (interactive)
    (setf dired-listing-switches
          (if (string= dired-listing-switches
                       dired-listing-switches-no-dotfiles)
              dired-listing-switches-dotfiles
            dired-listing-switches-no-dotfiles))
    (dolist (buffer dired-buffers)
      (with-current-buffer (cdr buffer)
        (dired-noselect (dired-current-directory) dired-listing-switches)))))

(use-package nerd-icons-dired
  :ensure t
  ;; Per-row file-type icons in dired listings. Pure visual layer:
  ;; doesn't touch `dired-listing-switches' or hide-details, so it
  ;; composes cleanly with `dired-toggle-dotfiles' above.
  :hook (dired-mode . nerd-icons-dired-mode))

(use-package dired-x
  ;; Built-in dired extensions. Loaded after dired so its keymap additions land:
  ;; `C-x M-o' -> dired-omit-mode, `* .' -> mark-by-extension, plus the
  ;; `dired-guess-shell-alist-user' table that `!' consults for defaults.
  :after dired
  :config
  ;; `!' (dired-do-shell-command) defaults to the desktop's registered handler.
  (setq dired-guess-shell-alist-user '((".*" "xdg-open"))))

(use-package diredfl
  :ensure t
  ;; File-type colourisation. Pure font-lock layer; composes with nerd-icons.
  :hook (dired-mode . diredfl-mode))

(use-package dired-subtree
  :ensure t
  :after dired
  ;; `TAB' expands a directory inline as a subtree; `S-TAB' cycles fold depth.
  ;; Both keys were unbound in dired-mode by default, so nothing is shadowed.
  :bind ( :map dired-mode-map
          ("<tab>" . dired-subtree-toggle)
          ("<backtab>" . dired-subtree-cycle))
  :custom (dired-subtree-use-backgrounds nil)
  :config
  ;; nerd-icons-dired only re-icons on `dired-after-readin-hook'; subtree
  ;; inserts rows without re-reading, so re-icon the buffer after a toggle.
  (advice-add 'dired-subtree-toggle :after #'nerd-icons-dired--refresh)
  (advice-add 'dired-subtree-cycle  :after #'nerd-icons-dired--refresh))

(use-package dired-preview
  :ensure t
  :after dired
  ;; Auto-preview the file at point while this (buffer-local) mode is on.
  ;; `P' toggles it -- shadows the rarely-used `dired-do-print' (still on M-x).
  :custom (dired-preview-delay 0.4)
  :bind ( :map dired-mode-map
          ("P" . dired-preview-mode)))

(use-package comint
  :defer t
  :custom
  (comint-scroll-show-maximum-output nil)
  (comint-highlight-input nil)
  (comint-input-ignoredups t))

(use-package with-editor
  :ensure t
  ;; Use THIS Emacs as $EDITOR for programs launched from in-Emacs shells, so
  ;; e.g. `git commit' opens an editor buffer here instead of a nested editor.
  ;; ghostel is wired separately (`ghostel-pre-spawn-hook'), since it's
  ;; `fundamental-mode' and `with-editor-export-editor' can't hook it.  In these
  ;; modes the edit buffer gets `with-editor-mode' → finish `C-c C-c', cancel
  ;; `C-c C-k'.  (Add `(vterm-mode . with-editor-export-editor)' if you install vterm.)
  :hook ((eshell-mode . with-editor-export-editor)
         (shell-mode  . with-editor-export-editor)
         (term-exec   . with-editor-export-editor)))

(use-package rect
  :bind (("C-x r C-y" . rectangle-yank-add-lines))
  :custom
  (rectangle-indicate-zero-width-rectangle nil)
  :preface
  (defun rectangle-yank-add-lines ()
    (interactive "*")
    (when (use-region-p)
      (delete-region (region-beginning) (region-end)))
    (save-restriction
      (narrow-to-region (point) (point))
      (yank-rectangle))))

(use-package profiler
  :bind ("<f2>" . profiler-start-or-report)
  :commands (profiler-report)
  :preface
  (defun profiler-start-or-report ()
    (interactive)
    (if (not (profiler-cpu-running-p))
        (profiler-start 'cpu)
      (profiler-report)
      (profiler-cpu-stop))))

(use-package hideshow
  :hook (prog-mode . hs-minor-mode)
  :delight hs-minor-mode
  :preface
  (define-advice hs-toggle-hiding (:before (&rest _) move-point-to-mouse)
    "Move point to the location of the mouse pointer."
    (when (mouse-event-p last-input-event)
      (mouse-set-point last-input-event))))

(use-package help
  :custom
  (help-window-select t))

;; Jump straight to the source of a command/key/variable/library — handy when
;; editing this config or spelunking built-ins.
(use-package find-func
  :bind (("C-h M-k" . find-function-on-key)
         ("C-h M-f" . find-function)
         ("C-h M-v" . find-variable)
         ("C-h M-l" . find-library)))

;; Native word definitions (dict.org); complements jinx's spell-checking.
(use-package dictionary
  :bind ("C-c w" . dictionary-search)
  :custom
  (dictionary-server "dict.org")
  (dictionary-use-single-buffer t))

(use-package which-key
  :hook (after-init . which-key-mode)
  :delight which-key-mode
  :custom
  (which-key-idle-delay 0.75)
  :config
  ;; My global `line-spacing' (init.el:204) makes rows 1.5x tall, which breaks
  ;; the side-window's `fit-window-to-buffer' math and clips the bottom row.
  ;; Reset it inside the which-key buffer so the popup fits exactly -- the same
  ;; fix karthink uses alongside his own global line-spacing.
  (add-hook 'which-key-init-buffer-hook
            (lambda () (setq-local line-spacing nil))))

(use-package doc-view
  :defer t
  :custom
  (doc-view-resolution 192))

(use-package flymake
  :preface
  (defvar flymake-prefix-map (make-sparse-keymap))
  (fset 'flymake-prefix-map flymake-prefix-map)
  :bind ( :map ctl-x-map
          ("!" . flymake-prefix-map)
          :map flymake-prefix-map
          ("l" . flymake-show-buffer-diagnostics)
          ("n" . flymake-goto-next-error)
          ("p" . flymake-goto-prev-error))
  :custom
  (flymake-fringe-indicator-position 'right-fringe)
  (flymake-mode-line-lighter "FlyM")
  :config
  (setq elisp-flymake-byte-compile-load-path (cons "./" load-path)))

(use-package markdown-ts-mode
  ;; Built-in (Emacs 31+) but experimental, so upstream doesn't wire it to
  ;; `auto-mode-alist' yet — do it here so `.md'/`.markdown' open in it: live
  ;; code-block fontification via each language's real major mode, Org-like
  ;; heading navigation/folding, and inline image rendering.  This is also what
  ;; activates the `markdown-ts-mode' entry in the jinx hook below (otherwise
  ;; dead).  First open prompts to install the markdown tree-sitter grammar via
  ;; your `treesit-auto-install-grammar' setting.
  :mode (("\\.md\\'" . markdown-ts-mode)
         ("\\.markdown\\'" . markdown-ts-mode)))

(use-package jinx
  :ensure t
	:when (executable-find "hunspell")
	:hook ((org-mode git-commit-mode markdown-ts-mode) . jinx-mode)
  :custom
  (jinx-languages "en_US"))

;; Capture router: drop a capture under <project>/<section> in projects.org,
;; prompting for the project.  One template per *kind* (issue/feature/task/
;; note) scales to N projects with no per-project template sprawl.
(defun my/org-capture-into-project (section)
  "Set capture target to SECTION under a chosen :project: heading in projects.org.
Creates SECTION as a child heading if it does not exist yet."
  (let ((file (expand-file-name "projects.org" org-directory)))
    (set-buffer (org-capture-target-buffer file))
    (widen)
    (goto-char (point-min))
    (let* ((projects (org-map-entries
                      (lambda () (org-get-heading t t t t)) "LEVEL=1" 'file))
           (project (completing-read "Project: " projects nil t)))
      (goto-char (point-min))
      (re-search-forward
       (format org-complex-heading-regexp-format (regexp-quote project)))
      (org-narrow-to-subtree)
      (if (re-search-forward
           (format org-complex-heading-regexp-format (regexp-quote section)) nil t)
          (goto-char (line-beginning-position))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "** %s\n" section))
        (forward-line -1))
      (widen))))

(use-package org
  :bind ( :map mode-specific-map
          ("c" . org-capture)
          ("a" . org-agenda)
          ("j" . org-clock-goto))
  :custom
  ;; --- paths ---
  (org-directory "~/Documents/org")
  (org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (org-agenda-files (list org-directory))   ; scans org-directory top level; archive/ excluded
  ;; --- startup / src blocks ---
  (org-startup-folded 'content)
  ;; --- in-buffer rendering / prettify ---
  ;; Render \alpha->a, \rightarrow->arrow, \copyright->(c) and braced
  ;; sub/superscripts (x^{2}, H_{2}O) as real glyphs.  Off by default; the
  ;; org-showcase file assumes it is on.
  (org-pretty-entities t)
  (org-pretty-entities-include-sub-superscripts t)
  ;; Only treat *braced* forms as sub/superscripts, so ordinary words with
  ;; underscores (foo_bar, my_file) are left untouched.
  (org-use-sub-superscripts '{})
  ;; Hide the =*/_+~ emphasis markers themselves so *bold* reads as bold.
  ;; NOTE: with org-appear removed the markers stay hidden even while editing;
  ;; set this to nil if you'd rather always see them.
  (org-hide-emphasis-markers t)
  ;; Breathing room that matches the surrounding context: a new heading gets a
  ;; blank line only where its siblings already have one (so new projects get a
  ;; gap, new sub-headings stay tight).  `auto' = mirror the existing spacing.
  (org-blank-before-new-entry '((heading . auto) (plain-list-item . auto)))
  (org-cycle-separator-lines 1)              ; show 1 blank line above folded headings
  ;; NOTE: org-indent-mode is intentionally OFF — org-modern can only hide
  ;; leading stars when org-indent is disabled, so we let org-modern style
  ;; headings (single fold-triangle, no stray stars) instead of indenting.
  (org-src-fontify-natively t)
  (org-src-tab-acts-natively t)
  (org-src-preserve-indentation t)
  (org-edit-src-content-indentation 0)
  (org-src-window-setup 'current-window)
  (org-image-actual-width nil)
  (org-confirm-babel-evaluate t)            ; SAFE: ask before running a src block
  ;; --- TODO workflow ---
  (org-todo-keywords
   '((sequence "TODO(t)" "NEXT(n)" "PENDING(p@/!)" "REVIEW(r@/!)"
               "|" "DONE(d!)" "CANCELLED(x@)")
     (sequence "ISSUE(i)" "|" "FIXED(f!)" "WONTFIX(w@)")
     (sequence "PROJECT(P)" "|" "COMPLETE(C)" "DROPPED(D@)")))
  (org-todo-keyword-faces
   '(("NEXT"      . (:inherit (bold org-todo)))
     ("PENDING"   . (:inherit (bold warning)))
     ("REVIEW"    . (:inherit (bold font-lock-keyword-face)))
     ("ISSUE"     . (:inherit (bold error)))
     ("PROJECT"   . (:inherit (bold font-lock-doc-face)))
     ("CANCELLED" . (:inherit (org-done shadow) :strike-through t))
     ("WONTFIX"   . (:inherit shadow :strike-through t))
     ("DROPPED"   . (:inherit shadow :strike-through t))
     ("FIXED"     . org-done)
     ("COMPLETE"  . org-done)))
  (org-use-fast-todo-selection 'expert)     ; minibuffer selection, no popup window
  (org-enforce-todo-dependencies t)         ; parent can't be DONE with open children
  (org-treat-insert-todo-heading-as-state-change t)
  ;; --- logging ---
  (org-log-done 'time)
  (org-log-into-drawer t)                    ; tuck logs + clocks into :LOGBOOK:
  (org-log-redeadline 'time)
  (org-log-reschedule 'time)
  ;; --- tags / properties (project CRM) ---
  (org-tag-alist
   '((:startgroup) ("shopify" . ?s) ("standalone" . ?a) (:endgroup)
     (:startgroup) ("feature" . ?f) ("bug" . ?b) ("chore" . ?c) (:endgroup)
     ("@shopify" . ?S) ("@deploy" . ?D) ("@email" . ?e) ("idea" . ?I)))
  (org-tags-exclude-from-inheritance '("project"))
  (org-use-property-inheritance '("STATUS" "REPO" "STACK"))
  (org-columns-default-format
   "%40ITEM(Project) %STATUS %12STACK %TODO %8CLOCKSUM(Clocked)")
  (org-global-properties
   '(("STATUS_ALL" . "active backlog paused shipped")
     ("Effort_ALL" . "0:15 0:30 1:00 2:00 4:00 1d")))
  ;; --- refile ---
  (org-refile-targets '((nil . (:maxlevel . 3))
                        (org-agenda-files . (:maxlevel . 3))))
  (org-refile-use-outline-path 'file)
  (org-outline-path-complete-in-steps nil)
  (org-refile-allow-creating-parent-nodes 'confirm)
  ;; --- scheduling discipline ---
  (org-deadline-warning-days 14)
  (org-agenda-skip-scheduled-if-done t)
  (org-agenda-skip-deadline-if-done t)
  ;; --- clocking (time tracking / billing) ---
  (org-clock-persist 'history)
  (org-clock-persist-query-resume nil)
  (org-clock-in-resume t)
  (org-clock-into-drawer t)
  (org-clock-out-remove-zero-time-clocks t)
  (org-clock-mode-line-total 'current)
  (org-clock-report-include-clocking-task t)
  (org-clock-in-switch-to-state
   (lambda (state) (if (member state '("TODO")) "NEXT" state)))
  ;; --- archive ---
  (org-archive-location "archive/%s_archive::* Archived")
  (org-archive-save-context-info '(time file olpath category itags))
  ;; --- stuck projects: a PROJECT heading with no NEXT child ---
  (org-stuck-projects '("/PROJECT" ("NEXT") nil ""))
  ;; --- capture ---
  (org-capture-bookmark nil)                 ; don't drop a fringe bookmark on each capture
  (org-capture-templates
   '(("t" "Todo → inbox" entry (file+headline "inbox.org" "Inbox")
      "* TODO %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n" :prepend t :empty-lines-after 1)
     ("l" "Todo w/ link → inbox" entry (file+headline "inbox.org" "Inbox")
      "* TODO %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n%a\n" :prepend t :empty-lines-after 1)
     ("n" "Note → inbox" entry (file+headline "inbox.org" "Inbox")
      "* %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n" :prepend t)
     ("e" "Idea → ideas.org" entry (file+headline "ideas.org" "Ideas")
      "* %? :idea:\n:PROPERTIES:\n:CREATED: %U\n:END:\n" :prepend t)
     ("p" "Project…")
     ("pp" "  New project" entry (file "projects.org")
      "* PROJECT %^{Project name} :project:\n:PROPERTIES:\n:STATUS:   %^{Status|active|backlog|paused|shipped}\n:STACK:    %^{Stack}\n:REPO:     %^{Repo}\n:CREATED:  %U\n:END:\n\n** Details\n%?\n\n** Features\n** Issues\n** Tasks\n** Notes"
      :prepend t :empty-lines-after 1)
     ("pi" "  Issue"   entry (function (lambda () (my/org-capture-into-project "Issues")))
      "* ISSUE %^{Title} :bug:\n:PROPERTIES:\n:CREATED: %U\n:END:\n%a\n%?" :empty-lines-after 1)
     ("pf" "  Feature" entry (function (lambda () (my/org-capture-into-project "Features")))
      "* TODO %^{Title} :feature:\n:PROPERTIES:\n:CREATED: %U\n:END:\n%?" :empty-lines-after 1)
     ("pt" "  Task"    entry (function (lambda () (my/org-capture-into-project "Tasks")))
      "* TODO %^{Title}\n:PROPERTIES:\n:CREATED: %U\n:END:\n%?" :empty-lines-after 1)
     ("pn" "  Note"    entry (function (lambda () (my/org-capture-into-project "Notes")))
      "* %^{Title}\n:PROPERTIES:\n:CREATED: %U\n:END:\n%a\n%?" :empty-lines-after 1)
     ("m" "Meeting (clock in)" entry (file+headline "gtd.org" "Meetings")
      "* MEETING %^{With/about}\n:PROPERTIES:\n:CREATED: %U\n:END:\n%?"
      :clock-in t :clock-resume t)
     ("j" "Journal" entry (file+olp+datetree "journal.org") "* %?\n%U")))
  ;; --- agenda: native multi-block dashboard ---
  (org-agenda-window-setup 'current-window)
  (org-agenda-block-separator ?─)
  (org-agenda-tags-column -100)
  (org-agenda-custom-commands
   '(("d" "Daily dashboard"
      ((agenda "" ((org-agenda-span 1) (org-deadline-warning-days 7)
                   (org-agenda-overriding-header "Today")))
       (tags-todo "+PRIORITY=\"A\"-project"
                  ((org-agenda-overriding-header "Important — no date")
                   (org-agenda-skip-function
                    '(org-agenda-skip-entry-if 'scheduled 'deadline 'timestamp))))
       (todo "NEXT"    ((org-agenda-overriding-header "Next actions")))
       (todo "REVIEW"  ((org-agenda-overriding-header "In review")))
       (todo "PENDING" ((org-agenda-overriding-header "Waiting / blocked")))
       (todo "ISSUE"   ((org-agenda-overriding-header "Open issues")))))
     ("p" "Projects overview"
      ((todo "PROJECT" ((org-agenda-overriding-header "All projects")))
       (stuck "" ((org-agenda-overriding-header "Stuck (no NEXT action)")))))
     ("i" "Open issues"       todo "ISSUE")
     ("r" "In review"         todo "REVIEW")
     ("w" "Pending / waiting"  todo "PENDING")
     ("R" "Weekly review"
      ((agenda "" ((org-agenda-span 7) (org-agenda-start-on-weekday 1)
                   (org-agenda-start-with-log-mode t)))
       (stuck "")
       (todo "PENDING")
       (todo "REVIEW")))))
  :config
  (org-clock-persistence-insinuate)
  (require 'org-habit)                        ; :STYLE: habit -> consistency graph in agenda
  (require 'org-tempo)                        ; <s TAB → src block, etc.
  ;; --- project dashboards: every ~/Sites/*/*/PROJECT.org joins the agenda ---
  ;; PROJECT.org files are pipeline dashboards generated/synced by the
  ;; org-dashboard skill (~/Sites/github/claude-skills). Recomputed before each
  ;; agenda build so new projects appear without a restart.
  (defun my/org-agenda-add-project-files (&rest _)
    (setq org-agenda-files
          (append (list org-directory)
                  (file-expand-wildcards "~/Sites/*/*/PROJECT.org"))))
  (advice-add 'org-agenda :before #'my/org-agenda-add-project-files)
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((emacs-lisp . t) (shell . t) (sql . t) (python . t))))

;; The single (optional) Org external package: a pure visual layer that pairs
;; with modus-themes.  Drop it anytime — nothing else depends on it.
(use-package org-modern
  :ensure t
  :hook (org-mode . org-modern-mode)
  :custom
  (org-modern-hide-stars 'leading)            ; hide leading stars; one bullet per heading
  ;; Replace heading stars with org-modern's classic bullets (◉○◈◇✳).
  ;; Well-supported glyphs — avoids the missing-glyph box the default fold
  ;; triangles produced at level 3 (U+2BC8/U+2BC6).
  (org-modern-star 'replace)
  (org-modern-replace-stars "◉○◈◇✳"))

;; Hide :PROPERTIES:/:LOGBOOK: drawers behind a small inline marker; they
;; reveal automatically when the cursor enters them.  Cleaner than native
;; folding (no leftover `:PROPERTIES:...' line).  Toggle: M-x org-tidy-toggle.
(use-package org-tidy
  :ensure t
  :hook (org-mode . org-tidy-mode)
  :custom
  (org-tidy-properties-style 'inline)        ; small ♯ marker, not the contents
  (org-tidy-properties-inline-symbol "♯")
  (org-tidy-top-property-style 'invisible)    ; fully hide the file-level drawer
  (org-tidy-property-drawer-flag t)           ; tidy :PROPERTIES:
  (org-tidy-general-drawer-flag t)            ; tidy :LOGBOOK: / :CLOCK: too
  (org-tidy-protect-overlay t))

(use-package autorevert
  :hook (after-init . global-auto-revert-mode)
  :custom
  (global-auto-revert-non-file-buffers t)
  (auto-revert-verbose nil)
  (auto-revert-avoid-polling t))

(use-package so-long
  :hook (after-init . global-so-long-mode))

(use-package outline
  :delight outline-minor-mode
  :custom
  (outline-minor-mode-cycle t))

(use-package browse-url
  :custom
  ;; Open links in the system default browser (via `xdg-open' / the XDG
  ;; handler).  eww stays a keystroke away via `M-x eww' /
  ;; `M-x eww-browse-url'.
  (browse-url-browser-function #'browse-url-default-browser)
  ;; …and eww is the "secondary" browser, so anything offering an alternate-
  ;; browser action (eww `&', elfeed, gnus, …) routes there.
  (browse-url-secondary-browser-function #'eww-browse-url))

(use-package goto-addr
  :hook ((prog-mode . goto-address-prog-mode)
         (text-mode . goto-address-mode)))

(use-package repeat
  :hook (after-init . repeat-mode))

(use-package isearch
  :bind ( :map isearch-mode-map
          ;; <backspace> deletes one char from the search string (what
          ;; every other tool does) instead of Emacs's default "undo
          ;; last search step".
          ("<backspace>" . isearch-del-char)
          ;; <left>/<right> while searching → open the search string in
          ;; the minibuffer for editing (default exits isearch).
          ("<left>"  . isearch-edit-string)
          ("<right>" . isearch-edit-string)
          :map minibuffer-local-isearch-map
          ;; In that edit minibuffer, restore normal cursor movement.
          ("<left>"  . backward-char)
          ("<right>" . forward-char))
  :custom
  (isearch-lazy-count t)
  (isearch-allow-motion t)
  (isearch-allow-scroll t)
  (search-whitespace-regexp ".*?")
  (isearch-wrap-pause 'no-ding))

;; (use-package page
  ;; I often input C-x C-p instead of C-x p followed by project
  ;; key, deleting contents of whole buffer as a result.
  ;; :bind ("C-x C-p" . nil))

(use-package indirect-narrow
  :bind ( :map narrow-map
          ("i n" . indirect-narrow-to-region)
          ("i d" . indirect-narrow-to-defun)
          ("i p" . indirect-narrow-to-page))
  :preface
  (defun indirect-narrow-to-region (start end)
    (interactive "r")
    (deactivate-mark)
    (with-current-buffer (clone-indirect-buffer nil nil)
      (narrow-to-region start end)
      (pop-to-buffer (current-buffer))))
  (defun indirect-narrow-to-page (&optional arg)
    (interactive "P")
    (deactivate-mark)
    (with-current-buffer (clone-indirect-buffer nil nil)
      (narrow-to-page arg)
      (pop-to-buffer (current-buffer))))
  (defun indirect-narrow-to-defun (&optional include-comments)
    (interactive (list narrow-to-defun-include-comments))
    (deactivate-mark)
    (with-current-buffer (clone-indirect-buffer nil nil)
      (narrow-to-defun include-comments)
      (pop-to-buffer (current-buffer))))
  (provide 'indirect-narrow))

(use-package vertico
  :ensure t
  :bind ( :map vertico-map
          ("M-RET" . vertico-exit-input))
  :hook (after-init . vertico-mode))

(use-package vertico-directory
  :after vertico
  :bind ( :map vertico-map
          ("RET" . vertico-directory-enter)
          ("DEL" . vertico-directory-delete-char)
          ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package nerd-icons-completion
  :ensure t
  ;; Adds nerd-font icons to vertico minibuffer candidates by hooking
  ;; into marginalia's annotation pipeline. Must load after marginalia
  ;; or `nerd-icons-completion-marginalia-setup' is a no-op.
  :after marginalia
  :config
  (nerd-icons-completion-mode)
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

(use-package marginalia
  :ensure t
  :hook (after-init . marginalia-mode))

(use-package consult
  :ensure t
  :commands (consult-completion-in-region)
  :preface
  (defvar consult-prefix-map (make-sparse-keymap))
  (fset 'consult-prefix-map consult-prefix-map)
  :bind ( :map ctl-x-map
          ("c" . consult-prefix-map)
          :map consult-prefix-map
          ("r" . consult-recent-file))
  :custom
  (consult-preview-key nil)
  :init
  (setq completion-in-region-function #'consult-completion-in-region))

(use-package embark
  :ensure t
  :bind (("C-."   . embark-act)
         ("C-;"   . embark-dwim)
         ("C-h B" . embark-bindings)))

(use-package embark-consult
  :ensure t
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

(use-package wgrep
  :ensure t
  ;; Make a grep/consult-ripgrep results buffer editable: `embark-export' a
  ;; `consult-ripgrep' (or `C-x p g') search to a grep buffer, hit `C-c C-p',
  ;; edit matches in place, `C-c C-c' to apply across the project.
  :bind ( :map grep-mode-map
          ("C-c C-p" . wgrep-change-to-wgrep-mode))
  :custom
  (wgrep-auto-save-buffer t))   ; save touched files automatically on apply

(use-package corfu
  :ensure t
  :bind ( :map corfu-map
          ("TAB" . corfu-next)
          ([tab] . corfu-next)
          ("S-TAB" . corfu-previous)
          ([backtab] . corfu-previous)
          ([remap completion-at-point] . corfu-complete)
          ("RET" . corfu-complete-and-quit)
          ("<return>" . corfu-complete-and-quit))
  :commands (corfu-quit)
  :custom
  (corfu-cycle t)
  (corfu-preselect-first t)
  (corfu-scroll-margin 4)
  (corfu-quit-no-match t)
  (corfu-quit-at-boundary t)
  (corfu-max-width 100)
  (corfu-min-width 42)
  (corfu-count 9)
  ;; should be configured in the `indent' package, but `indent.el'
  ;; doesn't provide the `indent' feature.
  (tab-always-indent 'complete)
  :config
  (defun corfu-complete-and-quit ()
    (interactive)
    (corfu-complete)
    (corfu-quit))
  :hook (after-init . global-corfu-mode))

(use-package corfu-popupinfo
  :bind ( :map corfu-popupinfo-map
          ("M-p" . corfu-popupinfo-scroll-down)
          ("M-n" . corfu-popupinfo-scroll-up))
  :hook (corfu-mode . corfu-popupinfo-mode)
  :custom-face
  (corfu-popupinfo ((t :height 1.0))))

(use-package nerd-icons-corfu
  :ensure t
  ;; Adds kind/category icons to corfu candidates (functions, vars,
  ;; keywords, snippets, files…) via the `margin-formatters' hook
  ;; corfu exposes. No advice, no remapping — corfu calls it during
  ;; render so disabling corfu disables this transparently.
  :after corfu
  :config
  (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

;; (use-package corfu-terminal
;;  :ensure t
;;  :when (and (not (display-graphic-p))
;;             (version< emacs-version "31"))
;;  :hook after-init)

(use-package cape
  :ensure t
  :after corfu
  :config
  (setq completion-at-point-functions '(cape-file)))

(use-package avy
  :ensure t
  :bind (("C-:"   . avy-goto-char-timer)
         ("M-g g" . avy-goto-line)))

;; kao — faithful Kakoune modal-editing engine. Normal/insert states, native
;; multi-selection, text objects, and registers. This supersedes the editing
;; cluster that used to live here (multiple-cursors + multiple-cursors-core,
;; phi-search, region-bindings + its keep/flush bindings, and expand-region) —
;; all removed in favour of kao's native selection model. kao-global-mode is
;; the autoloaded globalized entry; it already excludes the minibuffer,
;; special/derived buffers, and terminals (ghostel) from modal editing.
(use-package kao
  :vc (:url "https://github.com/saifulapm/kao" :rev :last-release)
  :demand t
  :config
  ;; --- System clipboard ----------------------------------------------------
  ;; kao's y / d / c / p ride the kill-ring; syncing the kill-ring with the
  ;; Wayland clipboard makes every kao yank/paste use the system clipboard,
  ;; shared with every other app in the session.
  (setq select-enable-clipboard t)

  ;; --- gw : jump to a word with avy (Kakoune `gw' = hop-kak-words) ---------
  ;; kao 1.0 exposes `kao-goto-define' (KEY KIND PAYLOAD DOC) as the public
  ;; registrar for the `g'/`G' menu — it upserts the spec row and its autoinfo
  ;; row together, so no more reaching into `kao--goto-specs'/`kao--goto-info'.
  ;; `gw' runs avy then collapses the selection onto the landing point: kao's
  ;; `g' dispatch is exempt from the avy-aware foreign-sync, so the jump must be
  ;; adopted here or the post-command mirror snaps point back.
  (defun my/kao-goto-word ()
    "Jump to a word with avy, then collapse the kao selection there (`gw')."
    (interactive)
    (avy-goto-word-0 nil)
    (when (kao-normal-state-p)
      (kao-set-selections
       (list (kao-sel-make :anchor (point) :cursor (point))))))
  (kao-goto-define ?w 'command #'my/kao-goto-word "avy word")

  ;; --- gd/gr/gy : kakoune-lsp goto bindings on kao's `g' menu ----------------
  ;; Faithful to kakoune-lsp (`gd' definition, `gr' references, `gy' type-def).
  ;; kao's `g' dispatch is exempt from foreign-sync (the same reason `gw' above
  ;; collapses by hand), so each wrapper adopts the jump via `kao-set-selections'
  ;; or the post-command mirror snaps point back.  `kao-goto-define' upserts, so
  ;; `gd' cleanly OVERRIDES kao's display-line-down motion (same key, spec+info
  ;; replaced atomically); `gu' still does prev-display-line.  `gr'/`gy' are free
  ;; goto keys.
  (defun my/kao-goto--jump (command)
    "Push a kao jump for the pre-jump position, run COMMAND, then collapse.
The jump push is what makes kao's `C-o' (`kao-jump-backward') return here:
xref pushes only its OWN marker stack (recoverable with `M-,'), NOT kao's jump
list, so a SAME-buffer definition would otherwise leave nothing for `C-o' to
walk back to.  kao 1.0's `command'-kind goto dispatch now auto-pushes a jump
when the command switches BUFFER (kao-menu.el, D-99), so on a cross-file jump
this push is redundant — but `kao-jump-push' dedupes an identical (buffer,
selections) entry, so the overlap is harmless while the push still covers the
same-buffer case.  Faithful to Kakoune+kakoune-lsp, where `gd' is a push_jump."
    (when (kao-normal-state-p)
      (kao-jump-push))
    (call-interactively command)
    (when (kao-normal-state-p)
      (kao-set-selections
       (list (kao-sel-make :anchor (point) :cursor (point))))))
  (defun my/kao-goto-definition ()
    "Go to definition, collapsing the selection (`gd')."
    (interactive) (my/kao-goto--jump #'xref-find-definitions))
  (defun my/kao-goto-references ()
    "List references, collapsing the selection (`gr')."
    (interactive) (my/kao-goto--jump #'xref-find-references))
  (defun my/kao-goto-type-definition ()
    "Go to type definition, collapsing the selection (`gy')."
    (interactive) (my/kao-goto--jump #'eglot-find-typeDefinition))
  (kao-goto-define ?d 'command #'my/kao-goto-definition      "definition")
  (kao-goto-define ?r 'command #'my/kao-goto-references      "references")
  (kao-goto-define ?y 'command #'my/kao-goto-type-definition "type definition")

  ;; --- vs : select the visible part of the buffer -------------------------
  ;; Kakoune's `select-view' (bound `v s'): there it zeroes scrolloff then
  ;; `gtGbGl' (window-top -> extend window-bottom -> extend line-end).  Here we
  ;; just span window-start..end-of-last-visible-line as one selection.  kao 1.0
  ;; exposes `kao-view-define' (KEY FN DOC) as the public registrar for the
  ;; `v'/`V' menu (upserting table + autoinfo together); FN is called with the
  ;; count, so the fn takes an ignored arg.  The menu only fires in the displayed
  ;; buffer, so window-start/-end are always live — no displayed-p guard needed.
  (defun my/kao-select-view (&optional _n)
    "Select the visible part of the buffer (Kakoune `select-view', `v s').
Anchored at the first visible line; the cursor lands on the last FULLY
visible line so the window does not scroll.  `window-end' counts a
partially-visible bottom line, and mirroring the cursor onto it would pull
point — and the view — down a line, so back up to the last whole line."
    (interactive)
    (let* ((beg (window-start))
           (cursor
            (save-excursion
              (goto-char (min (point-max) (max beg (1- (window-end nil t)))))
              (while (and (> (line-beginning-position) beg)
                          (not (pos-visible-in-window-p (line-end-position))))
                (forward-line -1))
              (line-end-position))))
      (kao-set-selections
       (list (kao-sel-make :anchor beg :cursor cursor)))))
  (kao-view-define ?s #'my/kao-select-view "select visible region")

  ;; --- SPC , = buffers, SPC SPC = files (project-aware) -------------------
  ;; Kakoune's `SPC ,' (buffer picker) and `SPC <space>' (file picker).  In a
  ;; project narrow to it; otherwise the global commands.  Bound directly on the
  ;; user map, so `this-command' is the finder itself and kao's foreign-sync
  ;; adopts the buffer/file switch (same as the built-in `SPC d' = xref).
  (defun my/kao-find-buffer ()
    "Project buffers when in a project, else all buffers (Kakoune `SPC ,')."
    (interactive)
    (if (project-current) (consult-project-buffer) (consult-buffer)))
  (defun my/kao-find-file ()
    "Project files when in a project, else `find-file' (Kakoune `SPC SPC')."
    (interactive)
    (if (project-current) (project-find-file) (call-interactively #'find-file)))
  (defun my/kao-find-dired ()
    "Dired the project root when in a project, else `dired' (Kakoune `SPC e')."
    (interactive)
    (if (project-current) (project-dired) (call-interactively #'dired)))
  (define-key kao-user-map "," #'my/kao-find-buffer)
  (define-key kao-user-map (kbd "SPC") #'my/kao-find-file)
  (define-key kao-user-map "e" #'my/kao-find-dired)
  ;; `SPC /' = project-wide live grep (Kakoune `SPC /' = live-grep).  consult-
  ;; ripgrep searches the project root when in one, else `default-directory'; a
  ;; prefix arg prompts for the directory.  Kakoune's `SPC \\' (sk-live-grep) is
  ;; the same job via another front-end, so it folds into this one key.
  (define-key kao-user-map "/" #'consult-ripgrep)

  ;; --- SPC w = window sub-menu (ports my Kakoune `window' user-mode) ----------
  ;; Kakoune maps `SPC w' to the windowing user-mode (window-ghostty/window-tmux):
  ;; `h/l/k/j' move between panes, `s'/`v' split, `q' close.  Here the same keys
  ;; drive Emacs windows (windmove + split/delete).  This frees the leader's
  ;; `h/j/k/l' — they used to be direct windmove binds, with `SPC l' = windmove-
  ;; right — so `SPC l' can now host the LSP menu below, matching kak's `SPC l' =
  ;; lsp.  windmove still lives on `S-<arrow>' too (see its package block); window
  ;; selection/splits are foreign commands kao's post-command sync adopts, so
  ;; plain binds suffice.  Q/o/= are Emacs-natural bonuses (no kak analogue).
  (defvar-keymap my/kao-window-map
    :doc "Window commands, Kakoune-windowing-style (`SPC w')."
    "h" #'windmove-left                  ; move left  (kak `h')
    "j" #'windmove-down                  ; move down  (kak `j')
    "k" #'windmove-up                    ; move up    (kak `k')
    "l" #'windmove-right                 ; move right (kak `l')
    "s" #'split-window-below             ; horizontal split (kak `s')
    "v" #'split-window-right             ; vertical split   (kak `v')
    "q" #'delete-window                  ; close this window (kak `q')
    "Q" #'delete-other-windows           ; close the others (maximize)
    "o" #'other-window                   ; cycle to next window
    "=" #'balance-windows)               ; equalize window sizes
  (define-key kao-user-map "w" `(menu-item "window" ,my/kao-window-map))

  ;; --- SPC b = buffers sub-menu (ports my Kakoune `buffers' user-mode) --------
  ;; A prefix keymap on the kao leader; which-key renders it as a labelled popup,
  ;; the Emacs analog of Kakoune's user-mode menu.  `D'/`o' act on file-visiting
  ;; buffers only, so they spare *scratch*/*Messages*/dired/magit/ghostel, and
  ;; `kill-buffer' still prompts before discarding any unsaved file.
  (defun my/kao-kill-file-buffers ()
    "Kill all file-visiting buffers (Kakoune `SPC b D')."
    (interactive)
    (when (yes-or-no-p "Kill all file buffers? ")
      (let ((n 0))
        (dolist (buf (buffer-list))
          (when (and (buffer-file-name buf) (kill-buffer buf))
            (setq n (1+ n))))
        (message "Killed %d file buffer(s)" n))))
  (defun my/kao-kill-other-buffers ()
    "Kill all OTHER file-visiting buffers, keeping the current one (Kakoune `SPC b o')."
    (interactive)
    (when (yes-or-no-p "Kill other file buffers? ")
      (let ((cur (current-buffer)) (n 0))
        (dolist (buf (buffer-list))
          (when (and (buffer-file-name buf) (not (eq buf cur)) (kill-buffer buf))
            (setq n (1+ n))))
        (message "Killed %d other file buffer(s)" n))))
  (defvar-keymap my/kao-buffer-map
    :doc "Buffer commands, Kakoune-style (`SPC b')."
    "a" #'mode-line-other-buffer       ; alternate ↔ (last buffer)
    "b" #'consult-buffer               ; switch / find
    "n" #'next-buffer                  ; next →
    "p" #'previous-buffer              ; previous ←
    "d" #'kill-current-buffer          ; delete
    "r" #'rename-buffer                ; rename
    "s" #'scratch-buffer               ; *scratch*
    "u" #'view-echo-area-messages      ; *Messages* (Emacs' *debug*)
    "i" #'ibuffer                      ; rich list
    "c" #'gptel                        ; AI chat
    "D" #'my/kao-kill-file-buffers     ; delete all (file buffers)
    "o" #'my/kao-kill-other-buffers)   ; delete others (file buffers)
  (define-key kao-user-map "b" `(menu-item "buffers" ,my/kao-buffer-map))

  ;; --- SPC l = LSP sub-menu (ports kakoune-lsp's `lsp' user-mode) -------------
  ;; Faithful to kakoune-lsp, which maps `SPC l' to the `lsp' user-mode (my kak
  ;; `map global user l :enter-user-mode lsp').  Now reachable on `SPC l' since
  ;; window movement moved to the `SPC w' menu above.  `d'/`r' duplicate kao's
  ;; built-in `SPC d'/`SPC r' (xref, from `kao-keys-user-alist') for a self-
  ;; contained menu.  Dropped from kak's table: j/k call-hierarchy, l code-lens,
  ;; v selection-range (no eglot equivalent).  X/Q are bonus server-control keys.
  (defvar-keymap my/kao-lsp-map
    :doc "LSP commands, Kakoune-lsp-style (`SPC l')."
    "a" #'eglot-code-actions          ; code actions
    "d" #'xref-find-definitions       ; definition (also SPC d)
    "r" #'xref-find-references        ; references (also SPC r)
    "i" #'eglot-find-implementation   ; implementation
    "y" #'eglot-find-typeDefinition   ; type definition
    "R" #'eglot-rename                ; rename
    "f" #'eglot-format                ; format (region or buffer)
    "h" #'eldoc-doc-buffer            ; hover
    "s" #'consult-imenu               ; document symbols
    "o" #'consult-eglot-symbols       ; workspace symbols
    "e" #'consult-flymake             ; diagnostics list
    "n" #'flymake-goto-next-error     ; next error
    "p" #'flymake-goto-prev-error     ; prev error
    "X" #'eglot-reconnect             ; restart server
    "Q" #'eglot-shutdown)             ; shutdown server
  (define-key kao-user-map "l" `(menu-item "lsp" ,my/kao-lsp-map))

  ;; --- SPC f = files / find sub-menu (ports my Kakoune `picker' user-mode) ----
  ;; Kakoune's picker mode is many fuzzy-finder front-ends (fzf/sk/zf/swiper/lf)
  ;; for the same jobs; here they collapse into consult, plus the file operations
  ;; a files menu wants.  `y' reuses `my/project-copy-relative-path' (project block).
  (defun my/find-changed-file ()
    "Pick a git-changed (modified or untracked) file in the repo and open it.
Ports Kakoune's `open_changed_file_picker' (`SPC f m')."
    (interactive)
    (let* ((root (or (vc-root-dir) (user-error "Not inside a Git repository")))
           (default-directory root)
           (files (delete-dups
                   (split-string
                    (shell-command-to-string
                     "git diff --name-only HEAD; git ls-files --others --exclude-standard")
                    "\n" t))))
      (unless files (user-error "No changed files"))
      (find-file (expand-file-name (completing-read "Changed file: " files nil t) root))))
  (defun my/delete-file-and-buffer ()
    "Delete the current file (to trash) and kill its buffer (`SPC f D')."
    (interactive)
    (let ((file (buffer-file-name)))
      (unless file (user-error "Buffer is not visiting a file"))
      (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name file)))
        (delete-file file t)
        (kill-buffer)
        (message "Deleted %s" (abbreviate-file-name file)))))
  (defun my/find-org-file ()
    "Pick and open an Org file from `org-directory' (recursively, `SPC f o').
Excludes .org_archive and backups.  Modeled on Prot's `prot-org-file-prompt'."
    (interactive)
    (require 'org)                         ; ensure `org-directory' is set
    (let* ((dir (expand-file-name org-directory))
           (files (seq-remove #'backup-file-name-p
                              (directory-files-recursively dir "\\.org\\'" nil)))
           (names (mapcar (lambda (f) (file-relative-name f dir)) files)))
      (unless names (user-error "No Org files in %s" dir))
      (find-file (expand-file-name (completing-read "Org file: " names nil t) dir))))
  (defvar-keymap my/kao-file-map
    :doc "File / find commands, Kakoune-picker-style (`SPC f')."
    "f" #'find-file                      ; find file
    "p" #'project-find-file              ; project file picker
    "o" #'my/find-org-file               ; org file picker (org-directory)
    "r" #'consult-recent-file            ; recent files
    "l" #'consult-line                   ; line picker
    "g" #'consult-ripgrep                ; grep project
    "e" #'dired-jump                     ; explorer (dired here)
    "m" #'my/find-changed-file           ; git-changed file
    "s" #'save-buffer                    ; save
    "S" #'save-some-buffers              ; save all
    "R" #'rename-visited-file            ; rename current file
    "D" #'my/delete-file-and-buffer      ; delete current file
    "y" #'my/project-copy-relative-path) ; copy file path
  (define-key kao-user-map "f" `(menu-item "files" ,my/kao-file-map))

  ;; `:' = eval-expression (Emacs `M-:').  kao rebinds `M-:' to Kakoune's `<a-:>'
  ;; (kao-ensure-forward), which shadows the stock eval-expression; reclaim it on
  ;; `:' (Kakoune's `:' is its command prompt, so this is the natural home).
  (define-key kao-normal-state-map (kbd ":") #'eval-expression)

  ;; --- Opt-in modules: kao-vundo (history-tree) + kao-objects (tag) + kao-surround ---
  ;; kao-vundo visualizes kao's OWN buffer-history TREE (the u/U/<c-j>/<c-k>
  ;; walk) and navigates it live.  `SPC v' opens it; inside: f/b = newer/older,
  ;; n/p = sibling branches, C-n/C-p browse without changing the buffer,
  ;; d = diff of the node at point, RET = jump there, g/q = refresh/quit.
  ;; Bound on the user map, NOT on `U' (that is kao-redo).  kao-objects adds the
  ;; HTML/XML `tag' object on `<a-i>T'/`<a-a>T'.  Both requires are guarded so a
  ;; not-yet-upgraded kao package cannot break init — `M-x package-vc-upgrade RET
  ;; kao' pulls a build that ships kao-vundo (kao-objects is already present).
  (when (require 'kao-vundo nil t)
    (define-key kao-user-map "v" #'kao-vundo))
  (when (require 'kao-objects nil t)
    (kao-objects-register-tag))
  ;; kao-surround ports my kak `match'/`surround-add' user-modes onto kao's
  ;; public config substrate.  `m' enters match mode: `m m' goto-match, `m i'/
  ;; `m a' inner/whole object, `m s KEY' wraps each selection with the KEY pair,
  ;; `m d KEY' deletes the surrounding pair, `m r OLD NEW' replaces it -- so the
  ;; plain `m' now lives on `m m'.  Delete/replace find the ENCLOSING pair via
  ;; the object system, so they work from anywhere inside it (multi-char tags
  ;; included).  Arg t enables the tree-sitter layer (I use *-ts-mode widely):
  ;; `m d t'/`m r t' target the syntax element in html/jsx/tsx and `m n' selects
  ;; (and, repeated, grows over) the enclosing named node; it falls back to the
  ;; regex tag in non-tree-sitter buffers.  Guarded like the modules above.
  (when (require 'kao-surround nil t)
    (kao-surround-setup t))
  ;; kao-treesit — Helix-style tree-sitter text objects + syntax-aware tree
  ;; motions (I use *-ts-mode widely).  Pin the query path to my kak runtime
  ;; corpus: the ~/.config/helix symlink is sparse, the kak runtime is the full
  ;; version-proof set (config-first, so my own overrides still win).  Arg t
  ;; binds the `SPC t' tree menu (object select f/F c/C a/A o T; motions
  ;; s P i ] [ n p; e/E expand-shrink, also top-level `<a-RET>'/`<a-S-RET>';
  ;; `*' `/' `?' `t' = all-functions / filter / scopes / explore) AND the
  ;; object-pending keys `<a-{a,i,A}>f' (function) + augmented `<a-{a,i,A}>u'
  ;; (parameter, falling back to the regex argument object).  Gated on a loaded
  ;; parser; degrades to the regex objects.  Guarded like the modules above (run
  ;; `M-x package-vc-upgrade RET kao' to pull a build that ships kao-treesit).
  (when (require 'kao-treesit nil t)
    (setq kao-treesit-queries-dir
          '("~/.config/helix/runtime/queries"
            "~/.local/share/kak/queries"))
    (kao-treesit-setup t))
  ;; --- Org tweaks for kao normal state (via the public per-mode `kao-define-key'
  ;;     seam, which shadows `kao-normal-state-map' in org buffers) ---
  ;; (1) TAB/S-TAB fold like Org.  TAB needs reclaiming because kao's faithful
  ;;     `C-i'=`kao-jump-forward' captures it (TAB == C-i); `<backtab>' (what
  ;;     S-TAB sends) already falls through but is bound here too, one place.
  ;; (2) h/j/k/l move like NATIVE Emacs (backward-char/next-line/previous-line/
  ;;     forward-char) when there is a SINGLE selection -- so Org's visual-line +
  ;;     folding navigation feels native -- while keeping kao's multi-cursor
  ;;     motions when several selections are live.  Tagging `this-command' lets
  ;;     kao's foreign-sync reconcile: collapse-to-point for the native command,
  ;;     exempt (preserve the multi-selection) for the `kao-' motion.
  (defun my/kao-native-or-motion (native motion)
    "Run NATIVE on a single kao selection, else the kao MOTION; tag `this-command'."
    (let ((cmd (if (= 1 (length (kao-get-selections))) native motion)))
      (setq this-command cmd)
      (call-interactively cmd)))
  (defun my/kao-org-left  () (interactive) (my/kao-native-or-motion #'backward-char  #'kao-left))
  (defun my/kao-org-right () (interactive) (my/kao-native-or-motion #'forward-char   #'kao-right))
  (defun my/kao-org-down  () (interactive) (my/kao-native-or-motion #'next-line      #'kao-down))
  (defun my/kao-org-up    () (interactive) (my/kao-native-or-motion #'previous-line  #'kao-up))
  (kao-define-key 'org-mode
                  (kbd "TAB")       #'org-cycle
                  (kbd "<backtab>") #'org-shifttab
                  (kbd "h") #'my/kao-org-left
                  (kbd "l") #'my/kao-org-right
                  (kbd "j") #'my/kao-org-down
                  (kbd "k") #'my/kao-org-up)

  (kao-global-mode 1))

(use-package orderless
  :ensure t
  :defer t
  :custom
  (completion-category-overrides
   '((file (styles basic partial-completion)))))

(use-package elfeed
  :ensure t
	:commands (elfeed elfeed-update elfeed-search-bookmark-handler)
	:preface
  (setq elfeed-feeds
        '(("https://nullprogram.com/feed/" blog emacs)
          ("https://nedroid.com/feed/" webcomic)
          ;; YouTube channels (RSS via channel_id)
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCbRP3c757lWg9M-U7TyEkXA" youtube webdev) ; t3dotgg
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCswG6FSbgZjbWtdf_hMLaow" youtube typescript ai) ; mattpocockuk
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCUbtdbJRpaXiUI_IlBOvPpA" youtube politics bangla) ; PinakiBhattacharya
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCelfWQr9sXVMTvBzviPGlFw" youtube ai) ; AILABS-393
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC0uTPqBCFIpZxlz_Lv1tk_g" youtube emacs) ; protesilaos
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCwXdFgeE9KYzlDdR7TG9cMw" youtube flutter) ; flutterdev
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCLKPca3kwwd-B59HNr-_lvA" youtube ai) ; aiDotEngineer
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCJvXIbdkzLzLNQNaTL6EgbQ" youtube entertainment bangla) ; KothaHokOhetuk
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCXUPKJO5MZQN11PqgIvyuvQ" youtube ai) ; AndrejKarpathy
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA" youtube webdev) ; Fireship
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCYeiozh-4QwuC1sjgCmB92w" youtube devops) ; devopstoolbox
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCbh_g91w0T6OYp40xFrtnhA" youtube emacs) ; karthink
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC1HNvqTpK24NjOh6VsHxdfw" youtube emacs) ; xenodium
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC1hOCRBN2mnXgN5reSoO3pQ" youtube react) ; ReactConfOfficial
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UClURnTgQiQpldGhtD4Fc7JQ" youtube politics) ; EliasHossain
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCbzoLT8wqhI3iOAz1Nq0pvw" youtube webdev) ; antfu
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCH7Ulw-HEr62_SUzCC9K8oQ" youtube webdev) ; andrew-burgess
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCFM3gG5IHfogarxlKcIHCAg" youtube webdev bangla) ; LearnwithSumit
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC1irENajwVYATt9hf5rfWRQ" youtube webdev) ; rich_harris
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCLLVlcmcCP4CUe7xSqVEnxw" youtube webdev) ; ryansolid
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC2Xd-TjJByJyK2w1zNwY0zQ" youtube webdev) ; beyondfireship
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UC-2Y8dQb0S6DtpxNgAKoJKA" youtube gaming) ; PlayStation
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCO_hYZF2gb_CyG5sA7ArlGg" youtube php) ; nunomaduro
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCb-d2dCbEt_T-d3qf3oMICw" youtube bangla) ; iamkhalidfarhan
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCeiAKuJGZrIjYvaq0nMwbJg" youtube entertainment hindi) ; FilmiIndian
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCPWqbr91cfbtLHZrHM5GItg" youtube entertainment hindi) ; ABHIKAREVIEW
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCyNJTXvvD-1gWzjC59Oc_Mg" youtube entertainment bangla) ; PlabonWorld
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCXzR5V9OMvhfoZPPv8g-VCw" youtube entertainment bangla) ; Achirar_goppo_shoppo
          ("https://www.youtube.com/feeds/videos.xml?channel_id=UCjqJ_NnTvCJFAXmLWntHgFg" youtube entertainment bangla))) ; faporbaz_fun
	:config
	(setq-default elfeed-db-directory (expand-file-name "elfeed" user-cache-directory)
								elfeed-save-multiple-enclosures-without-asking t
								elfeed-search-clipboard-type 'CLIPBOARD
								elfeed-use-curl nil
								elfeed-search-filter "#50 +unread "
								elfeed-search-date-format '("%Y-%m-%d" 10 :left) ;;'("%b %d" 6 :left)
								elfeed-search-title-min-width 45))

(use-package elfeed-tube
  :ensure t
  :after elfeed
  :demand t
  :config
  ;; (setq elfeed-tube-auto-save-p nil) ; default value
  ;; (setq elfeed-tube-auto-fetch-p t)  ; default value
  (elfeed-tube-setup)
  :bind ( :map elfeed-show-mode-map
          ("F" . elfeed-tube-fetch)
          ([remap save-buffer] . elfeed-tube-save)
          :map elfeed-search-mode-map
          ("F" . elfeed-tube-fetch)
          ([remap save-buffer] . elfeed-tube-save)))

;; Emacs mpv library, needed for "live" transcript tracking in elfeed-tube-mpv
(use-package mpv
  :ensure t
  :defer t)

(use-package elfeed-tube-mpv
  :ensure t
  :after elfeed-tube
  :bind ( :map elfeed-show-mode-map
          ("C-c C-f" . elfeed-tube-mpv-follow-mode)
          ("C-c C-w" . elfeed-tube-mpv-where)))

(use-package yeetube
  :ensure t
  :bind ("C-c y" . #'yeetube))

(use-package project
  :bind ( :map project-prefix-map
          ("b" . consult-project-buffer)   ; was: project-switch-to-buffer
          ("g" . consult-ripgrep)          ; was: project-find-regexp
          ("m" . magit-project-status)     ; was: unbound
          ("w" . my/project-copy-relative-path))
  :preface
  ;; Declare special so the let in `save-project-buffers-only' is dynamic
  ;; (else the byte-compiler makes it lexical and the binding does nothing).
  (defvar compilation-save-buffers-predicate)
  (defun my/project-copy-relative-path ()
    "Copy the current file's path, relative to its project root, to the kill ring.
Falls back to the abbreviated absolute path when the file isn't in a project."
    (interactive)
    (if-let* ((file (buffer-file-name)))
        (let* ((proj (project-current nil (file-name-directory file)))
               (path (if proj
                         (file-relative-name file (project-root proj))
                       (abbreviate-file-name file))))
          (kill-new path)
          (message "Copied: %s" path))
      (user-error "Buffer is not visiting a file")))
  :custom
  ;; Treat each git submodule as its own project.
  (project-vc-merge-submodules nil)
  ;; Drop an empty `.project' file to mark a non-git dir as a project root.
  ;; Deliberately NOT package.json/composer.json: every nested node_modules /
  ;; vendor sub-package has one, which would fragment projects.  `.git' already
  ;; roots my theme/React/Laravel repos correctly.
  (project-vc-extra-root-markers '(".project"))
  ;; Per-project compilation buffers, e.g. `*toughon-compilation*'.
  (project-compilation-buffer-name-function #'project-prefixed-buffer-name)
  ;; Labeled `C-x p p' switch menu; keys match the `project-prefix-map' rebinds
  ;; above.  `Other…' (o) escapes to ANY project command (kill, replace, shell).
  ;; (Preferred over `project-switch-use-entire-map', which shows only a bare,
  ;; unlabeled key list.)
  (project-switch-commands
   '((project-find-file      "Find file" ?f)
     (consult-ripgrep        "Search"    ?g)
     (consult-project-buffer "Buffer"    ?b)
     (project-dired          "Dired"     ?d)
     (magit-project-status   "Magit"     ?m)
     (project-compile        "Compile"   ?c)
     (project-eshell         "Eshell"    ?e)
     (project-any-command    "Other…"    ?o)))
  :config
  ;; Before `C-x p c', only prompt to save THIS project's modified buffers,
  ;; not every buffer in Emacs (handy with several projects open).
  (define-advice project-compile (:around (fn) save-project-buffers-only)
    "Only prompt to save the current project's buffers before compiling."
    (let* ((bufs (project-buffers (project-current)))
           (compilation-save-buffers-predicate
            (lambda () (memq (current-buffer) bufs))))
      (funcall fn)))
  ;; Auto-discover my projects so `C-x p p' lists them without visiting first
  ;; (the project.el answer to `projectile-project-search-path').  Non-recursive
  ;; — immediate children only — so it never crawls node_modules / vendor.
  (dolist (dir '("~/Sites/shopify_themes/" "~/Sites/react/" "~/Sites/laravel/"))
    (when (file-directory-p (expand-file-name dir))
      (project-remember-projects-under (expand-file-name dir)))))

(use-package ghostel
  :ensure t
  :preface
  (defun my/ghostel-new ()
    "Always open a fresh `*ghostel*' buffer (a new terminal \"tab\")."
    (interactive)
    (let ((current-prefix-arg '(4)))
      (call-interactively #'ghostel)))
  (defun my/ghostel-restore-line-spacing ()
    "Re-apply global `line-spacing' inside ghostel buffers.
`ghostel-mode' forces `line-spacing' to 0 so kitty graphics slices and
box-drawing glyphs tile flush; that diverges visually from eshell and
other buffers where the global cons/float value from `setup-fonts'
applies.  Restoring it here keeps row height consistent at the cost of
small gaps in inline images and TUI frames — accepted trade-off."
    (setq-local line-spacing
                (if (>= emacs-major-version 31) '(0.25 . 0.25) 0.5)))
  (defun my/ghostel-ensure-terminfo ()
    "Install ghostel's bundled `xterm-ghostty' terminfo into `~/.terminfo'.
The Emacs daemon builds `emacsclient -t' frames with TERM=xterm-ghostty but
runs without $TERMINFO, and Ghostty isn't installed system-wide here, so it
dies with \"Terminal type xterm-ghostty is not defined\".  ~/.terminfo is
searched via $HOME, so installing the entry there fixes it.  Idempotent — a
no-op once the entry exists or if `tic' is missing — so a fresh machine
self-heals on first run."
    (interactive)
    (unless (seq-some (lambda (d)
                        (file-exists-p
                         (expand-file-name (format "~/.terminfo/%s/xterm-ghostty" d))))
                      '("78" "x"))
      (let ((src (car (file-expand-wildcards
                       (expand-file-name
                        "ghostel-*/etc/terminfo/xterm-ghostty.terminfo"
                        package-user-dir)))))
        (when (and src (executable-find "tic"))
          (call-process "tic" nil nil nil "-x" "-o"
                        (expand-file-name "~/.terminfo") src)
          (message "ghostel: installed xterm-ghostty terminfo into ~/.terminfo")))))
  (defun my/ghostel-with-editor-setup ()
    "Make programs spawned inside a (local) ghostel use THIS Emacs as $EDITOR.
`ghostel-mode' is `fundamental-mode'-derived, so `with-editor-export-editor'
can't be hooked like shell/term/eshell/vterm.  ghostel exposes
`ghostel-pre-spawn-hook' for exactly this — it runs with `process-environment'
bound to the about-to-be-spawned child.  The CHANGELOG suggests a public
`with-editor-setup-environment' upstream never shipped, so we drive the internal
`with-editor--setup' with the env-var name bound.  Programs run in ghostel
\(Claude Code's Ctrl-G, git, …) then edit in a buffer of this Emacs; finish with
`C-x #'.  Skipped for remote/TRAMP ghostels, whose sleeping-editor path needs an
output filter ghostel doesn't provide (it would hang)."
    (when (and (not (file-remote-p default-directory))
               (require 'with-editor nil t))
      (let ((with-editor--envvar "EDITOR"))
        (with-editor--setup))
      (setenv "VISUAL" (getenv "EDITOR"))))
  :init
  ;; Self-provision the terminfo the daemon needs for `emacsclient -t' frames,
  ;; so a new machine just works — no manual `tic' step to remember.
  (my/ghostel-ensure-terminfo)
  :bind (("C-c t"   . ghostel)
         ("C-c T"   . ghostel-list-buffers)
         :map project-prefix-map
         ("t"       . ghostel-project)
         ("T"       . ghostel-project-list-buffers)
         :map ghostel-mode-map
         ;; Tab management, inside a ghostel buffer only.  These used to be the
         ;; Mac's `s-t' / `s-]' / `s-[' (cmd-T, cmd-], cmd-[); under niri the
         ;; compositor grabs Mod+T, Mod+[ and Mod+] before any client sees them,
         ;; so they live on the `C-c t' prefix instead.  Shadowing the global
         ;; `C-c t' (= `ghostel') here costs nothing — you are already in one,
         ;; and `C-c t n' makes another.
         ("C-c t n" . my/ghostel-new)        ; new tab
         ("C-c t ]" . ghostel-next)          ; next tab
         ("C-c t [" . ghostel-previous)      ; prev tab
         :map ghostel-semi-char-mode-map
         ;; Search the materialized scrollback (20MB, set below) from the DEFAULT
         ;; input mode; C-s otherwise forwards to the shell.  Applied after
         ;; ghostel loads (and after `ghostel--rebuild-semi-char-keymap'), so the
         ;; rebuild doesn't clobber it.
         ("C-s"     . consult-line))         ; fuzzy-search terminal history
  :hook (ghostel-mode . my/ghostel-restore-line-spacing)
  :custom
  ;; Silence OSC 9 / 777 desktop notifications — long-running commands in a
  ;; ghostel already show up in the buffer, and the banners just pile up in
  ;; the qshell notification list.
  (ghostel-notification-function nil)
  ;; Bigger scrollback — Claude Code sessions blow past the 5MB default.
  ;; Materialized into the buffer, so consult-line/isearch reach history.
  (ghostel-max-scrollback (* 20 1024 1024))   ; ~20k rows
  ;; Extend the `ghostel_cmd' whitelist with magit, so `ghostel_cmd magit'
  ;; from inside the terminal opens `magit-status' in Emacs.
  (ghostel-eval-cmds '(("find-file" find-file)
                       ("find-file-other-window" find-file-other-window)
                       ("dired" dired)
                       ("dired-other-window" dired-other-window)
                       ("magit" magit-status)
                       ("message" message)))
  ;; Let terminal programs (tmux, nvim, ssh, Claude Code) copy to the Wayland
  ;; clipboard via OSC 52.  ghostel writes it through `gui-set-selection
  ;; 'CLIPBOARD' (plus `kill-new'), so it reaches the real selection.  Off by
  ;; default for security: a rogue escape sequence in output could overwrite the
  ;; clipboard.
  (ghostel-enable-osc52 t)
  :config
  ;; Expose `ghostel-project' in the `C-x p p' dispatch menu.
  (add-to-list 'project-switch-commands '(ghostel-project "Ghostel" ?t) t)
  ;; `C-x p k' (project-kill-buffers) also closes this project's Ghostel
  ;; terminals — by default they survive (ghostel-mode derives fundamental-mode).
  (add-to-list 'project-kill-buffer-conditions '(derived-mode . ghostel-mode))
  ;; Programs run inside ghostel edit in THIS Emacs (see the defun above).
  (add-hook 'ghostel-pre-spawn-hook #'my/ghostel-with-editor-setup))

(use-package ghostel-eshell
  :hook (eshell-load . ghostel-eshell-visual-command-mode))

(use-package ghostel-compile
  :hook (after-init . ghostel-compile-global-mode))

;; ghostel-comint: swap comint's ANSI handling for the libghostty VT parser in
;; every comint buffer (M-x shell, REPLs, inferior processes) — truecolor,
;; clickable OSC 8 hyperlinks, OSC 7 directory tracking.  Does NOT render
;; cursor-addressing TUIs (htop/less); those still need `M-x ghostel'.  Sibling
;; of ghostel-compile above; autoloaded the same way, so this defers cleanly.
(use-package ghostel-comint
  :hook (after-init . ghostel-comint-global-mode))

;; Claude Code fleet indicator.  Each active project runs `claude agents
;; --cwd <root>' inside its project ghostel; with 6-7 projects live at once,
;; spotting a stopped agent means cycling s-[ / s-] through every terminal.
;; This polls the same data (`claude agents --json') on a timer instead and
;; renders one clickable glyph per active project into `global-mode-string'
;; (which `mode-line-misc-info' displays, right-aligned): a green spinner
;; while every agent works, a red ● (with a count) when any blocks on a
;; permission prompt or question.  Active means all of: the session has a
;; `pid' in the JSON (no pid = dead session from a long-closed project), it
;; is not idle (`status idle' = turn over, nothing running), and a ghostel
;; buffer lives under the project root (sessions running outside this Emacs
;; stay hidden).  Hover for the project path and
;; per-session states; mouse-1 jumps to that project's ghostel buffer,
;; spawning one when missing.  Sessions `run-tracks'
;; fans out into `<root>/.worktrees/<track>' collapse onto the root, so a
;; project stays one segment no matter how many tracks are building.
(use-package claude-agents
  :no-require
  :preface
  (defvar my/claude-agents-interval 10
    "Seconds between `claude agents --json' polls.
Each poll pays one Node CLI startup — async, so redisplay never blocks —
raise this if the background CPU bothers you.")
  (defvar my/claude-agents--timer nil)
  (defvar my/claude-agents--process nil)
  (defvar my/claude-agents--by-root nil
    "Last poll's background sessions, grouped (ROOT . SESSIONS) and sorted.")
  (defvar my/claude-agents--spinner ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
    "Braille spinner frames for projects whose agents are all working.")
  (defvar my/claude-agents--frame 0)
  (defvar my/claude-agents--anim-timer nil)
  (defvar my/claude-agents-mode-line-string nil
    "Rendered fleet segments, spliced into `global-mode-string'.")
  (put 'my/claude-agents-mode-line-string 'risky-local-variable t)
  (defun my/claude-agents--root (cwd)
    "Project root for a session CWD.
run-tracks spawns track sessions inside `<root>/.worktrees/<track>' git
worktrees; collapse those onto the root so the whole build renders as a
single segment."
    (if (string-match "\\`\\(.*?\\)/\\.worktrees/" cwd)
        (match-string 1 cwd)
      cwd))
  (defun my/claude-agents--ghostel-buffer (root)
    "Live ghostel buffer whose directory sits under ROOT, if any."
    (seq-find (lambda (buf)
                (with-current-buffer buf
                  (and (derived-mode-p 'ghostel-mode)
                       (not (file-remote-p default-directory))
                       (file-in-directory-p default-directory root))))
              (buffer-list)))
  (defun my/claude-agents-goto (root)
    "Switch to ROOT's ghostel buffer, spawning one there when none exists."
    (if-let* ((buf (my/claude-agents--ghostel-buffer root)))
        (pop-to-buffer-same-window buf)
      (let ((default-directory root))
        (ghostel-project))))
  (defun my/claude-agents--state (session)
    "SESSION's effective state: `working', `blocked', or `idle'.
`state' (background sessions) flags blocked — a permission prompt or a
question.  `status' flags idle — the turn is over; it overrides a stale
`state working' (a live idle session still reports the state its last
turn ran under)."
    (cond ((equal (alist-get 'state session) "blocked") 'blocked)
          ((equal (alist-get 'status session) "idle") 'idle)
          (t 'working)))
  (defun my/claude-agents--segment (root sessions)
    "One clickable status glyph for ROOT's SESSIONS.
A red ● (with a count when several) demands attention — a session
blocked on a permission or a question.  A spinner frame means
everything is still working.  The glyph carries no name, so the
tooltip leads with the project path."
    (let ((blocked (seq-filter
                    (lambda (s) (eq (my/claude-agents--state s) 'blocked))
                    sessions)))
      (propertize
       (if blocked
           (concat "●" (when (cdr blocked)
                         (number-to-string (length blocked))))
         (aref my/claude-agents--spinner
               (mod my/claude-agents--frame
                    (length my/claude-agents--spinner))))
       'face (if blocked 'error 'success)
       'mouse-face 'mode-line-highlight
       'help-echo (concat
                   (abbreviate-file-name root) "\n"
                   (mapconcat (lambda (s)
                                (format "%s — %s"
                                        (my/claude-agents--state s)
                                        (alist-get 'name s)))
                              sessions "\n")
                   "\nmouse-1: ghostel buffer")
       'local-map (let ((map (make-sparse-keymap)))
                    (define-key map [mode-line down-mouse-1]
                                (lambda () (interactive)
                                  (my/claude-agents-goto root)))
                    map))))
  (defun my/claude-agents--open-roots ()
    "Directories of live local ghostel buffers.
A project counts as open in THIS Emacs when its terminal exists — the
workflow gives every active project a ghostel running `claude agents';
live sessions running outside Emacs (a bare Ghostty tab) stay hidden."
    (delq nil (mapcar (lambda (buf)
                        (with-current-buffer buf
                          (and (derived-mode-p 'ghostel-mode)
                               (not (file-remote-p default-directory))
                               default-directory)))
                      (buffer-list))))
  (defun my/claude-agents--rebuild ()
    "Rebuild the glyphs from the last poll, open projects only.
Also starts/stops the spinner animation timer: it only ticks while a
visible project is actually working, so an idle fleet costs nothing."
    (let* ((dirs (my/claude-agents--open-roots))
           (open (seq-filter
                  (lambda (group)
                    (seq-some (lambda (dir)
                                (file-in-directory-p dir (car group)))
                              dirs))
                  my/claude-agents--by-root))
           (working
            (seq-some (lambda (group)
                        (seq-some (lambda (s)
                                    (eq (my/claude-agents--state s) 'working))
                                  (cdr group)))
                      open)))
      (setq my/claude-agents-mode-line-string
            (when open
              (concat " " (mapconcat
                           (lambda (group)
                             (my/claude-agents--segment (car group)
                                                        (cdr group)))
                           open " "))))
      (cond ((and working (not my/claude-agents--anim-timer))
             (setq my/claude-agents--anim-timer
                   (run-with-timer 0.2 0.2 #'my/claude-agents--animate)))
            ((and (not working) my/claude-agents--anim-timer)
             (cancel-timer my/claude-agents--anim-timer)
             (setq my/claude-agents--anim-timer nil)))
      (force-mode-line-update t)))
  (defun my/claude-agents--animate ()
    (setq my/claude-agents--frame (1+ my/claude-agents--frame))
    (my/claude-agents--rebuild))
  (defun my/claude-agents--ghostel-changed ()
    "Rebuild when a ghostel buffer is born or killed.
A project's glyph should (dis)appear the moment its terminal does, not
at the next poll.  Deferred a tick: inside `kill-buffer-hook' the dying
buffer still counts as live."
    (when (derived-mode-p 'ghostel-mode)
      (run-with-timer 0 nil #'my/claude-agents--rebuild)))
  (defun my/claude-agents--render (sessions)
    "Group live, non-idle SESSIONS by project root, then rebuild the glyphs.
Live means the session has a numeric `pid' — a running process; the CLI
also reports the last recorded state of dead sessions from long-closed
projects, and those are noise.  Idle sessions are dropped too — turn
over, nothing running, nothing stuck — so the bar only carries projects
being actively worked.  Interactive sessions count the same as
background ones: a plain `claude' typed at in some project's ghostel is
part of the fleet.  Alphabetical order keeps glyphs from jumping around
between polls."
    (setq my/claude-agents--by-root
          (sort (seq-group-by
                 (lambda (s) (my/claude-agents--root (alist-get 'cwd s)))
                 (seq-filter
                  (lambda (s)
                    (and (numberp (alist-get 'pid s))
                         (not (eq (my/claude-agents--state s) 'idle))))
                  sessions))
                :key #'car :lessp #'string<))
    (my/claude-agents--rebuild))
  (defun my/claude-agents--sentinel (proc _event)
    (when (memq (process-status proc) '(exit signal))
      (let ((buf (process-buffer proc)))
        (unwind-protect
            (when (zerop (process-exit-status proc))
              ;; A failed parse (CLI hiccup) keeps the previous render.
              (ignore-errors
                (my/claude-agents--render
                 (with-current-buffer buf
                   (goto-char (point-min))
                   (json-parse-buffer :object-type 'alist
                                      :array-type 'list)))))
          (kill-buffer buf)))))
  (defun my/claude-agents--refresh ()
    "Poll `claude agents --json' asynchronously.
Runs through the shell so stderr noise can't corrupt the JSON; skipped
while the previous poll is still running."
    (unless (process-live-p my/claude-agents--process)
      (setq my/claude-agents--process
            (make-process
             :name "claude-agents"
             :buffer (generate-new-buffer " *claude-agents*")
             :command (list shell-file-name shell-command-switch
                            "claude agents --json 2>/dev/null")
             :connection-type 'pipe :noquery t
             :sentinel #'my/claude-agents--sentinel))))
  (define-minor-mode my/claude-agents-mode
    "Show per-project Claude Code background-agent status in the modeline."
    :global t
    (dolist (timer '(my/claude-agents--timer my/claude-agents--anim-timer))
      (when (symbol-value timer)
        (cancel-timer (symbol-value timer))
        (set timer nil)))
    (setq global-mode-string
          (remq 'my/claude-agents-mode-line-string global-mode-string)
          my/claude-agents-mode-line-string nil
          my/claude-agents--by-root nil)
    (remove-hook 'ghostel-mode-hook #'my/claude-agents--ghostel-changed)
    (remove-hook 'kill-buffer-hook #'my/claude-agents--ghostel-changed)
    (when my/claude-agents-mode
      (add-hook 'ghostel-mode-hook #'my/claude-agents--ghostel-changed)
      (add-hook 'kill-buffer-hook #'my/claude-agents--ghostel-changed)
      ;; Seed with "" first (as `display-time-mode' does): if the list ends up
      ;; STARTING with our symbol, mode-line data reads it as the conditional
      ;; construct (SYMBOL THEN ELSE) — with no THEN it renders `*invalid*'.
      (or global-mode-string (setq global-mode-string '("")))
      (add-to-list 'global-mode-string 'my/claude-agents-mode-line-string t)
      (setq my/claude-agents--timer
            (run-with-timer 0 my/claude-agents-interval
                            #'my/claude-agents--refresh))))
  :config
  (when (executable-find "claude")
    (add-hook 'after-init-hook #'my/claude-agents-mode))
  (provide 'claude-agents))

(use-package gptel
  :ensure t
  :preface
  (defvar my/gptel-project-directory
    (expand-file-name "gptel-chats/" user-emacs-directory)
    "Directory holding per-project gptel chat files (kept out of the repos).")
  (defvar my/gptel-history-directory
    (expand-file-name "gptel-chats/history/" user-emacs-directory)
    "Directory where one-off (non-file) gptel chats are auto-saved on kill.")
  (defvar my/gptel-commit-system
    "You are a Git expert.  From the staged diff, write a commit message: a \
concise imperative subject line under 50 characters, a blank line, then a \
short body explaining what changed and why.  Output only the message text, \
with no code fences or commentary."
    "System prompt used by `my/gptel-commit-summary'.")
  (defun my/gptel-project ()
    "Open a gptel chat scoped to the current project, in a right side window.
The chat file is keyed by project name under `my/gptel-project-directory',
so it never lands inside the project repo.  `default-directory' is bound to
the project root so gptel's tools/context resolve against it."
    (interactive)
    (require 'gptel)
    (let* ((proj (project-current t))
           (name (file-name-nondirectory (directory-file-name (project-root proj))))
           (file (expand-file-name (concat name ".org") my/gptel-project-directory))
           (default-directory (project-root proj)))
      (make-directory my/gptel-project-directory t)
      (let ((buf (find-file-noselect file)))
        (with-current-buffer buf
          (unless (bound-and-true-p gptel-mode) (gptel-mode 1)))
        (select-window
         (display-buffer
          buf '(display-buffer-in-side-window
                (side . right) (window-width . 0.4)))))))
  ;; --- Session auto-save (jim-myhrberg) -----------------------------------
  (defun my/gptel-autosave-session ()
    "Persist an unsaved gptel chat to `my/gptel-history-directory' on kill.
Skips buffers already visiting a file (e.g. the per-project chats) and empty
scratch sessions."
    (when (and (bound-and-true-p gptel-mode)
               (not buffer-file-name)
               (> (buffer-size) 0))
      (make-directory my/gptel-history-directory t)
      (write-region
       (point-min) (point-max)
       (expand-file-name (format-time-string "gptel-%Y%m%d-%H%M%S.org")
                         my/gptel-history-directory))))
  ;; --- Prose-friendly chat buffers + arm auto-save ------------------------
  (defun my/gptel-prose-setup ()
    "Make gptel chat buffers comfortable, and arm session auto-save."
    (visual-line-mode 1)
    (add-hook 'kill-buffer-hook #'my/gptel-autosave-session nil t))
  ;; --- Per-project context (chen-bin / nathan-typanski) -------------------
  (defun my/gptel-add-project-context ()
    "Add files chosen from the current project to the gptel context."
    (interactive)
    (require 'gptel-context)
    (let* ((proj (project-current t))
           (root (project-root proj))
           (files (mapcar (lambda (f) (file-relative-name f root))
                          (project-files proj)))
           (chosen (completing-read-multiple "Add to gptel context: " files)))
      (dolist (f chosen)
        (gptel-add-file (expand-file-name f root)))
      (message "Added %d file(s) to gptel context" (length chosen))))
  ;; --- On-demand commit summary (john-wiegley / karthink) -----------------
  (defun my/gptel-commit-summary ()
    "Draft a commit message from the staged diff and insert it at point.
Meant for the `git-commit' buffer; calls the LLM on demand (not on every
commit), so it costs a request only when you ask for it."
    (interactive)
    (require 'gptel)
    (let ((diff (shell-command-to-string "git diff --cached --no-color")))
      (if (string-blank-p diff)
          (user-error "No staged changes to summarize")
        (let ((pos (copy-marker (point))))
          (message "Asking %s for a commit summary..." gptel-model)
          (gptel-request diff
            :system my/gptel-commit-system
            :callback
            (lambda (resp _info)
              (if (stringp resp)
                  (with-current-buffer (marker-buffer pos)
                    (save-excursion (goto-char pos) (insert resp)))
                (message "gptel commit summary failed"))))))))
  :bind (("C-c g"   . gptel)
         ("C-c RET" . gptel-send)
         :map project-prefix-map
         ("a" . my/gptel-project)
         ("A" . my/gptel-add-project-context))
  :hook ((gptel-mode        . my/gptel-prose-setup)
         (gptel-post-stream . gptel-auto-scroll))
  :custom
  (gptel-default-mode 'org-mode)
  ;; Each Org subtree is its own conversation branch.
  (gptel-org-branching-context t)
  ;; Foldable turns: every prompt/response is its own Org heading.
  (gptel-prompt-prefix-alist '((org-mode      . "** Prompt\n")
                               (markdown-mode . "# ")
                               (text-mode     . "# ")))
  (gptel-response-prefix-alist '((org-mode      . "** Response\n")
                                 (markdown-mode . "")
                                 (text-mode     . "")))
  :config
  ;; Expose the per-project chat in the `C-x p p' dispatch menu.
  (add-to-list 'project-switch-commands '(my/gptel-project "AI chat" ?a) t)
  ;; Jump to the end of each finished response.
  (add-hook 'gptel-post-response-functions #'gptel-end-of-response)
  ;; On-demand commit messages in the magit/git-commit buffer.
  (with-eval-after-load 'git-commit
    (define-key git-commit-mode-map (kbd "C-c M-g") #'my/gptel-commit-summary))
  (setq gptel-model   'claude-haiku-4.5
        gptel-backend (gptel-make-gh-copilot "Copilot")))

;; Floating popups for gptel-quick (loaded on demand by gptel-quick itself).
(use-package posframe
  :ensure t
  :defer t)

;; One-shot "explain this" on any Embark target (symbol, region, URL, ...):
;; `C-.' then `?'.  karthink's package; GitHub-only, so installed via `:vc'.
(use-package gptel-quick
  :vc (:url "https://github.com/karthink/gptel-quick.git")
  :after embark                          ; only needs `embark-general-map' to exist;
  :bind ( :map embark-general-map        ; gptel-quick `require's gptel itself
          ("?" . gptel-quick))
  :config
  ;; Float the popup (posframe) and allow more time to press M-RET/M-w/+.
  (setq gptel-quick-display 'posframe
        gptel-quick-timeout 30))

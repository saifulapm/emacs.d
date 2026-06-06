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

;; Needed in any launch mode: `brew services' generates a plist with no
;; `EnvironmentVariables', so the daemon inherits launchd's minimal
;; /usr/bin:/bin PATH.  Run unconditionally (don't gate on
;; `window-system') — a `--fg-daemon' has no window system but still
;; needs Homebrew tools (gls, hunspell, intelephense, …).
(use-package exec-path-from-shell
  :ensure t
  :when (memq system-type '(darwin gnu/linux))
  :custom
  ;; Login shell only — skip the interactive `-i' pass that sources the
  ;; whole ~/.zshrc on every startup (~1000ms -> ~50ms).
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
	:functions (dbus-color-theme-dark-p mac-os-color-theme-dark-p)
  :preface
  (defun dark-mode-enabled-p ()
    "Check if dark mode is enabled."
    (cond ((file-exists-p (expand-file-name "~/.dark-mode")) t)
          ((featurep 'mac-os) (mac-os-color-theme-dark-p))
          ((featurep 'dbus) (dbus-color-theme-dark-p))
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
   frame-title-format "Emacs"
   auto-window-vscroll nil
   mouse-highlight t
   hscroll-step 1
   hscroll-margin 1
   scroll-margin 0
   scroll-conservatively 101
   scroll-preserve-screen-position nil
   frame-resize-pixelwise window-system
   window-resize-pixelwise window-system)
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
   enable-recursive-minibuffers t)
  (provide 'defaults))

(use-package jit-lock
  :custom
  (jit-lock-defer-time 0))

(use-package window
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
and icons look heavier/blockier than the same bytes rendered in
Ghostty (where CoreText scales the fallback glyph to the cell).
Setting this 1-2pt below the default face size shrinks the glyph to
sit cleanly inside one Maple Mono cell, matching Ghostty's look.
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
    ;; Linux renders the same `:height' visibly larger than macOS (no Retina
    ;; HiDPI scaling, different DPI assumptions), so dial it down there to
    ;; match the macOS look.
    (let ((mono (cond ((font-installed-p "Maple Mono Ghostty") "Maple Mono Ghostty")
                      ((font-installed-p "Maple Mono") "Maple Mono")
                      ((font-installed-p "JetBrains Mono") "JetBrains Mono")))
          (height (if (eq system-type 'gnu/linux) 120 150)))
      (when mono
        (set-face-attribute 'default nil :font mono :height height :width 'normal :weight 'normal)
        (set-face-attribute 'fixed-pitch nil :font mono)
        (set-face-attribute 'variable-pitch nil :font mono)))
    ;; Daemon size fix.  The FIRST emacsclient frame is sized while the default
    ;; face is still macOS's fallback `Menlo' 12pt (the font swap above no-ops
    ;; until a GUI frame exists), and `frame-inhibit-implied-resize' then freezes
    ;; that wrong pixel size — so the first frame comes up SMALLER than every
    ;; later frame (which is born after Maple Mono is cached on the daemon).
    ;; Re-assert the configured char dimensions here, *after* the real font is
    ;; applied, so every client frame settles to the same size no matter which
    ;; font it was born with.  Dimensions come from `default-frame-alist' to keep
    ;; a single source of truth.
    (when (display-graphic-p)
      (let ((w (cdr (assq 'width default-frame-alist)))
            (h (cdr (assq 'height default-frame-alist))))
        (when (and (integerp w) (integerp h))
          (set-frame-size (selected-frame) w h))))
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
  ;; present at `~/Library/Fonts/SymbolsNerdFontMono-Regular.ttf'.
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
         ([remap undo] . undo-only))
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
  :bind ([remap list-buffers] . ibuffer))

(use-package frame
  :bind (("C-z" . ignore)
         ("C-x C-z" . ignore)))

(use-package startup
  :no-require
  :custom
  (inhibit-splash-screen t))

(use-package menu-bar
  :config
  (menu-bar-mode -1)
  ;; `menu-bar-mode -1' hides the menu globally, but on a macOS daemon creating
  ;; a GUI frame re-enables it, so later text-terminal frames (`emacsclient -t')
  ;; come up WITH a menu bar.  The old `:unless (display-graphic-p)' guard can't
  ;; help — on a daemon it runs once, with no frame to test.  Force the menu off
  ;; per TTY frame instead; a no-op on GUI frames, and works on macOS + Linux.
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
  (defun dbus-color-theme-dark-p ()
    (equal '1 (caar (dbus-ignore-errors
                      (dbus-call-method
                       :session
                       "org.freedesktop.portal.Desktop"
                       "/org/freedesktop/portal/desktop"
                       "org.freedesktop.portal.Settings"
                       "Read"
                       "org.freedesktop.appearance"
                       "color-scheme")))))
  :config
  (dbus-ignore-errors
   (dbus-register-signal :session
                         "org.freedesktop.portal.Desktop"
                         "/org/freedesktop/portal/desktop"
                         "org.freedesktop.portal.Settings"
                         "SettingChanged"
                         #'color-scheme-changed)))

(use-package mac-os
  :no-require               ; there is no `mac-os.el' on disk — this
                            ; package is purely a `(provide 'mac-os)'
                            ; flag for `dark-mode-enabled-p'.  Without
                            ; `:no-require', use-package emits
                            ; "Cannot load mac-os" and skips `:config'
                            ; (so the `provide' never runs, the dark-
                            ; mode probe falls back, and the wrong
                            ; theme loads).
  :when (fboundp 'ns-do-applescript)
  :preface
  (defun mac-os-color-theme-dark-p ()
    "Return non-nil when macOS is in dark mode.
Uses `defaults read' instead of `ns-do-applescript' so it works
during `--fg-daemon' startup, where NS isn't yet initialised and
AppleScript signals an unrecoverable \"Window system is not in
use\" error that crashes the daemon."
    (string-prefix-p
     "Dark"
     (or (ignore-errors
           (string-trim
            (shell-command-to-string
             "defaults read -g AppleInterfaceStyle 2>/dev/null")))
         "")))
  (defun mac-os-appearance-changed (appearance)
    "MacOS handler to detect when the color-scheme has changed."
    (pcase appearance
      ('dark (load-theme local-config-dark-theme t))
      ('light (load-theme local-config-light-theme t))))
  :config
  ;; `:preface' runs unconditionally even when `:when' is false, so
  ;; `(provide 'mac-os)' must live in `:config' — otherwise on Linux
  ;; `(featurep 'mac-os)' is t and `mac-os-color-theme-dark-p' gets
  ;; called, hitting void `ns-do-applescript' during init.
  (provide 'mac-os)
  (add-hook 'ns-system-appearance-change-functions 'mac-os-appearance-changed))

(use-package modus-themes
  :ensure t
  :requires (local-config)
  :custom
  (modus-themes-org-blocks nil)
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
  :hook (after-init . load-modus)
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
  (defun load-modus ()
    (load-theme
     (if (dark-mode-enabled-p)
         local-config-dark-theme
       local-config-light-theme)
     'no-confirm)))

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
  :hook (prog-mode . show-paren-mode))

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

(use-package magit
  :ensure t
  :bind ("C-x g" . magit-status))

(use-package server
  :commands (server-running-p)
  :init
  (unless (server-running-p)
    (server-start)))

(use-package eldoc
  :delight eldoc-mode
  :defer t
  :custom
  (eldoc-echo-area-use-multiline-p nil))

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
  :config
  ;; Eglot's default PHP entry tries phpactor / felixfbecker — override to
  ;; use intelephense (installed via `pnpm i -g intelephense'). Pushed to
  ;; the front of the alist so it wins over the built-in default.
  (add-to-list 'eglot-server-programs
               '((php-mode phps-mode php-ts-mode) . ("intelephense" "--stdio"))))

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
          ("<backspace>" . dired-up-directory)
          ("M-<up>" . dired-up-directory)
          ("~" . dired-home-directory)
          ("C-c l" . org-store-link)
          ("h" . dired-toggle-dotfiles))
  :functions (dired-current-directory)
  :hook (dired-mode . dired-hide-details-mode)
  :preface
  (defvar dired-listing-switches-no-dotfiles
    "-lXhv --group-directories-first")
  (defvar dired-listing-switches-dotfiles
    "-lAXhv --group-directories-first")
  :init
  (when (eq system-type 'darwin)
    (setq insert-directory-program "gls"))
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
  (when (eq system-type 'darwin)
    ;; `!' (dired-do-shell-command) defaults to opening with the macOS app.
    (setq dired-guess-shell-alist-user '((".*" "open")))))

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

(use-package which-key
  :hook (after-init . which-key-mode)
  :delight which-key-mode
  :custom
  (which-key-idle-delay 0.75))

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

(use-package jinx
  :ensure t
	:when (executable-find "hunspell")
	:hook ((org-mode git-commit-mode markdown-ts-mode) . jinx-mode)
  :custom
  (jinx-languages "en_US"))

(use-package org
  :bind ( :map mode-specific-map
          ("c" . org-capture))
  :custom
  (org-directory "~/org")
  (org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (org-startup-folded 'content)
  (org-log-done 'time)
  (org-src-fontify-natively t)
  (org-edit-src-content-indentation 0)
  (org-src-preserve-indentation t)
  (org-image-actual-width nil)
  (org-capture-templates
   '(("t" "Todo"  entry (file+headline "" "Tasks")
      "* TODO %?\n  %U\n  %a")
     ("n" "Note"  entry (file+headline "" "Notes")
      "* %?\n  %U")
     ("j" "Journal" entry (file+olp+datetree "journal.org")
      "* %?\n  %U"))))

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
  :custom (browse-url-browser-function
           (if (featurep 'xwidget-internal)
               #'xwidget-webkit-browse-url
             #'eww-browse-url)))

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

(use-package region-bindings
  :vc ( :url "https://gitlab.com/andreyorst/region-bindings.el.git"
        :branch "main"
        :rev :newest)
  :commands (region-bindings-mode)
  :preface
  (defun region-bindings-off ()
    (region-bindings-mode -1))
  :hook ((after-init . global-region-bindings-mode)
         ((elfeed-search-mode magit-mode mu4e-headers-mode)
          . region-bindings-off)))

(use-package replace
  :bind ( :map region-bindings-mode-map
          ("k" . keep-lines)
          ("f" . flush-lines)))

(use-package phi-search
  :ensure t
  :defer t)

(use-package expand-region
  :ensure t
  :bind ("C-=" . er/expand-region))

(use-package multiple-cursors
  :ensure t
  :bind
  (("S-<mouse-1>" . mc/add-cursor-on-click)
   :map region-bindings-mode-map
   ("n" . mc/mark-next-symbol-like-this)
   ("N" . mc/mark-next-like-this)
   ("p" . mc/mark-previous-symbol-like-this)
   ("P" . mc/mark-previous-like-this)
   ("a" . mc/mark-all-symbols-like-this)
   ("A" . mc/mark-all-like-this)
   ("s" . mc/mark-all-in-region-regexp)
   ("l" . mc/edit-ends-of-lines)))

(use-package multiple-cursors-core
  :bind ( :map mc/keymap
          ("<return>" . nil)
          ("C-&" . mc/vertical-align-with-space)
          ("C-#" . mc/insert-numbers)))

(use-package vundo
  :ensure t
  :bind ( :map mode-specific-map
          ("u" . vundo))
  :custom
  (vundo-roll-back-on-quit nil)
  (vundo--window-max-height 10))

(use-package ov
  :ensure t
  :commands (ov-regexp))

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
    "Always open a fresh `*ghostel*' buffer (Ghostty-style cmd-T new tab)."
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
runs without $TERMINFO, so it can't see Ghostty.app's copy and dies with
\"Terminal type xterm-ghostty is not defined\".  ~/.terminfo is searched via
$HOME, so installing the entry there fixes it.  Idempotent — a no-op once the
entry exists or if `tic' is missing — so a fresh Mac self-heals on first run."
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
  ;; so a new Mac just works — no manual `tic' step to remember.
  (my/ghostel-ensure-terminfo)
  :bind (("C-c t"   . ghostel)
         ("C-c T"   . ghostel-list-buffers)
         :map project-prefix-map
         ("t"       . ghostel-project)
         ("T"       . ghostel-project-list-buffers)
         :map ghostel-mode-map
         ("s-t"     . my/ghostel-new)        ; cmd-T  → new tab
         ("s-]"     . ghostel-next)          ; cmd-]  → next tab
         ("s-["     . ghostel-previous))     ; cmd-[  → prev tab
  :hook (ghostel-mode . my/ghostel-restore-line-spacing)
  :custom
  ;; Silence OSC 9 / 777 desktop notifications — macOS attributes
  ;; AppleScript-posted banners to Script Editor, so clicking them
  ;; is useless.  See alert.el `osx-notifier' implementation.
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

(use-package gptel
  :ensure t
  :preface
  (defvar my/gptel-project-directory
    (expand-file-name "gptel-chats/" user-emacs-directory)
    "Directory holding per-project gptel chat files (kept out of the repos).")
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
  :bind (("C-c g"   . gptel)
         ("C-c RET" . gptel-send)
         :map project-prefix-map
         ("a" . my/gptel-project))
  :custom
  (gptel-default-mode 'org-mode)
  :config
  ;; Expose the per-project chat in the `C-x p p' dispatch menu.
  (add-to-list 'project-switch-commands '(my/gptel-project "AI chat" ?a) t)
  (setq gptel-model   'claude-haiku-4.5
        gptel-backend (gptel-make-gh-copilot "Copilot")))

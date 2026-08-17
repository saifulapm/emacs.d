;;; qshell-dark-theme.el --- Modus-derived theme following the desktop theme -*- lexical-binding:t -*-

;;; Commentary:
;;
;; The dark half of the qshell desktop integration: a Modus derivative
;; whose named colors come from ~/.local/state/qshell/emacs-theme.el,
;; rendered by the dotfiles' bin/theme-apply from the active desktop
;; theme's tokens.  Modus contributes every semantic mapping and face,
;; so Magit/Org/Eglot/Vertico coverage is stock-Modus complete — the
;; palette below only swaps the roots those mappings resolve to.
;;
;; The state file is re-read on every load of this file, and
;; `load-theme' (unlike `enable-theme') always re-loads the theme file —
;; that is the whole live-retheme mechanism: theme-apply re-renders the
;; palette, then has emacsclient call `qshell-theme-refresh'.
;;
;; Palette resolution order, first match winning (see
;; `modus-themes--get-theme-palette-subr'):
;;
;;     qshell-dark--overrides                 <- this file
;;     modus-themes-common-palette-overrides  <- init.el, incl. the faint preset
;;     qshell-theme-palette                   <- rendered desktop palette
;;     modus-themes-vivendi-palette           <- stock Modus
;;
;; Note where the faint preset sits: AHEAD of the rendered palette.  It
;; remaps a handful of surface entries onto other palette roots
;; (`bg-hl-line' -> `bg-dim', `bg-mode-line-active' -> `bg-inactive', …),
;; which for stock Modus is the whole point but here would quietly
;; discard the values theme-apply computed from the desktop — including
;; the accent-tinted `bg-hl-line' it derives specifically so a selection
;; stays visible on the current line.  `qshell-theme-desktop-owned'
;; re-asserts those entries from the top layer so the desktop wins.

;;; Code:

(require 'modus-themes)

(defvar qshell-theme-palette nil
  "Named-color palette rendered by theme-apply from the desktop theme.
Shared by `qshell-dark' and `qshell-light'; the desktop's polarity
decides which of the two is loaded, so the palette always matches.")

(defcustom qshell-theme-desktop-owned
  '(bg-hl-line bg-completion bg-mode-line-active bg-tab-bar bg-tab-other)
  "Palette entries the desktop theme owns outright.
Each is re-asserted from `qshell-theme-palette' into the theme's own
overrides layer, which outranks `modus-themes-common-palette-overrides'
— without that, the faint preset's remappings would shadow the rendered
value and these surfaces would stop tracking the desktop.  Entries
absent from the rendered palette are skipped, so this degrades to stock
Modus when the state file is missing."
  :group 'modus-themes
  :type '(repeat symbol))

(defcustom qshell-dark-palette-overrides nil
  "Overrides for the `qshell-dark' palette.
Mirrors `modus-vivendi-palette-overrides' in role and format.  These
take precedence over `qshell-theme-desktop-owned', so naming an entry
here hands it back to you."
  :group 'modus-themes
  :type '(repeat (list symbol (choice symbol string))))

(load (expand-file-name "~/.local/state/qshell/emacs-theme.el")
      :no-error :no-message)

(defvar qshell-dark--overrides nil
  "Effective OVERRIDES-PALETTE handed to `modus-themes-theme'.
`qshell-dark-palette-overrides' first, then the desktop-owned entries
resolved out of `qshell-theme-palette'.  Recomputed on every load of
this file, which is also every `load-theme' of `qshell-dark'.")

(setq qshell-dark--overrides
      (append qshell-dark-palette-overrides
              (delq nil (mapcar (lambda (entry) (assq entry qshell-theme-palette))
                                qshell-theme-desktop-owned))))

(modus-themes-theme
 'qshell-dark
 'qshell
 "Modus-derived dark theme drawing its palette from the qshell desktop theme."
 'dark
 'modus-themes-vivendi-palette
 'qshell-theme-palette
 'qshell-dark--overrides)

(provide 'qshell-dark-theme)
;;; qshell-dark-theme.el ends here

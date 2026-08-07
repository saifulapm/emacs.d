;;; qshell-dark-theme.el --- Modus-derived theme following the desktop theme -*- lexical-binding:t -*-

;;; Commentary:
;;
;; The dark half of the qshell desktop integration: a Modus derivative
;; whose named colors come from ~/.local/state/qshell/emacs-theme.el,
;; rendered by the dotfiles' bin/theme-apply from the active desktop
;; theme's tokens.  Modus contributes every semantic mapping and face,
;; so Magit/Org/Eglot/Vertico coverage is stock-Modus complete — the
;; palette below only swaps the roots those mappings resolve to, and
;; `modus-themes-common-palette-overrides' (the faint preset) still
;; applies on top, ahead of it in the resolution order.
;;
;; The state file is re-read on every load of this file, and
;; `load-theme' (unlike `enable-theme') always re-loads the theme file —
;; that is the whole live-retheme mechanism: theme-apply re-renders the
;; palette, then has emacsclient call `qshell-theme-refresh'.

;;; Code:

(require 'modus-themes)

(defvar qshell-theme-palette nil
  "Named-color palette rendered by theme-apply from the desktop theme.
Shared by `qshell-dark' and `qshell-light'; the desktop's polarity
decides which of the two is loaded, so the palette always matches.")

(defcustom qshell-dark-palette-overrides nil
  "Overrides for the `qshell-dark' palette.
Mirrors `modus-vivendi-palette-overrides' in role and format."
  :group 'modus-themes
  :type '(repeat (list symbol (choice symbol string))))

(load (expand-file-name "~/.local/state/qshell/emacs-theme.el")
      :no-error :no-message)

(modus-themes-theme
 'qshell-dark
 'qshell
 "Modus-derived dark theme drawing its palette from the qshell desktop theme."
 'dark
 'modus-themes-vivendi-palette
 'qshell-theme-palette
 'qshell-dark-palette-overrides)

(provide 'qshell-dark-theme)
;;; qshell-dark-theme.el ends here

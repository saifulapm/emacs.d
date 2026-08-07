;;; qshell-light-theme.el --- Modus-derived theme following the desktop theme -*- lexical-binding:t -*-

;;; Commentary:
;;
;; The light half of the qshell desktop integration; see
;; qshell-dark-theme.el for the full mechanism.  Identical except the
;; core palette is operandi's, so everything the rendered palette does
;; not name (it names all root colors; the semantic mappings differ)
;; resolves through Modus's light-polarity choices.

;;; Code:

(require 'modus-themes)

(defvar qshell-theme-palette nil
  "Named-color palette rendered by theme-apply from the desktop theme.
Shared by `qshell-dark' and `qshell-light'; the desktop's polarity
decides which of the two is loaded, so the palette always matches.")

(defcustom qshell-light-palette-overrides nil
  "Overrides for the `qshell-light' palette.
Mirrors `modus-operandi-palette-overrides' in role and format."
  :group 'modus-themes
  :type '(repeat (list symbol (choice symbol string))))

(load (expand-file-name "~/.local/state/qshell/emacs-theme.el")
      :no-error :no-message)

(modus-themes-theme
 'qshell-light
 'qshell
 "Modus-derived light theme drawing its palette from the qshell desktop theme."
 'light
 'modus-themes-operandi-palette
 'qshell-theme-palette
 'qshell-light-palette-overrides)

(provide 'qshell-light-theme)
;;; qshell-light-theme.el ends here

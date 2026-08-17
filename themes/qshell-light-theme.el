;;; qshell-light-theme.el --- Modus-derived theme following the desktop theme -*- lexical-binding:t -*-

;;; Commentary:
;;
;; The light half of the qshell desktop integration; see
;; qshell-dark-theme.el for the full mechanism and the palette
;; resolution order.  Identical except the core palette is operandi's,
;; so the ~20 semantic mappings that differ by polarity (`docstring',
;; `accent-3', `date-holiday', `fg-heading-3', …) resolve through
;; Modus's light-polarity choices.  The rendered palette names every
;; root color, so that difference in mappings is the whole of what the
;; core palette still contributes.

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

(defcustom qshell-light-palette-overrides nil
  "Overrides for the `qshell-light' palette.
Mirrors `modus-operandi-palette-overrides' in role and format.  These
take precedence over `qshell-theme-desktop-owned', so naming an entry
here hands it back to you."
  :group 'modus-themes
  :type '(repeat (list symbol (choice symbol string))))

(load (expand-file-name "~/.local/state/qshell/emacs-theme.el")
      :no-error :no-message)

(defvar qshell-light--overrides nil
  "Effective OVERRIDES-PALETTE handed to `modus-themes-theme'.
`qshell-light-palette-overrides' first, then the desktop-owned entries
resolved out of `qshell-theme-palette'.  Recomputed on every load of
this file, which is also every `load-theme' of `qshell-light'.")

(setq qshell-light--overrides
      (append qshell-light-palette-overrides
              (delq nil (mapcar (lambda (entry) (assq entry qshell-theme-palette))
                                qshell-theme-desktop-owned))))

(modus-themes-theme
 'qshell-light
 'qshell
 "Modus-derived light theme drawing its palette from the qshell desktop theme."
 'light
 'modus-themes-operandi-palette
 'qshell-theme-palette
 'qshell-light--overrides)

(provide 'qshell-light-theme)
;;; qshell-light-theme.el ends here

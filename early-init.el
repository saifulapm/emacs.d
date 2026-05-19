;;; early-init.el --- Description -*- lexical-binding: t; -*-

(setq package-enable-at-startup nil)

(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 1.0)

;; Opacity
(add-to-list 'default-frame-alist '(alpha-background . 90))

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 2 1024 1024)
                  gc-cons-percentage 0.1)))

;;; File handler optimization — skip regex matching on every load
(defvar my--old-file-name-handler-alist file-name-handler-alist)
(setq file-name-handler-alist nil)
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq file-name-handler-alist my--old-file-name-handler-alist)))

;;; UI — set frame parameters directly
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(horizontal-scroll-bars) default-frame-alist)
(setq menu-bar-mode nil
      tool-bar-mode nil
      scroll-bar-mode nil)

;;; Performance
(setq frame-resize-pixelwise t
      frame-inhibit-implied-resize t
      auto-mode-case-fold nil
      read-process-output-max (* 2 1024 1024)
      load-prefer-newer t)

;;; Bidirectional text
(setq-default bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)


;;; Native comp
(setq native-comp-async-report-warnings-errors 'silent)

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("gnu-devel" . "https://elpa.gnu.org/devel/"))
(package-initialize)

(provide 'early-init)
;;; early-init.el ends here

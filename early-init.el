;;; early-init.el --- Description -*- lexical-binding: t; -*-
(setq gc-cons-threshold (* 16 1024 1024))

(let ((original-gc-cons-threshold gc-cons-threshold))
  (setq
    gc-cons-threshold most-positive-fixnum
    inhibit-compacting-font-caches t
    message-log-max 16384
    package-enable-at-startup nil
    inhibit-default-init t
		auto-mode-case-fold nil
    load-prefer-newer noninteractive)
    (add-hook 'emacs-startup-hook
    					(lambda nil
                (setq gc-cons-threshold original-gc-cons-threshold))))

;; Paint the frame in the dark theme's colors before any package or
;; theme loads, so startup doesn't flash white before `modus-vivendi'
;; takes over.  Values mirror `init.el' overrides:
;;   bg-main "#181818"  (modus-vivendi-palette-overrides)
;;   fg-main "#ffffff"  (modus-vivendi default)
;; `ns-appearance' + `ns-transparent-titlebar' keep the macOS title
;; bar dark too — without them the bar paints light at launch.
(setq-default default-frame-alist '((width . 170)
                                   (height . 52)
                                   (tool-bar-lines . 0)
                                   (vertical-scroll-bars . nil)
                                   (left-fringe . 8)
                                   (right-fringe . 8)
                                   (bottom-divider-width . 0)
                                   (right-divider-width . 1)
                                   (background-color . "#181818")
                                   (foreground-color . "#ffffff")
                                   (ns-appearance . dark)
                                   (ns-transparent-titlebar . t))
              initial-frame-alist default-frame-alist
							use-short-answers t
              frame-background-mode 'dark
              frame-inhibit-implied-resize t
              fringe-indicator-alist (assq-delete-all 'truncation fringe-indicator-alist))

(unless (or (daemonp) noninteractive)
  (let ((original-file-name-handler-alist file-name-handler-alist))
    (setq-default file-name-handler-alist nil)
    (add-hook
     'emacs-startup-hook
     (lambda nil
       (setq file-name-handler-alist
             (delete-dups (append file-name-handler-alist
                                  original-file-name-handler-alist)))
       (setq read-process-output-max
             (or (and (eq system-type 'gnu/linux)
                      (ignore-error permission-denied
                        (with-temp-buffer
                          (insert-file-contents-literally
                           "/proc/sys/fs/pipe-max-size")
                          (string-to-number
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
                 (* 4 1024 1024))))
     101))
  (when (fboundp #'tool-bar-mode)
    (tool-bar-mode -1))
  (when (fboundp #'tooltip-mode)
    (tooltip-mode -1))
  (when (fboundp #'scroll-bar-mode)
    (scroll-bar-mode -1)))

(when (featurep 'native-compile)
  (setopt native-comp-async-report-warnings-errors 'silent))

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("gnu-devel" . "https://elpa.gnu.org/devel/"))
(package-initialize)

(provide 'early-init)
;;; early-init.el ends here

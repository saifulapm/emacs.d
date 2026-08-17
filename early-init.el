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

;; NO `background-color'/`foreground-color' here — the theme owns colors.
;; Colors set as frame parameters become *frame-local* default-face settings,
;; which shadow whatever `load-theme' installs globally, for the life of the
;; frame.  Pinning "#181818" here therefore didn't just pre-paint the frame,
;; it made `modus-operandi' unusable: every emacsclient frame kept the dark
;; background while wearing the light theme's foreground palette (grey-on-black
;; text, white mode line).  These used to pre-paint the frame dark so startup
;; wouldn't flash white; under the daemon that bought nothing anyway — client
;; frames are created long after the theme is loaded, so there is no flash to
;; hide — and it cost a permanently mispainted frame whenever the light theme
;; won.  A direct, non-daemon `emacs' may now flash light for the length of
;; init; that is the whole of the regression.
;; No frame size set here — niri owns the window geometry.  Only appearance
;; params live in the alist.
(setq-default default-frame-alist '((tool-bar-lines . 0)
                                   (vertical-scroll-bars . nil)
                                   (left-fringe . 8)
                                   (right-fringe . 8)
                                   (bottom-divider-width . 0)
                                   (right-divider-width . 1))
              initial-frame-alist default-frame-alist
							use-short-answers t
              frame-background-mode 'dark
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
  (setopt native-comp-async-report-warnings-errors 'silent)
  ;; Pause background native-compilation while on battery, so an unplugged
  ;; laptop doesn't get surprise fan spin-ups from async comp jobs (Emacs 31+).
  (setopt native-comp-async-on-battery-power nil))

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("gnu-devel" . "https://elpa.gnu.org/devel/"))
(package-initialize)

(provide 'early-init)
;;; early-init.el ends here

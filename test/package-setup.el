;;; package-setup.el --- Isolated dependencies for flexi-table tests -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Initialize a repository-local package directory for batch commands.  When
;; FLEXI_TABLE_INSTALL_DEPS is set, install the runtime dependencies as well as
;; development dependencies requested by FLEXI_TABLE_DEV_DEPS.

;;; Code:

(require 'package)
(require 'seq)

(defconst flexi-table-test--root-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the flexi-table checkout.")

(setq package-user-dir
      (file-name-as-directory
       (expand-file-name
        (or (getenv "FLEXI_TABLE_PACKAGE_DIR") ".packages")
        flexi-table-test--root-directory)))

(setq package-install-upgrade-built-in t)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))

(package-initialize)

(when (getenv "FLEXI_TABLE_INSTALL_DEPS")
  (let* ((runtime '((transient "0.13.4")))
         (development (and (getenv "FLEXI_TABLE_DEV_DEPS")
                           '((package-lint nil))))
         (requirements (append runtime development))
         (missing
          (seq-filter
           (lambda (requirement)
             (not (package-installed-p
                   (car requirement)
                   (and (cadr requirement)
                        (version-to-list (cadr requirement))))))
           requirements)))
    (when missing
      (package-refresh-contents)
      (dolist (requirement missing)
        (package-install (car requirement))))))

(provide 'package-setup)
;;; package-setup.el ends here

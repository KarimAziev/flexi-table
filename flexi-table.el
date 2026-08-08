;;; flexi-table.el --- Dynamic tabulated list renderer -*- lexical-binding: t -*-

;; Copyright © 2026 Karim Aziiev <karim.aziiev@gmail.com>

;; Author: Karim Aziiev <karim.aziiev@gmail.com>
;; Keywords: convenience, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.13.4"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/KarimAziev/flexi-table

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `flexi-table-mode' is a small, dynamic alternative to Emacs's
;; built-in tabulated list renderer.  Its rows are ordinary objects and its
;; columns use the following form:
;;
;;   (FIELD :name "Name" :width 20 :formatter FUNCTION ...)
;;
;; The renderer supports styled sortable headers, igist-style fast resizing,
;; declarative clickable cell filters, transient column and filter editors, and
;; coalesced row replacement as asynchronous data arrives.  It was extracted
;; from the tabulated view implementation in igist.el so it can be reused
;; independently.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'transient)

(defgroup flexi-table nil
  "Dynamic, incrementally updated tabulated lists."
  :group 'convenience
  :prefix "flexi-table-")

(defface flexi-table-cell
  '((t :inherit fixed-pitch))
  "Base face supplying consistent fixed-pitch metrics to table cells."
  :group 'flexi-table)

(defface flexi-table-header
  '((t :inherit (flexi-table-cell header-line)))
  "Face used for an in-buffer table heading.
It inherits fixed-pitch font metrics so character widths match table cells."
  :group 'flexi-table)

(defface flexi-table-header-column
  '((t :inherit (flexi-table-cell header-line-active flexi-table-header)
       :weight semi-bold))
  "Face used for individual column names in a table heading."
  :group 'flexi-table)

(defface flexi-table-header-column-sorted
  '((t :inherit (flexi-table-cell font-lock-keyword-face
                             flexi-table-header-column)
       :weight bold))
  "Face used for the actively sorted column name."
  :group 'flexi-table)

(defface flexi-table-header-column-filtered
  '((t :inherit (flexi-table-cell warning flexi-table-header-column)
       :weight bold))
  "Face used for a column that has an active filter."
  :group 'flexi-table)

(defface flexi-table-filter-button
  '((t :inherit link))
  "Face used for cells that can be clicked to filter a table."
  :group 'flexi-table)

(defface flexi-table-filter-button-active
  '((t :inherit (success flexi-table-filter-button) :weight bold))
  "Face used for a filterable cell whose value is currently active."
  :group 'flexi-table)

(defcustom flexi-table-padding 1
  "Number of spaces before each table row and its header."
  :type 'natnum
  :group 'flexi-table)

(defcustom flexi-table-use-header-line t
  "Whether to display column headings in the header line.
When nil, the heading is displayed in an overlay at the start of the buffer."
  :type 'boolean
  :group 'flexi-table)

(defcustom flexi-table-resize-strategy 20
  "Rows to update immediately while resizing a column.

An integer means to update at most that many visible rows before scheduling a
full idle refresh.  The value `visible' updates every visible row, t refreshes
the complete table immediately, and nil updates only the current row."
  :type '(choice
          (const :tag "Current row" nil)
          (integer :tag "Maximum visible rows" 20)
          (const :tag "All visible rows" visible)
          (const :tag "All rows" t))
  :group 'flexi-table)

(defcustom flexi-table-resize-idle-delay 0.35
  "Idle delay before completing a partial column resize."
  :type 'number
  :group 'flexi-table)

(defcustom flexi-table-async-update-delay 0.05
  "Idle delay used to coalesce asynchronous row updates.

Calls to `flexi-table-queue-entry-update' made during this interval
are rendered as one position-preserving operation."
  :type 'number
  :group 'flexi-table)

(defcustom flexi-table-column-comp-read-threshold 15
  "Column count above which selection uses completion.

Integer threshold for choosing how column switching selects a column.

When the number of columns is greater than the value, column switching
reads a column name with completion.

When the number of columns is less than or equal to the value, column
switching moves to the next column cyclically.

A value of 0 makes completion be used whenever at least one column is
available."
  :type 'integer
  :group 'flexi-table)

(defcustom flexi-table-menu-column-line-width 58
  "Maximum width of a column-list line in the column transient.

Longer lists are continued on indented lines so a table with many columns does
not turn the transient into one dense horizontal sentence."
  :type '(integer :tag "Characters" 24)
  :group 'flexi-table)

(defcustom flexi-table-gui-sort-indicator-asc ?▼
  "Indicator for ascending sorting on graphical displays."
  :type 'character
  :group 'flexi-table)

(defcustom flexi-table-gui-sort-indicator-desc ?▲
  "Indicator for descending sorting on graphical displays."
  :type 'character
  :group 'flexi-table)

(defcustom flexi-table-tty-sort-indicator-asc ?v
  "Indicator for ascending sorting on text displays."
  :type 'character
  :group 'flexi-table)

(defcustom flexi-table-tty-sort-indicator-desc ?^
  "Indicator for descending sorting on text displays."
  :type 'character
  :group 'flexi-table)

(defvar-local flexi-table-entries nil
  "Objects displayed in the current table.")

(defvar-local flexi-table-columns nil
  "Active column specifications in the current table.")

(defvar-local flexi-table-available-columns nil
  "All column specifications that can be added to the current table.")

(defvar-local flexi-table-key-function nil
  "Function called with an entry to obtain its stable row identifier.")

(defvar-local flexi-table-sort-key nil
  "Current sort specification as (COLUMN-NAME . DESCENDING).")

(defvar-local flexi-table-filter-function nil
  "Optional predicate called for every entry before it is rendered.")

(defvar-local flexi-table-filters nil
  "Active declarative column filters as (FIELD . VALUE) pairs.")

(defvar-local flexi-table-columns-variable nil
  "Custom variable from which the current column layout originated.")

(defvar-local flexi-table-mode-name-function nil
  "Optional function called with the entry count to compute `mode-name'.")

(defvar-local flexi-table--rendered (make-hash-table :test #'equal)
  "Map of rendered row identifiers to entry objects.")

(defvar-local flexi-table--row-markers nil
  "Map of row identifiers to start markers for fast incremental updates.")

(defvar-local flexi-table-menu-extra-suffixes-description nil)
(defvar-local flexi-table-menu-extra-suffixes nil)

(defvar-local flexi-table--render-timer nil)
(defvar-local flexi-table--update-timer nil)
(defvar-local flexi-table--pending-updates nil)
(defvar-local flexi-table--current-column nil)
(defvar-local flexi-table--header-overlay nil)
(defvar-local flexi-table--owns-header-line nil)
(defvar-local flexi-table--initial-columns nil)

(defvar flexi-table-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<header-line> <mouse-1>")
                #'flexi-table-sort-by-click)
    (define-key map (kbd "<header-line> <mouse-2>")
                #'flexi-table-sort-by-click)
    (define-key map (kbd "<mouse-1>")
                #'flexi-table-sort-by-click)
    (define-key map (kbd "<mouse-2>")
                #'flexi-table-sort-by-click)
    map)
  "Keymap installed on sortable column headings.")

(defvar flexi-table-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'flexi-table-sort)
    (define-key map (kbd "}") #'flexi-table-widen-current-column)
    (define-key map (kbd "{") #'flexi-table-narrow-current-column)
    (define-key map (kbd "M-]") #'flexi-table-move-column-right)
    (define-key map (kbd "M-[") #'flexi-table-move-column-left)
    (define-key map (kbd "C-M-f") #'flexi-table-forward-column)
    (define-key map (kbd "C-M-b") #'flexi-table-backward-column)
    (define-key map (kbd "C-c C-e") #'flexi-table-edit-column)
    (define-key map (kbd "C-c C-a") #'flexi-table-add-column)
    (define-key map (kbd "C-c C-d") #'flexi-table-remove-column)
    (define-key map (kbd "C-c C-s") #'flexi-table-save-columns)
    (define-key map (kbd "C") #'flexi-table-columns-menu)
    (define-key map (kbd "?") #'flexi-table-columns-menu)
    (define-key map (kbd "f") #'flexi-table-toggle-filter-at-point)
    (define-key map (kbd "/") #'flexi-table-filters-menu)
    map)
  "Keymap used by `flexi-table-mode'.")




(define-derived-mode flexi-table-mode special-mode "Flexi-Table"
  "Major mode for dynamically editable, incrementally updated tables."
  (setq-local truncate-lines t)
  (setq-local buffer-undo-list t)
  (setq-local bidi-paragraph-direction 'left-to-right)
  (setq-local text-scale-remap-header-line t)
  (setq-local flexi-table--rendered
              (make-hash-table :test #'equal))
  (setq-local flexi-table--row-markers
              (make-hash-table :test #'equal))
  (setq-local flexi-table--pending-updates
              (make-hash-table :test #'equal))
  (add-hook 'kill-buffer-hook
            #'flexi-table--cancel-timers nil t)
  (when (fboundp 'header-line-indent-mode)
    (header-line-indent-mode 1))
  (setq-local glyphless-char-display
              (let ((table (make-char-table 'glyphless-char-display nil)))
                (set-char-table-parent table glyphless-char-display)
                (aset table flexi-table-gui-sort-indicator-desc
                      (cons nil
                            (char-to-string
                             flexi-table-tty-sort-indicator-desc)))
                (aset table flexi-table-gui-sort-indicator-asc
                      (cons nil
                            (char-to-string
                             flexi-table-tty-sort-indicator-asc)))
                table)))

(put 'flexi-table-mode 'mode-class 'special)

(defun flexi-table--column-name (column)
  "Return the display name of COLUMN."
  (or (plist-get (cdr column) :name)
      (capitalize
       (replace-regexp-in-string
        "[_-]+" " " (format "%s" (car column))))))

(defun flexi-table--find-column (name &optional columns)
  "Return the column named NAME from COLUMNS or the active columns."
  (seq-find (lambda (column)
              (equal name (flexi-table--column-name column)))
            (or columns flexi-table-columns)))

(defun flexi-table--column-sortable-p (column)
  "Return non-nil when COLUMN may be sorted."
  (let ((props (cdr column)))
    (if (plist-member props :sortable)
        (plist-get props :sortable)
      t)))

(defun flexi-table--column-filterable-p (column)
  "Return non-nil when COLUMN supports declarative value filtering."
  (and column
       (or (plist-get (cdr column) :filterable)
           (functionp (plist-get (cdr column) :filter-predicate)))))

(defun flexi-table--find-column-by-field (field &optional columns)
  "Return the column for FIELD from COLUMNS or the complete column catalog."
  (seq-find (lambda (column) (equal field (car column)))
            (or columns flexi-table-available-columns
                flexi-table-columns)))

(defun flexi-table--filterable-columns ()
  "Return visible columns that support declarative filtering."
  (seq-filter #'flexi-table--column-filterable-p flexi-table-columns))

(defun flexi-table--active-filter (field)
  "Return the active filter cell for FIELD, including a nil filter value."
  (cl-assoc field flexi-table-filters :test #'equal))

(defun flexi-table--filter-value-label (column value)
  "Return a concise display label for COLUMN's filter VALUE."
  (let ((label (flexi-table--sanitize-label
                (flexi-table--format-value column value))))
    (if (string-empty-p label) "(empty)" label)))

(defun flexi-table--column-filter-match-p (column selected entry)
  "Return non-nil when ENTRY's COLUMN value matches SELECTED.

When COLUMN declares `:filter-predicate', call it with the raw cell value,
SELECTED, ENTRY, and the current table buffer.  Otherwise compare values using
`equal'."
  (let* ((value (flexi-table--column-value column entry))
         (predicate (plist-get (cdr column) :filter-predicate)))
    (if (functionp predicate)
        (funcall predicate value selected entry (current-buffer))
      (equal value selected))))

(defun flexi-table--entry-visible-p (entry)
  "Return non-nil when ENTRY passes consumer and declarative filters."
  (and (or (not (functionp flexi-table-filter-function))
           (funcall flexi-table-filter-function entry))
       (cl-every
        (lambda (filter)
          (when-let* ((column (flexi-table--find-column-by-field
                               (car filter))))
            (flexi-table--column-filter-match-p
             column (cdr filter) entry)))
        flexi-table-filters)))

(defun flexi-table--window-width ()
  "Return the most relevant body width for the current table."
  (if-let* ((window (get-buffer-window (current-buffer))))
      (window-body-width window)
    (window-body-width)))

(defun flexi-table--width-value (value &optional fallback)
  "Convert column width VALUE to characters, or return FALLBACK.
VALUE may be a number, a percentage string, or a pixel string."
  (cond
   ((numberp value) (max 1 (truncate value)))
   ((and (stringp value)
         (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%\\'" value))
    (max 1 (round (* (flexi-table--window-width)
                     (/ (string-to-number (match-string 1 value)) 100.0)))))
   ((and (stringp value)
         (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)px\\'" value))
    (max 1 (round (/ (string-to-number (match-string 1 value))
                     (max 1.0 (float (frame-char-width)))))))
   ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
    (max 1 (string-to-number value)))
   (t (or fallback 10))))

(defun flexi-table--column-width (column)
  "Return the effective character width of COLUMN."
  (let* ((props (cdr column))
         (width (flexi-table--width-value
                 (plist-get props :width)
                 (max 3 (string-width
                         (flexi-table--column-name column)))))
         (minimum (and (plist-member props :min-width)
                       (flexi-table--width-value
                        (plist-get props :min-width))))
         (maximum (and (plist-member props :max-width)
                       (flexi-table--width-value
                        (plist-get props :max-width)))))
    (when minimum
      (setq width (max width minimum)))
    (when maximum
      (setq width (min width maximum)))
    width))

(defun flexi-table--column-padding (column)
  "Return the number of spaces following COLUMN."
  (max 0 (or (plist-get (cdr column) :pad-right) 1)))

(defun flexi-table--entry-key (entry)
  "Return the stable key for ENTRY."
  (unless (functionp flexi-table-key-function)
    (error "No `flexi-table-key-function' has been configured"))
  (funcall flexi-table-key-function entry))

(defun flexi-table-map-getter (path)
  "Return a function that obtains PATH from an alist object.
PATH may be a symbol, a string, or a list describing nested fields."
  (let ((parts (if (listp path) path (list path))))
    (lambda (object &optional _table)
      (seq-reduce
       (lambda (value part)
         (cond
          ((symbolp part) (alist-get part value))
          ((stringp part) (cdr (assoc-string part value)))
          (t nil)))
       parts object))))

(defun flexi-table--column-value (column entry)
  "Obtain COLUMN's raw value from ENTRY."
  (let ((getter (or (plist-get (cdr column) :getter)
                    (flexi-table-map-getter (car column)))))
    (funcall getter entry (current-buffer))))

(defun flexi-table--format-value (column value)
  "Format VALUE according to COLUMN."
  (let* ((props (cdr column))
         (formatter (plist-get props :formatter))
         (formatted
          (cond
           ((functionp formatter) (funcall formatter value))
           ((stringp formatter) (format formatter (or value "")))
           ((null value) "")
           ((stringp value) value)
           (t (format "%s" value))))
         (formatted (or formatted ""))
         (displayer (plist-get props :displayer)))
    (if (functionp displayer)
        (or (funcall displayer formatted
                     (* (flexi-table--column-width column)
                        (frame-char-width))
                     (current-buffer))
            "")
      formatted)))

(defun flexi-table--sanitize-label (value)
  "Turn rendered VALUE into a single-line string."
  (let ((label (if (stringp value) value (format "%s" value))))
    (if (string-match-p "[\n\r\f]" label)
        (string-join (split-string label "[\n\r\f]" t) " ")
      label)))

(defun flexi-table--align-label (label width align truncate)
  "Render LABEL in WIDTH characters using ALIGN.
When TRUNCATE is non-nil, truncate values wider than WIDTH."
  (let* ((label (if truncate
                    (truncate-string-to-width label width nil nil t t)
                  label))
         (label-width (string-width label))
         (space (max 0 (- width label-width))))
    (pcase align
      ((or 'right "right") (concat (make-string space ?\s) label))
      ((or 'center "center")
       (let ((left (/ space 2)))
         (concat (make-string left ?\s) label
                 (make-string (- space left) ?\s))))
      (_ (concat label (make-string space ?\s))))))

(defun flexi-table--apply-column-face (text column)
  "Apply COLUMN's face or color to TEXT."
  (let* ((props (cdr column))
         (face (plist-get props :face))
         (color (plist-get props :color)))
    (propertize
     text 'face
     (delq nil
           (list 'flexi-table-cell
                 (cond
                  (face face)
                  ((stringp color) `(:foreground ,color))
                  (color color)))))))

(defun flexi-table--filter-button-action (button)
  "Toggle the declarative filter represented by BUTTON."
  (flexi-table-toggle-filter
   (button-get button 'flexi-table-filter-field)
   (button-get button 'flexi-table-filter-value)))

(defun flexi-table--make-filter-button
    (start end column value label)
  "Make text from START to END a filter button for COLUMN and VALUE.
LABEL is the human-readable cell value used in help text."
  (when (< start end)
    (let* ((field (car column))
           (active (flexi-table--active-filter field))
           (selected (and active (equal (cdr active) value))))
      (make-text-button
       start end
       'action #'flexi-table--filter-button-action
       'follow-link t
       'face (list 'flexi-table-cell
                   (if selected
                       'flexi-table-filter-button-active
                     'flexi-table-filter-button))
       'mouse-face 'highlight
       'help-echo
       (if selected
           (format "Click to remove filter %s = %s"
                   (flexi-table--column-name column) label)
         (format "Click to show only rows where %s = %s"
                 (flexi-table--column-name column) label))
       'flexi-table-filter-field field
       'flexi-table-filter-value value))))

(defun flexi-table--render-column (column entry last-column-p)
  "Insert COLUMN for ENTRY.
LAST-COLUMN-P means not to force trailing padding beyond the column width."
  (let* ((name (flexi-table--column-name column))
         (width (flexi-table--column-width column))
         (value (flexi-table--column-value column entry))
         (formatted (flexi-table--format-value column value))
         (label (flexi-table--sanitize-label formatted))
         (align (plist-get (cdr column) :align))
         (display-label
          (if (not last-column-p)
              (truncate-string-to-width label width nil nil t t)
            label))
         (display-width (string-width display-label))
         (space (max 0 (- width display-width)))
         (leading-space
          (pcase align
            ((or 'right "right") space)
            ((or 'center "center") (/ space 2))
            (_ 0)))
         (text (flexi-table--align-label
                label width align (not last-column-p)))
         (start (point)))
    (insert (flexi-table--apply-column-face text column))
    (add-text-properties
     start (point)
     (list 'flexi-table-column name
           'flexi-table-field (car column)
           'help-echo (format "%s: %s" name label)))
    (when (and (flexi-table--column-filterable-p column)
               (not (string-empty-p display-label)))
      (flexi-table--make-filter-button
       (+ start leading-space)
       (+ start leading-space (length display-label))
       column value display-label))
    (unless last-column-p
      (insert (propertize
               (make-string (flexi-table--column-padding column) ?\s)
               'face 'flexi-table-cell)))))

(defun flexi-table--render-entry (entry)
  "Insert one table row for ENTRY at point."
  (let* ((id (flexi-table--entry-key entry))
         (start (point))
         (columns flexi-table-columns)
         (last (car (last columns))))
    (insert (propertize (make-string flexi-table-padding ?\s)
                        'face 'flexi-table-cell))
    (dolist (column columns)
      (flexi-table--render-column column entry (eq column last)))
    (insert ?\n)
    (add-text-properties
     start (point)
     (list 'flexi-table-id id
           'flexi-table-entry entry
           'rear-nonsticky t))
    (puthash id entry flexi-table--rendered)
    (when-let* ((old-marker (gethash id flexi-table--row-markers)))
      (set-marker old-marker nil))
    (puthash id (copy-marker start)
             flexi-table--row-markers)))

(defun flexi-table-current-id (&optional position)
  "Return the row identifier at POSITION or point."
  (get-text-property (or position (point)) 'flexi-table-id))

(defun flexi-table-current-entry (&optional position)
  "Return the entry at POSITION or point."
  (or (get-text-property (or position (point))
                         'flexi-table-entry)
      (when-let* ((id (flexi-table-current-id position)))
        (gethash id flexi-table--rendered))))

(defun flexi-table-column-at-point (&optional position)
  "Return the column name at POSITION or point."
  (get-text-property (or position (point)) 'flexi-table-column))

(defun flexi-table--closest-column ()
  "Return the column at or nearest point on the current row."
  (or (flexi-table-column-at-point)
      (let* ((position (point))
             (beginning (line-beginning-position))
             (end (line-end-position))
             (before (previous-single-property-change
                      position 'flexi-table-column nil beginning))
             (after (next-single-property-change
                     position 'flexi-table-column nil end))
             (candidates
              (delq nil
                    (mapcar
                     (lambda (pos)
                       (when-let* ((name
                                    (flexi-table-column-at-point pos)))
                         (cons (abs (- position pos)) name)))
                     (list before after)))))
        (cdr (car (sort candidates (lambda (a b) (< (car a) (car b)))))))))

(defun flexi-table--row-bounds (id)
  "Return the buffer bounds of the row identified by ID."
  (let* ((marker (and (hash-table-p flexi-table--row-markers)
                      (gethash id flexi-table--row-markers)))
         (marker-position (and (markerp marker)
                               (marker-buffer marker)
                               (marker-position marker)))
         (limit (point-max))
         (position (or marker-position (point-min)))
         found)
    (when (and marker-position
               (equal id (get-text-property
                          marker-position 'flexi-table-id)))
      (setq found
            (cons marker-position
                  (or (next-single-property-change
                       marker-position 'flexi-table-id nil limit)
                      limit))))
    (unless found
      (setq position (point-min)))
    (while (and (< position limit) (not found))
      (let* ((value (get-text-property position 'flexi-table-id))
             (next (or (next-single-property-change
                        position 'flexi-table-id nil limit)
                       limit)))
        (if (equal value id)
            (progn
              (setq found (cons position next))
              (when (hash-table-p flexi-table--row-markers)
                (puthash id (copy-marker position)
                         flexi-table--row-markers)))
          (setq position (if (= position next) (1+ position) next)))))
    found))

(defun flexi-table--clear-row-markers ()
  "Detach and forget all cached row markers."
  (when (hash-table-p flexi-table--row-markers)
    (maphash (lambda (_id marker)
               (when (markerp marker)
                 (set-marker marker nil)))
             flexi-table--row-markers)
    (clrhash flexi-table--row-markers)))

(defun flexi-table--goto-id (id &optional column)
  "Move point to ID and optionally COLUMN, returning non-nil on success."
  (when-let* ((bounds (flexi-table--row-bounds id)))
    (goto-char (car bounds))
    (when column
      (flexi-table-goto-column column))
    t))

(defun flexi-table--location-at (position)
  "Return a stable table location describing POSITION."
  (save-excursion
    (goto-char (min (max (point-min) position) (point-max)))
    (let* ((id (flexi-table-current-id))
           (bounds (and id (flexi-table--row-bounds id)))
           (column (and id (flexi-table-column-at-point)))
           (column-start
            (and column
                 (or (previous-single-property-change
                      (point) 'flexi-table-column nil
                      (and bounds (car bounds)))
                     (and bounds (car bounds))))))
      (list :id id
            :column column
            :column-offset (and column-start (- (point) column-start))
            :offset (and bounds (- (point) (car bounds)))
            :point (point)))))

(defun flexi-table--goto-location (location)
  "Move point to a previously captured table LOCATION."
  (let ((id (plist-get location :id))
        (column (plist-get location :column))
        (column-offset (plist-get location :column-offset))
        (offset (plist-get location :offset))
        (old-point (plist-get location :point)))
    (cond
     ((and id (flexi-table--goto-id id))
      (when-let* ((bounds (flexi-table--row-bounds id)))
        (goto-char (min (cdr bounds)
                        (+ (car bounds) (or offset 0)))))
      (when column
        (flexi-table-goto-column column)
        (when column-offset
          (goto-char
           (min (+ (point) column-offset)
                (or (next-single-property-change
                     (point) 'flexi-table-column nil
                     (line-end-position))
                    (line-end-position))))))
      t)
     (t
      (goto-char (min (or old-point (point-min)) (point-max)))
      nil))))

(defun flexi-table--capture-position ()
  "Capture point and independent scroll state for every table window."
  (list
   :point (flexi-table--location-at (point))
   :windows
   (mapcar
    (lambda (window)
      (list :window window
            :point (flexi-table--location-at
                    (window-point window))
            :start (flexi-table--location-at
                    (window-start window))
            :hscroll (window-hscroll window)
            :vscroll (window-vscroll window t)))
    (get-buffer-window-list (current-buffer) nil t))))

(defun flexi-table--restore-position (state)
  "Restore cursor and window positions from STATE without sharing anchors."
  (flexi-table--goto-location (plist-get state :point))
  (dolist (window-state (plist-get state :windows))
    (let ((window (plist-get window-state :window)))
      (when (and (window-live-p window)
                 (eq (window-buffer window)
                     (current-buffer)))
        (let ((window-point
               (save-excursion
                 (flexi-table--goto-location
                  (plist-get window-state :point))
                 (point)))
              (window-start
               (save-excursion
                 (flexi-table--goto-location
                  (plist-get window-state :start))
                 (point))))
          (set-window-point window window-point)
          (set-window-start window window-start t)
          (set-window-hscroll window (plist-get window-state :hscroll))
          (set-window-vscroll window
                              (plist-get window-state :vscroll) t))))))

(defmacro flexi-table--preserving-position (&rest body)
  "Run BODY and restore the current table position afterward."
  (declare (indent 0) (debug t))
  `(let ((state (flexi-table--capture-position)))
     (unwind-protect
         (progn ,@body)
       (flexi-table--restore-position state))))

(defun flexi-table--compare-values (a b)
  "Return non-nil when A should sort before B."
  (cond
   ((equal a b) nil)
   ((null a) t)
   ((null b) nil)
   ((and (numberp a) (numberp b)) (< a b))
   ((and (stringp a) (stringp b))
    (string-collate-lessp a b nil t))
   (t (string-collate-lessp (format "%s" a) (format "%s" b) nil t))))

(defun flexi-table--sorter ()
  "Return a predicate for `flexi-table-sort-key'."
  (when-let* ((name (car flexi-table-sort-key))
              (column (flexi-table--find-column name)))
    (let ((descending (cdr flexi-table-sort-key))
          (predicate (plist-get (cdr column) :sort-predicate)))
      (lambda (a b)
        (let ((left (flexi-table--column-value column a))
              (right (flexi-table--column-value column b)))
          (if descending
              (funcall (or predicate #'flexi-table--compare-values)
                       right left)
            (funcall (or predicate #'flexi-table--compare-values)
                     left right)))))))

(defun flexi-table--update-mode-name ()
  "Update `mode-name' to reflect the current table size."
  (setq mode-name
        (if (functionp flexi-table-mode-name-function)
            (funcall flexi-table-mode-name-function
                     (length flexi-table-entries))
          (format "Flexi-Table[%d]"
                  (length flexi-table-entries)))))

(defun flexi-table-print (&optional remember-position)
  "Render all current entries.
When REMEMBER-POSITION is non-nil, preserve the selected row and column."
  (let ((render
         (lambda ()
           (let ((inhibit-read-only t)
                 (entries (seq-copy flexi-table-entries))
                 (sorter (flexi-table--sorter)))
             (when sorter
               (setq entries (sort entries sorter)))
             (flexi-table--clear-row-markers)
             (erase-buffer)
             (clrhash flexi-table--rendered)
             (dolist (entry entries)
               (when (flexi-table--entry-visible-p entry)
                 (flexi-table--render-entry entry)))
             (set-buffer-modified-p nil)
             (flexi-table--update-mode-name)))))
    (if remember-position
        (flexi-table--preserving-position
          (funcall render))
      (funcall render)
      (goto-char (point-min)))))

(defun flexi-table--header-label (column last-column-p)
  "Return the rendered heading for COLUMN.
LAST-COLUMN-P controls whether its trailing width is forced."
  (let* ((name (flexi-table--column-name column))
         (sortable (flexi-table--column-sortable-p column))
         (selected (equal name (car flexi-table-sort-key)))
         (suffix
          (if (not selected)
              ""
            (format " %c"
                    (if (cdr flexi-table-sort-key)
                        flexi-table-gui-sort-indicator-desc
                      flexi-table-gui-sort-indicator-asc))))
         (label (concat name suffix))
         (width (flexi-table--column-width column))
         (align (plist-get (cdr column) :align))
         (label (flexi-table--align-label
                 label width align (not last-column-p)))
         (header-face (or (plist-get (cdr column) :header-face)
                          'flexi-table-header-column))
         (filtered (flexi-table--active-filter (car column)))
         (properties
          (list 'face (delq nil
                            (list 'flexi-table-cell
                             (and selected
                                  'flexi-table-header-column-sorted)
                             (and filtered
                                  'flexi-table-header-column-filtered)
                             header-face))
                'flexi-table-column name
                'flexi-table-field (car column))))
    (when sortable
      (setq properties
            (append properties
                    (list 'mouse-face 'header-line-highlight
                          'help-echo "Click to sort by this column"
                          'keymap flexi-table-header-map))))
    (apply #'propertize label properties)))

(defun flexi-table--header-spacing (width)
  "Return WIDTH spaces with table metrics and header decoration.
`flexi-table-cell' deliberately comes first in the face list.  Header-line
faces are frequently rendered with a proportional UI font, so applying only
`flexi-table-header' here would make every inter-column gap a different pixel
width from the corresponding gap in a row.  The small error would then
accumulate toward the right edge of the table."
  (propertize (make-string width ?\s)
              'face '(flexi-table-cell flexi-table-header)))

(defun flexi-table-render-header ()
  "Return the rendered heading for the current table."
  (let* ((columns flexi-table-columns)
         (last (car (last columns)))
         (parts (list (flexi-table--header-spacing
                       flexi-table-padding))))
    (dolist (column columns)
      (push (flexi-table--header-label column (eq column last)) parts)
      (unless (eq column last)
        (push (flexi-table--header-spacing
               (flexi-table--column-padding column))
              parts)))
    (apply #'concat (nreverse parts))))

(defun flexi-table-init-header ()
  "Install or update the current table heading."
  (when (overlayp flexi-table--header-overlay)
    (delete-overlay flexi-table--header-overlay)
    (setq flexi-table--header-overlay nil))
  (if flexi-table-use-header-line
      (progn
        (setq-local header-line-format
                    (list "" 'header-line-indent
                          (flexi-table-render-header)))
        (setq flexi-table--owns-header-line t))
    ;; A derived mode can reserve the real header line for status information,
    ;; as gh-repo does.  Clear it only when this renderer installed it.
    (when flexi-table--owns-header-line
      (setq-local header-line-format nil)
      (setq flexi-table--owns-header-line nil))
    (let ((overlay (make-overlay (point-min) (point-min))))
      (overlay-put overlay 'after-string
                   (concat (flexi-table-render-header)
                           (propertize
                            "\n" 'face
                            '(flexi-table-cell flexi-table-header))))
      (overlay-put overlay 'flexi-table-header t)
      (setq flexi-table--header-overlay overlay))))

(cl-defun flexi-table-setup
    (columns entries &key key-function available-columns columns-variable
             filter-function mode-name-function sort-key)
  "Configure the current table with COLUMNS and ENTRIES.

KEY-FUNCTION must return a stable identifier for an entry.  AVAILABLE-COLUMNS
may include hidden columns which can later be added interactively.
COLUMNS-VARIABLE, when non-nil, is used by
`flexi-table-save-columns'.  FILTER-FUNCTION is an optional entry
predicate.  MODE-NAME-FUNCTION receives the entry count.  SORT-KEY has the form
\=(COLUMN-NAME . DESCENDING)."
  (unless (derived-mode-p 'flexi-table-mode)
    (flexi-table-mode))
  (flexi-table--cancel-timers)
  (setq-local flexi-table-columns (copy-tree columns)
              flexi-table--initial-columns (copy-tree columns)
              flexi-table-available-columns
              (copy-tree (or available-columns columns))
              flexi-table-entries entries
              flexi-table-key-function key-function
              flexi-table-columns-variable columns-variable
              flexi-table-filter-function filter-function
              flexi-table-filters nil
              flexi-table-mode-name-function mode-name-function
              flexi-table-sort-key sort-key
              flexi-table--current-column nil)
  (flexi-table-init-header)
  (flexi-table-print))

(defun flexi-table-set-entries (entries &optional remember-position)
  "Replace the table with ENTRIES and render it.
REMEMBER-POSITION preserves the selected row and column."
  (flexi-table--clear-pending-updates)
  (setq flexi-table-entries entries)
  (flexi-table-print remember-position))

(defun flexi-table-append-entries (entries)
  "Append new ENTRIES and render only the required rows when possible.
Entries with an existing identifier replace the corresponding object."
  (let ((new nil)
        (updates nil)
        (known (make-hash-table :test #'equal)))
    (dolist (entry flexi-table-entries)
      (puthash (flexi-table--entry-key entry) t known))
    (dolist (entry entries)
      (if (gethash (flexi-table--entry-key entry) known)
          (push entry updates)
        (puthash (flexi-table--entry-key entry) t known)
        (push entry new)))
    (setq new (nreverse new))
    (setq flexi-table-entries
          (nconc flexi-table-entries new))
    (if (or flexi-table-sort-key
            (functionp flexi-table-filter-function)
            flexi-table-filters)
        (flexi-table-print t)
      (flexi-table--preserving-position
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (dolist (entry new)
            (flexi-table--render-entry entry))
          (set-buffer-modified-p nil)
          (flexi-table--update-mode-name))))
    (flexi-table-update-entries (nreverse updates))))

(defun flexi-table--replace-entry-in-data (entry)
  "Replace ENTRY in `flexi-table-entries' by identifier."
  (let ((id (flexi-table--entry-key entry))
        (tail flexi-table-entries)
        found)
    (while (and tail (not found))
      (if (equal id (flexi-table--entry-key (car tail)))
          (progn
            (setcar tail entry)
            (setq found t))
        (setq tail (cdr tail))))
    (unless found
      (setq flexi-table-entries
            (nconc flexi-table-entries (list entry))))
    found))

(defun flexi-table--update-entry-1 (entry)
  "Replace ENTRY without capturing or restoring point.
Return `full' when filtering requires a complete render, or `sort' when the
active ordering should be recomputed after the row replacement."
  (let* ((id (flexi-table--entry-key entry))
         (bounds (flexi-table--row-bounds id)))
    (flexi-table--replace-entry-in-data entry)
    ;; Callers commonly enrich an alist in place.  Consequently the object in
    ;; `flexi-table--rendered' may already compare equal to ENTRY even
    ;; though the text in the buffer still represents its previous contents.
    ;; Always replace an existing row instead of using object equality here.
    (cond
     ((or (functionp flexi-table-filter-function)
          flexi-table-filters)
      'full)
     (bounds
      (let ((inhibit-read-only t))
        (goto-char (car bounds))
        (delete-region (car bounds) (cdr bounds))
        (flexi-table--render-entry entry)
        (set-buffer-modified-p nil))
      (and flexi-table-sort-key 'sort))
     (t
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (flexi-table--render-entry entry)
        (set-buffer-modified-p nil)
        (flexi-table--update-mode-name))
      (and flexi-table-sort-key 'sort)))))

(defun flexi-table-update-entry (entry)
  "Replace one rendered row with the latest version of ENTRY.
For streams of asynchronous updates, prefer
`flexi-table-queue-entry-update'."
  (flexi-table-update-entries (list entry)))

(defun flexi-table-update-entries (entries)
  "Incrementally update ENTRIES in one position-preserving operation."
  (let (refresh)
    (flexi-table--preserving-position
      (dolist (entry entries)
        (let ((result (flexi-table--update-entry-1 entry)))
          (when (or (eq result 'full)
                    (and (eq result 'sort) (not (eq refresh 'full))))
            (setq refresh result)))))
    (pcase refresh
      ('full (flexi-table-print t))
      ('sort (flexi-table--debounce-render)))))

(defun flexi-table-queue-entry-update (entry &optional delay)
  "Queue an asynchronous row update for ENTRY.

Updates received within idle DELAY, or
`flexi-table-async-update-delay', are coalesced and rendered together
without repeatedly moving point or changing window anchors."
  (unless (hash-table-p flexi-table--pending-updates)
    (setq flexi-table--pending-updates
          (make-hash-table :test #'equal)))
  (puthash (flexi-table--entry-key entry) entry
           flexi-table--pending-updates)
  (unless (timerp flexi-table--update-timer)
    (setq flexi-table--update-timer
          (run-with-idle-timer
           (or delay flexi-table-async-update-delay) nil
           #'flexi-table--flush-entry-updates (current-buffer)))))

(defun flexi-table--flush-entry-updates (buffer)
  "Render pending asynchronous row updates in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp flexi-table--update-timer)
        (cancel-timer flexi-table--update-timer))
      (setq flexi-table--update-timer nil)
      (when (and (derived-mode-p 'flexi-table-mode)
                 (hash-table-p flexi-table--pending-updates))
        (let (entries)
          (maphash (lambda (_id entry) (push entry entries))
                   flexi-table--pending-updates)
          (clrhash flexi-table--pending-updates)
          (when entries
            (flexi-table-update-entries (nreverse entries))))))))

(defun flexi-table--clear-pending-updates ()
  "Cancel and discard queued asynchronous row updates."
  (when (timerp flexi-table--update-timer)
    (cancel-timer flexi-table--update-timer))
  (setq flexi-table--update-timer nil)
  (when (hash-table-p flexi-table--pending-updates)
    (clrhash flexi-table--pending-updates)))

(defun flexi-table-remove-entry (id)
  "Remove the entry identified by ID from the data and display."
  (setq flexi-table-entries
        (seq-remove (lambda (entry)
                      (equal id (flexi-table--entry-key entry)))
                    flexi-table-entries))
  (when-let* ((bounds (flexi-table--row-bounds id)))
    (let ((inhibit-read-only t))
      (delete-region (car bounds) (cdr bounds))))
  (remhash id flexi-table--rendered)
  (when-let* ((marker (gethash id flexi-table--row-markers)))
    (set-marker marker nil))
  (remhash id flexi-table--row-markers)
  (set-buffer-modified-p nil)
  (flexi-table--update-mode-name))

(defun flexi-table--cancel-render-timer ()
  "Cancel the pending full render, if any."
  (when (timerp flexi-table--render-timer)
    (cancel-timer flexi-table--render-timer))
  (setq flexi-table--render-timer nil))

(defun flexi-table--cancel-timers ()
  "Cancel all pending renders in the current table buffer."
  (flexi-table--cancel-render-timer)
  (flexi-table--clear-pending-updates))

(defun flexi-table--run-render-timer (buffer)
  "Complete a delayed render in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq flexi-table--render-timer nil)
      (when (derived-mode-p 'flexi-table-mode)
        (flexi-table-print t)))))

(defun flexi-table--debounce-render (&optional delay)
  "Schedule a full table refresh after idle DELAY."
  (flexi-table--cancel-render-timer)
  (setq flexi-table--render-timer
        (run-with-idle-timer
         (or delay flexi-table-resize-idle-delay) nil
         #'flexi-table--run-render-timer (current-buffer))))

(defun flexi-table-goto-column (name)
  "Move point to the beginning of column NAME in the current row."
  (let ((id (flexi-table-current-id)))
    (when-let* ((bounds (and id (flexi-table--row-bounds id))))
      (goto-char (car bounds))
      (let ((limit (cdr bounds))
            found)
        (while (and (< (point) limit) (not found))
          (if (equal name (flexi-table-column-at-point))
              (setq found t)
            (goto-char
             (or (next-single-property-change
                  (point) 'flexi-table-column nil limit)
                 limit))))
        found))))

(defun flexi-table--forward-column (count)
  "Move COUNT column property boundaries in the current row."
  (let* ((id (flexi-table-current-id))
         (bounds (and id (flexi-table--row-bounds id)))
         (forward (> count 0))
         (function (if forward
                       #'next-single-property-change
                     #'previous-single-property-change))
         (limit (and bounds (if forward (cdr bounds) (car bounds)))))
    (when bounds
      (dotimes (_ (abs count))
        (when-let* ((next (funcall function (point)
                                   'flexi-table-column nil limit)))
          (goto-char next))))))

(defun flexi-table-forward-column (&optional count)
  "Move forward COUNT columns on the current row."
  (interactive "p")
  (flexi-table--forward-column (or count 1)))

(defun flexi-table-backward-column (&optional count)
  "Move backward COUNT columns on the current row."
  (interactive "p")
  (flexi-table--forward-column (- (or count 1))))

(defun flexi-table--sort-by-name (name)
  "Sort by column NAME, reversing an already selected column."
  (when-let* ((column (flexi-table--find-column name)))
    (unless (flexi-table--column-sortable-p column)
      (user-error "Column %s is not sortable" name))
    (if (equal name (car flexi-table-sort-key))
        (setcdr flexi-table-sort-key
                (not (cdr flexi-table-sort-key)))
      (setq flexi-table-sort-key (cons name nil)))
    (flexi-table-init-header)
    (flexi-table-print t)))

(defun flexi-table-sort (&optional column-number)
  "Sort by the current column or COLUMN-NUMBER.
A COLUMN-NUMBER of -1 restores unsorted entry order."
  (interactive "P")
  (if (equal column-number -1)
      (progn
        (setq flexi-table-sort-key nil)
        (flexi-table-init-header)
        (flexi-table-print t))
    (let ((column
           (if column-number
               (nth column-number flexi-table-columns)
             (flexi-table--find-column
              (flexi-table--closest-column)))))
      (unless column
        (user-error "No table column at point"))
      (flexi-table--sort-by-name
       (flexi-table--column-name column))
      (when-let* ((buff-wnd (get-buffer-window (current-buffer))))
        (with-selected-window buff-wnd
          (when (save-excursion
                  (and (zerop (forward-line))
                       (goto-char (line-end-position))
                       (eobp)))
            (recenter)))))))

(defun flexi-table-sort-by-click (event)
  "Sort by the column heading clicked in EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (object (posn-object start))
         (position (if object (cdr object) (posn-point start)))
         (string (car-safe object))
         (name (get-text-property position
                                  'flexi-table-column string)))
    (with-current-buffer (window-buffer (posn-window start))
      (flexi-table--sort-by-name name))))

(defun flexi-table--set-column-width (column width)
  "Set COLUMN's character WIDTH."
  (setcdr column (plist-put (cdr column) :width (max 1 width))))

(defun flexi-table--rerender-visible (&optional maximum)
  "Rerender visible rows nearest point.
When MAXIMUM is non-nil, update at most that many unique rows."
  (let* ((window (or (get-buffer-window (current-buffer))
                     (selected-window)))
         (current-id (flexi-table-current-id))
         (start (if (eq (window-buffer window) (current-buffer))
                    (window-start window)
                  (point-min)))
         (end (if (eq (window-buffer window) (current-buffer))
                  (window-end window t)
                (point-max)))
         (position start)
         ids)
    (while (< position end)
      (when-let* ((id (get-text-property position 'flexi-table-id)))
        (unless (member id ids)
          (push id ids)))
      (setq position
            (or (next-single-property-change
                 position 'flexi-table-id nil end)
                end)))
    (setq ids (nreverse ids))
    (when (and maximum (> (length ids) maximum))
      (let* ((index (or (seq-position ids current-id #'equal) 0))
             (beginning (max 0 (- index (/ maximum 2))))
             (beginning (min beginning (- (length ids) maximum))))
        (setq ids (seq-subseq ids beginning (+ beginning maximum)))))
    (dolist (id ids)
      (when-let* ((entry (gethash id flexi-table--rendered)))
        (let ((bounds (flexi-table--row-bounds id))
              (inhibit-read-only t))
          (when bounds
            (goto-char (car bounds))
            (delete-region (car bounds) (cdr bounds))
            (flexi-table--render-entry entry)))))
    (set-buffer-modified-p nil)))

(defun flexi-table-widen-current-column (&optional amount)
  "Increase the width of the current column by AMOUNT characters."
  (interactive "p")
  (setq amount (or amount 1))
  (flexi-table--cancel-render-timer)
  (let* ((name (if (and (memq last-command
                                '(flexi-table-widen-current-column
                                  flexi-table-narrow-current-column))
                         flexi-table--current-column)
                    flexi-table--current-column
                  (flexi-table--closest-column)))
         (column (flexi-table--find-column name)))
    (unless column
      (user-error "No table column at point"))
    (setq flexi-table--current-column name)
    (flexi-table--set-column-width
     column (+ (flexi-table--column-width column) amount))
    (flexi-table--preserving-position
      (pcase flexi-table-resize-strategy
        ('t (flexi-table-print t))
        ('visible (flexi-table--rerender-visible))
        ((pred integerp)
         (flexi-table--rerender-visible
          flexi-table-resize-strategy))
        (_
         (when-let* ((entry (flexi-table-current-entry)))
           (let ((bounds (flexi-table--row-bounds
                          (flexi-table--entry-key entry)))
                 (inhibit-read-only t))
             (when bounds
               (goto-char (car bounds))
               (delete-region (car bounds) (cdr bounds))
               (flexi-table--render-entry entry)))))))
    (flexi-table-init-header)
    (unless (eq flexi-table-resize-strategy t)
      (flexi-table--debounce-render))
    (flexi-table-goto-column name)))

(defun flexi-table-narrow-current-column (&optional amount)
  "Decrease the width of the current column by AMOUNT characters."
  (interactive "p")
  (flexi-table-widen-current-column (- (or amount 1))))

(defun flexi-table--refresh-layout (&optional column-name)
  "Refresh the heading and rows, then return to COLUMN-NAME."
  (flexi-table-init-header)
  (flexi-table-print t)
  (when column-name
    (flexi-table-goto-column column-name)))

(defun flexi-table--move-column (offset)
  "Move the current column by OFFSET places."
  (let* ((name (flexi-table--closest-column))
         (column (flexi-table--find-column name))
         (index (seq-position flexi-table-columns column))
         (length (length flexi-table-columns)))
    (unless index
      (user-error "No table column at point"))
    (let* ((target (mod (+ index offset) length))
           (copy (copy-sequence flexi-table-columns))
           (other (nth target copy)))
      (setf (nth index copy) other
            (nth target copy) column)
      (setq flexi-table-columns copy)
      (flexi-table--refresh-layout name))))

(defun flexi-table-move-column-right (&optional count)
  "Move the current column right by COUNT places."
  (interactive "p")
  (flexi-table--move-column (or count 1)))

(defun flexi-table-move-column-left (&optional count)
  "Move the current column left by COUNT places."
  (interactive "p")
  (flexi-table--move-column (- (or count 1))))

(defun flexi-table-add-column (name)
  "Add the available column NAME after the column at point."
  (interactive
   (list
    (let* ((active (mapcar #'flexi-table--column-name
                           flexi-table-columns))
           (available
            (seq-remove
             (lambda (column)
               (member (flexi-table--column-name column) active))
             flexi-table-available-columns)))
      (unless available
        (user-error "There are no hidden columns to add"))
      (completing-read
       "Add column: "
       (mapcar #'flexi-table--column-name available) nil t))))
  (let* ((column (copy-tree
                  (flexi-table--find-column
                   name flexi-table-available-columns)))
         (current (flexi-table--find-column
                   (flexi-table--closest-column)))
         (index (and current
                     (seq-position flexi-table-columns current))))
    (unless column
      (user-error "Unknown column %s" name))
    (setq flexi-table-columns
          (append (seq-take flexi-table-columns (1+ (or index -1)))
                  (list column)
                  (seq-drop flexi-table-columns (1+ (or index -1)))))
    (flexi-table--refresh-layout name)))

(defun flexi-table-remove-column (name)
  "Remove the active column NAME from the current table."
  (interactive
   (list
    (completing-read
     "Remove column: "
     (mapcar #'flexi-table--column-name
             flexi-table-columns)
     nil t (flexi-table--closest-column))))
  (when (= (length flexi-table-columns) 1)
    (user-error "Cannot remove the table's only column"))
  (setq flexi-table-columns
        (seq-remove
         (lambda (column)
           (equal name (flexi-table--column-name column)))
         flexi-table-columns))
  (when (equal name (car flexi-table-sort-key))
    (setq flexi-table-sort-key nil))
  (flexi-table--refresh-layout))

(defun flexi-table-current-column-spec ()
  "Return the column selected by the menu or nearest point."
  (flexi-table--find-column
   (or flexi-table--current-column
       (flexi-table--closest-column))))

(defun flexi-table-select-current-column ()
  "Select the column nearest point for subsequent column operations."
  (setq flexi-table--current-column
        (flexi-table--closest-column)))

(defun flexi-table-switch-column ()
  "Select the next table column, or read one when the table is wide."
  (interactive)
  (let* ((names (mapcar #'flexi-table--column-name
                        flexi-table-columns))
         (index (or (seq-position names
                                  flexi-table--current-column
                                  #'equal)
                    -1))
         (next
          (if (> (length names)
                 flexi-table-column-comp-read-threshold)
              (completing-read "Column: " names nil t nil nil
                               flexi-table--current-column)
            (nth (mod (1+ index)
                      (length names))
                 names))))
    (setq flexi-table--current-column next)
    (flexi-table-goto-column next)))

(defun flexi-table-set-current-column-name ()
  "Rename the currently selected column."
  (interactive)
  (when-let* ((column (flexi-table-current-column-spec)))
    (let* ((old-name (flexi-table--column-name column))
           (new-name (read-string "Column name: " old-name)))
      (setcdr column (plist-put (cdr column) :name new-name))
      (when (equal old-name (car flexi-table-sort-key))
        (setcar flexi-table-sort-key new-name))
      (setq flexi-table--current-column new-name)
      (flexi-table--refresh-layout new-name))))

(defun flexi-table-set-current-column-width ()
  "Read and set the selected column width."
  (interactive)
  (when-let* ((column (flexi-table-current-column-spec)))
    (flexi-table--set-column-width
     column
     (read-number "Column width: "
                  (flexi-table--column-width column)))
    (flexi-table--refresh-layout
     (flexi-table--column-name column))))

(defun flexi-table-cycle-current-column-alignment ()
  "Cycle the selected column through left, center, and right alignment."
  (interactive)
  (when-let* ((column (flexi-table-current-column-spec)))
    (let* ((props (cdr column))
           (current (plist-get props :align))
           (next (pcase current
                   ((or 'center "center") "right")
                   ((or 'right "right") "left")
                   (_ "center"))))
      (setcdr column (plist-put props :align next))
      (flexi-table--refresh-layout
       (flexi-table--column-name column)))))

(defun flexi-table-toggle-current-column-sortable ()
  "Toggle whether the selected column can be sorted."
  (interactive)
  (when-let* ((column (flexi-table-current-column-spec)))
    (let ((name (flexi-table--column-name column)))
      (setcdr column
              (plist-put (cdr column) :sortable
                         (not (flexi-table--column-sortable-p
                               column))))
      (when (and (not (flexi-table--column-sortable-p column))
                 (equal name (car flexi-table-sort-key)))
        (setq flexi-table-sort-key nil))
      (flexi-table--refresh-layout name))))

(defun flexi-table-set-current-column-padding ()
  "Read and set the selected column's right padding."
  (interactive)
  (when-let* ((column (flexi-table-current-column-spec)))
    (setcdr column
            (plist-put
             (cdr column) :pad-right
             (max 0 (read-number
                     "Right padding: "
                     (flexi-table--column-padding column)))))
    (flexi-table--refresh-layout
     (flexi-table--column-name column))))

(defun flexi-table-sort-current-column ()
  "Sort by the column selected in the column menu."
  (interactive)
  (if flexi-table--current-column
      (flexi-table--sort-by-name
       flexi-table--current-column)
    (flexi-table-sort)))

(defun flexi-table-remove-current-column ()
  "Remove the column selected in the column menu."
  (interactive)
  (let ((name (or flexi-table--current-column
                  (flexi-table--closest-column))))
    (flexi-table-remove-column name)
    (setq flexi-table--current-column
          (flexi-table--closest-column))))

(defun flexi-table-reset-columns ()
  "Restore the initial or default column layout for the current table."
  (interactive)
  (setq flexi-table-columns
        (copy-tree
         (if (and flexi-table-columns-variable
                  (boundp flexi-table-columns-variable))
             (default-value flexi-table-columns-variable)
           flexi-table--initial-columns))
        flexi-table-sort-key nil
        flexi-table--current-column nil)
  (flexi-table--refresh-layout)
  (flexi-table-select-current-column))

(defun flexi-table--filter-column-at-point ()
  "Return the filterable column at or nearest point."
  (when-let* ((column (flexi-table--find-column
                       (flexi-table--closest-column))))
    (and (flexi-table--column-filterable-p column) column)))

(defun flexi-table--filter-at-point-p ()
  "Return non-nil when point is on or near a filterable cell."
  (and (flexi-table-current-entry)
       (flexi-table--filter-column-at-point)))

(defun flexi-table--has-filters-p ()
  "Return non-nil when the current table has active column filters."
  (and flexi-table-filters t))

(defun flexi-table--replace-filter (field value)
  "Set the active filter for FIELD to VALUE without rendering."
  (setq flexi-table-filters
        (cons (cons field value)
              (seq-remove (lambda (filter)
                            (equal field (car filter)))
                          flexi-table-filters))))

(defun flexi-table--refresh-filters ()
  "Refresh headings and rows after a filter state change."
  (flexi-table-init-header)
  (flexi-table-print t))

(defun flexi-table-toggle-filter (field value)
  "Toggle an equality filter for FIELD and VALUE.

If FIELD already filters by VALUE, remove that filter.  Otherwise replace the
column's previous filter.  Columns can provide `:filter-predicate' when equality
does not express the desired matching behavior."
  (when-let* ((column (flexi-table--find-column-by-field field)))
    (unless (flexi-table--column-filterable-p column)
      (user-error "Column %s is not filterable"
                  (flexi-table--column-name column)))
    (let ((active (flexi-table--active-filter field))
          (name (flexi-table--column-name column))
          (label (flexi-table--filter-value-label column value)))
      (if (and active (equal (cdr active) value))
          (progn
            (setq flexi-table-filters (delq active flexi-table-filters))
            (message "Removed filter for %s" name))
        (flexi-table--replace-filter field value)
        (message "Filtering %s by %s" name label))
      (flexi-table--refresh-filters))))

(defun flexi-table-toggle-filter-at-point ()
  "Toggle a filter using the raw value of the cell at point."
  (interactive)
  (unless (flexi-table-current-entry)
    (user-error "No table row at point"))
  (if-let* ((column (flexi-table--filter-column-at-point)))
      (flexi-table-toggle-filter
       (car column)
       (flexi-table--column-value column
                                  (flexi-table-current-entry)))
    (user-error "The current column is not filterable")))

(defun flexi-table--read-filter-column (&optional active-only)
  "Read a filterable column, restricted to active filters when ACTIVE-ONLY."
  (let* ((columns
          (if active-only
              (delq nil
                    (mapcar
                     (lambda (filter)
                       (flexi-table--find-column-by-field (car filter)))
                     flexi-table-filters))
            (flexi-table--filterable-columns)))
         (names (mapcar #'flexi-table--column-name columns)))
    (unless columns
      (user-error (if active-only
                      "There are no active filters"
                    "There are no filterable columns")))
    (let ((name (completing-read
                 (if active-only "Remove filter: " "Filter column: ")
                 names nil t)))
      (flexi-table--find-column name columns))))

(defun flexi-table--filter-value-records (column)
  "Return display, raw value, and count records for COLUMN."
  (let (counts)
    (dolist (entry flexi-table-entries)
      (let* ((value (flexi-table--column-value column entry))
             (cell (cl-assoc value counts :test #'equal)))
        (if cell
            (setcdr cell (1+ (cdr cell)))
          (push (cons value 1) counts))))
    (let (records used-labels)
      (dolist (cell counts)
        (let* ((value (car cell))
               (base (flexi-table--filter-value-label column value))
               (label base)
               (index 2))
          (while (member label used-labels)
            (setq label (format "%s [%d]" base index)
                  index (1+ index)))
          (push label used-labels)
          (push (list label value (cdr cell)) records)))
      (sort records
            (lambda (left right)
              (string-collate-lessp (car left) (car right) nil t))))))

(defun flexi-table--read-filter-value (column)
  "Read one of COLUMN's values from the table's complete entry set."
  (let* ((records (flexi-table--filter-value-records column))
         (active (flexi-table--active-filter (car column))))
    (unless records
      (user-error "The table has no values for %s"
                  (flexi-table--column-name column)))
    (let* ((completion-extra-properties
            `(:annotation-function
              ,(lambda (candidate)
                 (when-let* ((record (assoc-string candidate records)))
                   (format "  %d row%s%s"
                           (nth 2 record)
                           (if (= (nth 2 record) 1) "" "s")
                           (if (and active
                                    (equal (cadr record) (cdr active)))
                               " (active)"
                             ""))))))
           (initial
            (and active
                 (car (seq-find
                       (lambda (record)
                         (equal (cadr record) (cdr active)))
                       records))))
           (choice (completing-read
                    (format "%s value: "
                            (flexi-table--column-name column))
                    (mapcar #'car records) nil t nil nil initial)))
      (cadr (assoc-string choice records)))))

(defun flexi-table-set-filter (column value)
  "Set COLUMN's filter to VALUE, replacing any previous value."
  (interactive
   (let ((column (flexi-table--read-filter-column)))
     (list column (flexi-table--read-filter-value column))))
  (unless (consp column)
    (setq column (flexi-table--find-column-by-field column)))
  (unless (flexi-table--column-filterable-p column)
    (user-error "Column is not filterable"))
  (flexi-table--replace-filter (car column) value)
  (message "Filtering %s by %s"
           (flexi-table--column-name column)
           (flexi-table--filter-value-label column value))
  (flexi-table--refresh-filters))

(defun flexi-table-remove-filter (column)
  "Remove the active filter associated with COLUMN."
  (interactive (list (flexi-table--read-filter-column t)))
  (unless (consp column)
    (setq column (flexi-table--find-column-by-field column)))
  (when column
    (setq flexi-table-filters
          (seq-remove (lambda (filter)
                        (equal (car column) (car filter)))
                      flexi-table-filters))
    (message "Removed filter for %s" (flexi-table--column-name column))
    (flexi-table--refresh-filters)))

(defun flexi-table-reset-filters ()
  "Remove every declarative column filter from the current table."
  (interactive)
  (setq flexi-table-filters nil)
  (message "Reset table filters")
  (flexi-table--refresh-filters))

(defun flexi-table--filter-at-point-description ()
  "Describe the filter action available at point."
  (if-let* ((entry (flexi-table-current-entry))
            (column (flexi-table--filter-column-at-point)))
      (concat
       "Filter by cell: "
       (propertize
        (format "%s = %s"
                (flexi-table--column-name column)
                (flexi-table--filter-value-label
                 column (flexi-table--column-value column entry)))
        'face 'transient-value))
    "Filter by cell"))

(defun flexi-table--active-filters-description ()
  "Return a styled summary of active declarative filters."
  (if (not flexi-table-filters)
      "Filters — active: none"
    (concat
     "Filters — active: "
     (mapconcat
      (lambda (filter)
        (if-let* ((column (flexi-table--find-column-by-field (car filter))))
            (propertize
             (format "%s = %s"
                     (flexi-table--column-name column)
                     (flexi-table--filter-value-label column (cdr filter)))
             'face 'transient-value)
          (format "%s" (car filter))))
      (reverse flexi-table-filters)
      (propertize " | " 'face 'transient-inactive-value)))))

;;;###autoload (autoload 'flexi-table-filters-menu "flexi-table" nil t)
(transient-define-prefix flexi-table-filters-menu ()
  "Filter rows using declaratively filterable table columns."
  [:description flexi-table--active-filters-description
   ("f" flexi-table-toggle-filter-at-point
    :description flexi-table--filter-at-point-description
    :inapt-if-not flexi-table--filter-at-point-p
    :transient t)
   ("c" "Set column filter" flexi-table-set-filter :transient t)
   ("-" "Remove one filter" flexi-table-remove-filter
    :inapt-if-not flexi-table--has-filters-p
    :transient t)
   ("r" "Reset all filters" flexi-table-reset-filters
    :inapt-if-not flexi-table--has-filters-p
    :transient t)
   ("RET" "Done" ignore)]
  (interactive)
  (transient-setup #'flexi-table-filters-menu))

(defun flexi-table--column-menu-description ()
  "Return a styled, multiline description of the active columns."
  (let* ((label "Column: ")
         (limit (max 24 flexi-table-menu-column-line-width))
         (indent (make-string (+ 4 (string-width label)) ?\s))
         (separator (propertize " | " 'face 'transient-inactive-value))
         (opening (propertize "[" 'face 'transient-inactive-value))
         (closing (propertize "]" 'face 'transient-inactive-value))
         (result (concat label opening))
         (line-width (1+ (string-width label)))
         first)
    (dolist (column flexi-table-columns)
      (let* ((name (flexi-table--column-name column))
             (styled
              (propertize
               name 'face
               (if (equal name flexi-table--current-column)
                   'transient-value
                 'transient-inactive-value)))
             (addition-width (+ (if first (string-width separator) 0)
                                (string-width name))))
        (if (and first (> (+ line-width addition-width) limit))
            (setq result (concat result "\n" indent styled)
                  line-width (string-width name))
          (setq result (concat result (if first separator "") styled)
                line-width (+ line-width addition-width)))
        (setq first t)))
    (concat result closing)))

(defun flexi-table--menu-value (value &optional fallback)
  "Return VALUE highlighted for a transient description.
Use FALLBACK as its display value when VALUE is nil."
  (propertize (format "%s" (or value fallback ""))
              'face (if value 'transient-value 'transient-unreachable)))

(defun flexi-table--current-column-name-description ()
  "Describe the current column's rename action."
  (concat "Rename "
          (flexi-table--menu-value
           flexi-table--current-column "(No column)")))

(defun flexi-table--current-column-width-description ()
  "Describe the current column's width."
  (if-let* ((column (flexi-table-current-column-spec)))
      (concat "Width: "
              (flexi-table--menu-value
               (flexi-table--column-width column)))
    "Width: (No column)"))

(defun flexi-table--resize-column-description (verb)
  "Describe resizing the current column using VERB."
  (if-let* ((column (flexi-table-current-column-spec)))
      (concat verb " width: "
              (flexi-table--menu-value
               (flexi-table--column-width column)))
    (concat verb " width: (No column)")))

(defun flexi-table--increase-column-description ()
  "Describe increasing the current column's width."
  (flexi-table--resize-column-description "Increase"))

(defun flexi-table--decrease-column-description ()
  "Describe decreasing the current column's width."
  (flexi-table--resize-column-description "Decrease"))

(defun flexi-table--current-column-sortable-description ()
  "Describe the current column's sortability."
  (if-let* ((column (flexi-table-current-column-spec)))
      (let* ((props (cdr column))
             (sortable (flexi-table--column-sortable-p column))
             (predicate (and sortable
                             (plist-get props :sort-predicate))))
        (concat "Toggle sortable: "
                (flexi-table--menu-value
                 (and sortable (or predicate t)) "nil")))
    "Toggle sortable: (No column)"))

(defun flexi-table--current-column-formatter-description ()
  "Describe the current column's value formatter."
  (if-let* ((column (flexi-table-current-column-spec)))
      (let* ((formatter (plist-get (cdr column) :formatter))
             (display
              (cond
               ((symbolp formatter) formatter)
               ((stringp formatter) formatter)
               ((functionp formatter) "#<function>")
               (t nil))))
        (concat "Formatter: "
                (flexi-table--menu-value display "default")))
    "Formatter: (No column)"))

(defun flexi-table--current-column-alignment-description ()
  "Describe the current column's alignment as a styled choice list."
  (if-let* ((column (flexi-table-current-column-spec)))
      (let* ((current (or (plist-get (cdr column) :align) "left"))
             (current (if (symbolp current) (symbol-name current) current))
             (separator (propertize " | " 'face 'transient-inactive-value)))
        (concat
         "Alignment: "
         (propertize "[" 'face 'transient-inactive-value)
         (mapconcat
          (lambda (alignment)
            (propertize alignment 'face
                        (if (equal alignment current)
                            'transient-value
                          'transient-inactive-value)))
          '("left" "center" "right") separator)
         (propertize "]" 'face 'transient-inactive-value)))
    "Alignment: (No column)"))

(defun flexi-table--current-column-padding-description ()
  "Describe the current column's right padding."
  (if-let* ((column (flexi-table-current-column-spec)))
      (concat "Right padding: "
              (flexi-table--menu-value
               (flexi-table--column-padding column)))
    "Right padding: (No column)"))

(defun flexi-table--current-column-description ()
  "Return a multiline transient description of the selected column."
  (mapconcat
   #'identity
   (list (flexi-table--current-column-name-description)
         (flexi-table--current-column-width-description)
         (flexi-table--current-column-sortable-description)
         (flexi-table--current-column-formatter-description)
         (flexi-table--current-column-alignment-description)
         (flexi-table--current-column-padding-description))
   "\n"))

(defun flexi-table--sort-current-column-description ()
  "Describe sorting by the current menu column."
  (let ((name (or flexi-table--current-column "(No column)")))
    (concat
     (if (equal name (car flexi-table-sort-key))
         "Reverse sort: "
       "Sort by: ")
     (flexi-table--menu-value name))))

(defun flexi-table--columns-saveable-p ()
  "Return non-nil when this table's column layout can be saved."
  (and flexi-table-columns-variable
       (custom-variable-p flexi-table-columns-variable)))

(defun flexi-table-maybe-resume-columns-menu ()
  "Resume the columns menu when it is the current transient command."
  (when (eq transient-current-command
            'flexi-table-columns-menu)
    (transient-setup transient-current-command)))

;;;###autoload (autoload 'flexi-table-columns-menu "flexi-table" nil t)
(transient-define-prefix flexi-table-columns-menu ()
  "Edit the current dynamic table's column layout."
  :refresh-suffixes t
  ["Edit column"
   ("c" flexi-table-switch-column
    :description flexi-table--column-menu-description
    :transient t)]
  [["Properties"
    ("n" flexi-table-set-current-column-name
     :description
     flexi-table--current-column-name-description
     :transient t)
    ("w" flexi-table-set-current-column-width
     :description
     flexi-table--current-column-width-description
     :transient t)
    ("<right>" flexi-table-widen-current-column
     :description
     flexi-table--increase-column-description
     :transient t)
    ("<left>" flexi-table-narrow-current-column
     :description
     flexi-table--decrease-column-description
     :transient t)
    ""
    ("u" flexi-table-toggle-current-column-sortable
     :description
     flexi-table--current-column-sortable-description
     :transient t)
    ("f" ignore
     :description
     flexi-table--current-column-formatter-description)
    ("a" flexi-table-cycle-current-column-alignment
     :description
     flexi-table--current-column-alignment-description
     :transient t)
    ("p" flexi-table-set-current-column-padding
     :description
     flexi-table--current-column-padding-description
     :transient t)]
   [:class transient-column
    :if (lambda () flexi-table-menu-extra-suffixes)
    :description (lambda ()
                   (if (functionp flexi-table-menu-extra-suffixes-description)
                       (funcall flexi-table-menu-extra-suffixes-description)
                     flexi-table-menu-extra-suffixes-description))
    :setup-children
    (lambda (&rest _)
      (transient-parse-suffixes
       (oref transient--prefix
             command)
       flexi-table-menu-extra-suffixes))]]
  [["Layout"
    ("M-<left>" "Move left" flexi-table-move-column-left
     :transient t)
    ("M-<right>" "Move right" flexi-table-move-column-right
     :transient t)
    ("+" "Add column" flexi-table-add-column :transient t)
    ("-" "Remove column" flexi-table-remove-current-column
     :transient t)]]
  [["Sort"
    ("s" flexi-table-sort-current-column
     :description flexi-table--sort-current-column-description
     :transient t)
    ("0" "Restore original order"
     (lambda ()
       (interactive)
       (flexi-table-sort -1))
     :transient t)]
   ["Settings"
    ("R" "Reset layout" flexi-table-reset-columns :transient t)
    ("S" "Save layout" flexi-table-save-columns
     :inapt-if-not flexi-table--columns-saveable-p
     :transient t)]]
  (interactive)
  (flexi-table-select-current-column)
  (transient-setup #'flexi-table-columns-menu))

(defun flexi-table-edit-column (operation)
  "Apply an interactive edit OPERATION to the column at point."
  (interactive
   (list
    (intern
     (completing-read
      "Edit column: " '("width" "name" "alignment" "sortable") nil t))))
  (flexi-table-select-current-column)
  (pcase operation
    ('width (flexi-table-set-current-column-width))
    ('name (flexi-table-set-current-column-name))
    ('alignment (flexi-table-cycle-current-column-alignment))
    ('sortable (flexi-table-toggle-current-column-sortable))))

(defun flexi-table-save-columns ()
  "Save the active column layout to its configured Custom variable."
  (interactive)
  (unless (and flexi-table-columns-variable
               (custom-variable-p flexi-table-columns-variable))
    (user-error "This table is not associated with a Custom variable"))
  (customize-save-variable flexi-table-columns-variable
                           flexi-table-columns)
  (message "Saved columns to %s" flexi-table-columns-variable))

(provide 'flexi-table)
;;; flexi-table.el ends here

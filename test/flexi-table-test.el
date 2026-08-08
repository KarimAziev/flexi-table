;;; flexi-table-test.el --- Tests for flexi-table -*- lexical-binding: t -*-

(require 'ert)
(require 'flexi-table)

(defconst flexi-table-test--columns
  '((name :name "Name" :width 12)
    (score :name "Score" :width 5 :align "right"))
  "Columns used by the renderer tests.")

(defun flexi-table-test--key (entry)
  "Return the ID of test ENTRY."
  (alist-get 'id entry))

(ert-deftest flexi-table-renders-and-finds-current-entry ()
  (with-temp-buffer
    (let ((first '((id . 1) (name . "alpha") (score . 2)))
          (second '((id . 2) (name . "beta") (score . 10))))
      (flexi-table-setup
       flexi-table-test--columns (list first second)
       :key-function #'flexi-table-test--key)
      (goto-char (point-min))
      (should (eq (flexi-table-current-entry) first))
      (should (equal (flexi-table-current-id) 1))
      (should (string-match-p "alpha" (buffer-string)))
      (should (= (line-number-at-pos (point-max)) 3)))))

(ert-deftest flexi-table-updates-an-alist-mutated-in-place ()
  (with-temp-buffer
    (let ((entry '((id . 1) (name . "before") (score . 2))))
      (flexi-table-setup
       flexi-table-test--columns (list entry)
       :key-function #'flexi-table-test--key)
      (goto-char (point-min))
      (search-forward "before")
      (setf (alist-get 'name entry) "after")
      (flexi-table-update-entry entry)
      (should (string-match-p "after" (buffer-string)))
      (should-not (string-match-p "before" (buffer-string)))
      (should (= (length flexi-table-entries) 1))
      (should (equal (flexi-table-current-id) 1)))))

(ert-deftest flexi-table-column-action-receives-cell-context ()
  (with-temp-buffer
    (let* ((entry '((id . 1) (owner (login . "octocat"))))
           called)
      (flexi-table-setup
       `(((owner login)
          :name "Owner"
          :width 16
          :action ,(lambda (value row table)
                     (setq called (list value row table)))))
       (list entry)
       :key-function #'flexi-table-test--key)
      (goto-char (point-min))
      (search-forward "octocat")
      (let ((button (button-at (1- (point)))))
        (should button)
        (should (equal (button-get button 'face)
                       '(flexi-table-cell flexi-table-action-button)))
        (button-activate button))
      (should (equal (car called) "octocat"))
      (should (eq (cadr called) entry))
      (should (eq (caddr called) (current-buffer))))))

(ert-deftest flexi-table-sorts-numeric-columns ()
  (with-temp-buffer
    (flexi-table-setup
     flexi-table-test--columns
     '(((id . 1) (name . "low") (score . 2))
       ((id . 2) (name . "high") (score . 10)))
     :key-function #'flexi-table-test--key)
    (flexi-table--sort-by-name "Score")
    (goto-char (point-min))
    (should (equal (flexi-table-current-id) 1))
    (flexi-table--sort-by-name "Score")
    (goto-char (point-min))
    (should (equal (flexi-table-current-id) 2))))

(ert-deftest flexi-table-edits-column-layout-locally ()
  (with-temp-buffer
    (flexi-table-setup
     flexi-table-test--columns
     '(((id . 1) (name . "alpha") (score . 2)))
     :key-function #'flexi-table-test--key)
    (goto-char (point-min))
    (flexi-table-goto-column "Name")
    (let ((width (flexi-table--column-width
                  (flexi-table--find-column "Name"))))
      (let ((flexi-table-resize-strategy t))
        (flexi-table-widen-current-column 3))
      (should (= (+ width 3)
                 (flexi-table--column-width
                  (flexi-table--find-column "Name")))))
    (flexi-table-remove-column "Score")
    (should-not (flexi-table--find-column "Score"))
    (flexi-table-add-column "Score")
    (should (flexi-table--find-column "Score"))))

(ert-deftest flexi-table-preserves-an-external-header-line ()
  (with-temp-buffer
    (flexi-table-mode)
    (setq-local flexi-table-use-header-line nil)
    (setq-local header-line-format '("External status"))
    (flexi-table-setup
     flexi-table-test--columns nil
     :key-function #'flexi-table-test--key)
    (should (equal header-line-format '("External status")))
    (should-not flexi-table--owns-header-line)
    (should (overlayp flexi-table--header-overlay))
    (flexi-table-append-entries
     '(((id . 1) (name . "alpha") (score . 2))))
    (should (equal header-line-format '("External status")))
    (should (= (overlay-start flexi-table--header-overlay)
               (point-min)))))

(ert-deftest flexi-table-overlay-header-has-column-and-state-faces ()
  (with-temp-buffer
    (flexi-table-mode)
    (setq-local flexi-table-use-header-line nil)
    (flexi-table-setup
     '((name :name "Name" :width 12)
       (language :name "Lang" :width 10 :filterable t))
     '(((id . 1) (name . "one") (language . "Elisp"))
       ((id . 2) (name . "two") (language . "Rust")))
     :key-function #'flexi-table-test--key)
    (let* ((header (overlay-get flexi-table--header-overlay 'after-string))
           (name-position (string-match "Name" header)))
      (let ((faces (ensure-list
                    (get-text-property name-position 'face header))))
        (should (eq (car faces) 'flexi-table-cell))
        (should (memq 'flexi-table-header-column faces))))
    (goto-char (point-min))
    (should (memq 'flexi-table-cell
                  (ensure-list (get-text-property (point) 'face))))
    (flexi-table--sort-by-name "Name")
    (let* ((header (overlay-get flexi-table--header-overlay 'after-string))
           (name-position (string-match "Name" header)))
      (should (memq 'flexi-table-header-column-sorted
                    (ensure-list
                     (get-text-property name-position 'face header)))))
    (flexi-table-toggle-filter 'language "Elisp")
    (let* ((header (overlay-get flexi-table--header-overlay 'after-string))
           (lang-position (string-match "Lang" header)))
      (should (memq 'flexi-table-header-column-filtered
                    (ensure-list
                     (get-text-property lang-position 'face header)))))))

(ert-deftest flexi-table-real-header-line-uses-fixed-pitch-metrics ()
  (with-temp-buffer
    (flexi-table-setup
     flexi-table-test--columns
     '(((id . 1) (name . "alpha") (score . 2)))
     :key-function #'flexi-table-test--key)
    (let* ((header (nth 2 header-line-format))
           (name-position (string-match "Name" header))
           (faces (ensure-list
                   (get-text-property name-position 'face header))))
      (should (eq (car faces) 'flexi-table-cell))
      (should (memq 'flexi-table-header-column faces)))))

(ert-deftest flexi-table-header-spacing-uses-cell-metrics ()
  (with-temp-buffer
    (flexi-table-mode)
    (setq-local flexi-table-use-header-line nil)
    (flexi-table-setup
     '((name :name "Name" :width 12 :pad-right 3)
       (language :name "Lang" :width 10 :filterable t)
       (score :name "Score" :width 5 :align right))
     '(((id . 1) (name . "one") (language . "Elisp") (score . 2)))
     :key-function #'flexi-table-test--key)
    (let* ((header (overlay-get flexi-table--header-overlay 'after-string))
           (body (buffer-substring (point-min) (line-end-position))))
      ;; Column starts must be identical character positions in both strings.
      (dolist (column flexi-table-columns)
        (let ((field (car column)))
          (should
           (= (text-property-any 0 (length header)
                                 'flexi-table-field field header)
              (text-property-any 0 (length body)
                                 'flexi-table-field field body)))))
      ;; Initial padding and every gap between columns must use the same metric
      ;; face as the row.  The decorative header face is intentionally second.
      (dotimes (position (1- (length header)))
        (unless (get-text-property position 'flexi-table-field header)
          (should
           (equal (ensure-list (get-text-property position 'face header))
                  '(flexi-table-cell flexi-table-header))))))))

(ert-deftest flexi-table-declarative-cell-filters-are-clickable-and-composable ()
  (with-temp-buffer
    (let ((columns
           '((name :name "Name" :width 9)
             (language :name "Lang" :width 12 :filterable t)
             (fork :name "Fork" :width 4 :align "right" :filterable t
                   :formatter (lambda (value) (if value "Yes" "No")))))
          (entries
           '(((id . 1) (name . "one") (language . "Elisp") (fork . t))
             ((id . 2) (name . "two") (language . "Rust") (fork))
             ((id . 3) (name . "three") (language . "Elisp") (fork)))))
      (flexi-table-setup
       columns entries :key-function #'flexi-table-test--key)
      (should (eq (key-binding (kbd "f"))
                  #'flexi-table-toggle-filter-at-point))
      (should (eq (key-binding (kbd "/"))
                  #'flexi-table-filters-menu))
      (goto-char (point-min))
      (search-forward "Elisp")
      (let ((button (button-at (1- (point)))))
        (should button)
        (button-activate button))
      (should (equal flexi-table-filters '((language . "Elisp"))))
      (should (= (hash-table-count flexi-table--rendered) 2))
      (should-not (string-match-p "two" (buffer-string)))
      (goto-char (point-min))
      (flexi-table-goto-column "Fork")
      (flexi-table-toggle-filter-at-point)
      (should (= (length flexi-table-filters) 2))
      (should (= (hash-table-count flexi-table--rendered) 1))
      (should (string-match-p "one" (buffer-string)))
      (flexi-table-reset-filters)
      (should-not flexi-table-filters)
      (should (= (hash-table-count flexi-table--rendered) 3)))))

(ert-deftest flexi-table-collection-values-are-independent-filter-buttons ()
  (with-temp-buffer
    (flexi-table-setup
     '((name :name "Name" :width 10)
       (topics :name "Topics" :width 24 :filter-values t))
     '(((id . 1) (name . "one") (topics . ["elisp" "tables"]))
       ((id . 2) (name . "two") (topics "elisp" "github"))
       ((id . 3) (name . "three") (topics . ["rust"])))
     :key-function #'flexi-table-test--key)
    (goto-char (point-min))
    (search-forward "tables")
    (let ((button (button-at (1- (point)))))
      (should button)
      (should (equal (button-get button 'flexi-table-filter-value) "tables"))
      (button-activate button))
    (should (equal flexi-table-filters '((topics . "tables"))))
    (should (= (hash-table-count flexi-table--rendered) 1))
    (should (string-match-p "one" (buffer-string)))
    (flexi-table-reset-filters)
    (goto-char (point-min))
    (search-forward ",")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "elisp")))
      (flexi-table-toggle-filter-at-point))
    (should (equal flexi-table-filters '((topics . "elisp"))))
    (should (= (hash-table-count flexi-table--rendered) 2))
    (flexi-table-reset-filters)
    (let ((records (flexi-table--filter-value-records
                    (flexi-table--find-column "Topics"))))
      (should (equal (mapcar #'car records)
                     '("elisp" "github" "rust" "tables")))
      (should (= (nth 2 (assoc "elisp" records)) 2)))))

(ert-deftest flexi-table-column-menu-uses-structured-descriptions ()
  (with-temp-buffer
    (let ((columns
           (cl-loop for number from 1 to 9
                    collect
                    (list (intern (format "field-%d" number))
                          :name (format "Long column %d" number)
                          :width (+ 10 number)))))
      (flexi-table-setup
       columns '(((id . 1)))
       :key-function #'flexi-table-test--key)
      (setq flexi-table--current-column "Long column 1")
      (let ((flexi-table-menu-column-line-width 42)
            (description
             (flexi-table--column-menu-description)))
        (should (string-match-p "\n" description))
        (should (eq (get-text-property
                     (string-match "Long column 1" description)
                     'face description)
                    'transient-value)))
      (should (equal
               (substring-no-properties
                (flexi-table--current-column-description))
               (mapconcat
                #'identity
                '("Rename Long column 1"
                  "Width: 11"
                  "Toggle sortable: t"
                  "Formatter: default"
                  "Alignment: [left | center | right]"
                  "Right padding: 1")
                "\n"))))))

(ert-deftest flexi-table-interactive-sort-and-resize-are-bound ()
  (with-temp-buffer
    (flexi-table-setup
     flexi-table-test--columns
     '(((id . 1) (name . "beta") (score . 2))
       ((id . 2) (name . "alpha") (score . 10)))
     :key-function #'flexi-table-test--key)
    (should (eq (key-binding (kbd "s")) #'flexi-table-sort))
    (should (eq (key-binding (kbd "}"))
                #'flexi-table-widen-current-column))
    (should (eq (key-binding (kbd "C"))
                #'flexi-table-columns-menu))
    (goto-char (point-min))
    (call-interactively #'flexi-table-sort)
    (goto-char (point-min))
    (should (= (flexi-table-current-id) 2))
    (let ((before (flexi-table--column-width
                   (flexi-table--find-column "Name")))
          (flexi-table-resize-strategy t))
      (call-interactively #'flexi-table-widen-current-column)
      (should (= (1+ before)
                 (flexi-table--column-width
                  (flexi-table--find-column "Name")))))))

(ert-deftest flexi-table-coalesces-async-updates-without-moving-point ()
  (with-temp-buffer
    (let ((first '((id . 1) (name . "alpha") (score . 2)))
          (second '((id . 2) (name . "beta") (score . 10))))
      (flexi-table-setup
       flexi-table-test--columns (list first second)
       :key-function #'flexi-table-test--key)
      (goto-char (point-min))
      (search-forward "pha")
      (let ((id (flexi-table-current-id))
            (column (current-column)))
        (setf (alist-get 'score first) 3
              (alist-get 'score second) 11)
        (flexi-table-queue-entry-update first)
        (flexi-table-queue-entry-update second)
        (should (= (hash-table-count
                    flexi-table--pending-updates)
                   2))
        (flexi-table--flush-entry-updates (current-buffer))
        (should (equal (flexi-table-current-id) id))
        (should (= (current-column) column))
        (should (string-match-p "11" (buffer-string)))))))

(ert-deftest flexi-table-preserves-window-anchor-during-batch-update ()
  (let ((buffer (generate-new-buffer " *flexi-window-test*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (let ((entries
                   (cl-loop for id from 1 to 40
                            collect `((id . ,id)
                                      (name . ,(format "row-%02d" id))
                                      (score . ,id)))))
              (flexi-table-setup
               flexi-table-test--columns entries
               :key-function #'flexi-table-test--key)
              (goto-char (point-min))
              (forward-line 20)
              (move-to-column 5)
              (recenter 5)
              (let ((point-id (flexi-table-current-id))
                    (point-column (current-column))
                    (start-id (get-text-property
                               (window-start)
                               'flexi-table-id))
                    (first (car entries))
                    (current (nth 20 entries)))
                (setf (alist-get 'score first) 100
                      (alist-get 'score current) 200)
                (flexi-table-update-entries (list first current))
                (should (equal (flexi-table-current-id) point-id))
                (should (= (current-column) point-column))
                (should (equal
                         (get-text-property
                          (window-start) 'flexi-table-id)
                         start-id))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'flexi-table-test)
;;; flexi-table-test.el ends here

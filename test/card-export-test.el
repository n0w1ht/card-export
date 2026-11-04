;;; card-export-test.el --- Tests for card-export -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -l test/card-export-test.el -f ert-run-tests-batch-and-exit
;;
;; The org-srs tests run when org-srs (and fsrs) are on the load path.

;;; Code:

(require 'ert)
(require 'org)
(require 'card-export)

(defvar org-id-track-globally)
(defvar org-srs-review-source)
(declare-function org-srs-review-pending-items "org-srs-review")

;;;; Clozes

(ert-deftest card-export-test-number-clozes ()
  (should (equal (card-export-anki-number-clozes "{{a}} and {{c1::b}} and {{c::d::hint}}")
                 "{{c2::a}} and {{c1::b}} and {{c3::c::d::hint}}"))
  (should (equal (card-export-anki-number-clozes "no clozes [1]") "no clozes [1]"))
  (should (equal (card-export-anki-number-clozes "{{across\nlines}}")
                 "{{c1::across\nlines}}")))

(ert-deftest card-export-test-cloze-command ()
  (with-temp-buffer
    (insert "The mitral valve")
    (card-export-anki-cloze 5 11)
    (should (equal (buffer-string) "The {{mitral}} valve"))
    (card-export-anki-cloze 16 21 "part")
    (should (equal (buffer-string) "The {{mitral}} {{valve::part}}"))))

(ert-deftest card-export-test-org-body ()
  (should (equal (card-export-org-body "* not a heading
ok *bold*")
                 " * not a heading\nok *bold*")))

(ert-deftest card-export-test-cloze-to-srs ()
  (should (equal (card-export-anki-cloze-to-srs
                  "The {{c1::mitral}} valve has {{c2::two::number}} cusps [1].")
                 "The {{1}{mitral}} valve has {{2}{two}{number}} cusps [1]."))
  ;; org-srs finds clozes line by line.
  (should (equal (card-export-anki-cloze-to-srs "{{c1::across\nlines}}")
                 "{{1}{across lines}}"))
  (should (equal (card-export-anki-cloze-to-srs "{{plain}}") "{{1}{plain}}")))

(ert-deftest card-export-test-cloze-ids ()
  (should (equal (card-export-anki-cloze-ids "{{c1::a}} {{c2::b}} {{c1::c}}") '(1 2)))
  (should-not (card-export-anki-cloze-ids "none")))

;;;; Anki

(ert-deftest card-export-test-html-escape ()
  (should (equal (card-export-html-escape "a<b> & c") "a&lt;b&gt; &amp; c")))

(defun card-export-test--note (front &rest props)
  "Return a Basic note with FRONT, plus PROPS."
  (append (list :deck "D" :model "Basic"
                :fields `(("Front" . ,front) ("Back" . "B"))
                :tags '("t1" "t2"))
          props))

(ert-deftest card-export-test-add-notes ()
  (let (calls)
    (cl-letf (((symbol-function 'card-export-anki)
               (lambda (action &optional params)
                 (push (cons action params) calls)
                 (pcase action
                   ("addNote"
                    (let ((front (cdr (assoc "Front" (alist-get 'fields (alist-get 'note params))))))
                      (pcase front
                        ("dup" (error "AnkiConnect: cannot create note because it is a duplicate"))
                        ("bad" (error "AnkiConnect: model was not found"))
                        (_ 42))))
                   (_ nil)))))
      (should (equal (card-export-anki-add-notes
                      (list (card-export-test--note "ok" :media '(("x.png" . "/tmp/x.png")))
                            (card-export-test--note "dup")
                            (card-export-test--note "bad")))
                     '(42 duplicate (error . "AnkiConnect: model was not found")))))
    (setq calls (nreverse calls))
    ;; One deck, created first; media stored before its note.
    (should (equal (car calls) '("createDeck" (deck . "D"))))
    (should (equal (car (nth 1 calls)) "storeMediaFile"))
    (should (equal (car (nth 2 calls)) "addNote"))
    (should (equal (alist-get 'tags (alist-get 'note (cdr (nth 2 calls)))) ["t1" "t2"]))))

(ert-deftest card-export-test-org-to-html ()
  (should (equal (card-export-org-to-html "") ""))
  ;; One paragraph: no <p>.
  (should (equal (card-export-org-to-html "What is *ATP*?") "What is <b>ATP</b>?"))
  (should (string-match-p "\\`<p>" (card-export-org-to-html "One.\n\nTwo.")))
  (let ((html (card-export-org-to-html "Some *bold* text.\n- one\n- two")))
    (should (string-match-p "<b>bold</b>" html))
    (should (string-match-p "<li>one</li>" html))))

(ert-deftest card-export-test-markdown-to-html ()
  (should (equal (card-export-markdown-to-html
                  "**ATP** is *made* in `a<b` mitochondria\nof cells")
                 "<b>ATP</b> is <i>made</i> in <code>a&lt;b</code> mitochondria<br>of cells"))
  ;; Underscores inside words stay.
  (should (equal (card-export-markdown-to-html "snake_case_name and _this_")
                 "snake_case_name and <i>this</i>"))
  ;; Markup inside code stays.
  (should (equal (card-export-markdown-to-html "`**x**`") "<code>**x**</code>")))

(ert-deftest card-export-test-markdown-to-org ()
  (should (equal (card-export-markdown-to-org "What is **ATP**?") "What is *ATP*?"))
  (should (equal (card-export-markdown-to-org "**bold** then *it*") "*bold* then /it/"))
  (should (equal (card-export-markdown-to-org "`a*b` and __x__, _y_ in snake_case")
                 "~a*b~ and *x*, /y/ in snake_case")))

(ert-deftest card-export-test-note-hash ()
  (let ((a (card-export-test--note "café")))
    (should (equal (card-export-note-hash a) (card-export-note-hash (copy-tree a))))
    (should-not (equal (card-export-note-hash a)
                       (card-export-note-hash (card-export-test--note "cafe"))))
    ;; Deck and tags don't count: updating leaves them alone.
    (should (equal (card-export-note-hash a)
                   (card-export-note-hash (plist-put (copy-tree a) :tags '("other")))))))

(ert-deftest card-export-test-update-notes ()
  (let (calls)
    (cl-letf (((symbol-function 'card-export-anki)
               (lambda (action &optional params)
                 (push (cons action params) calls)
                 (when (equal action "updateNoteFields")
                   (pcase (alist-get 'id (alist-get 'note params))
                     (404 (error "AnkiConnect: Note was not found: 404"))
                     (500 (error "AnkiConnect: collection is not available"))))
                 nil)))
      (should (equal (card-export-anki-update-notes
                      (list (card-export-test--note "a" :id 1 :media '(("x.png" . "/tmp/x.png")))
                            (card-export-test--note "b" :id 404)
                            (card-export-test--note "c" :id 500)))
                     '(t missing (error . "AnkiConnect: collection is not available")))))
    (setq calls (nreverse calls))
    (should (equal (car (nth 0 calls)) "storeMediaFile"))
    (should (equal (nth 1 calls)
                   '("updateNoteFields"
                     (note (id . 1) (fields ("Front" . "a") ("Back" . "B"))))))))

(ert-deftest card-export-test-send ()
  (let ((file (make-temp-file "card-export" nil ".txt"))
        (notes (list (card-export-test--note "a"))))
    (unwind-protect
        (progn
          ;; Anki answers.
          (cl-letf (((symbol-function 'card-export-anki-reachable-p) (lambda () t))
                    ((symbol-function 'card-export-anki-add-notes) (lambda (_) '(7))))
            (should (equal (card-export-anki-send notes file) '(anki 7))))
          ;; It doesn't: write the file if the user agrees, else nothing.
          (cl-letf (((symbol-function 'card-export-anki-reachable-p) #'ignore)
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (should-error (card-export-anki-send notes file) :type 'user-error))
          (cl-letf (((symbol-function 'card-export-anki-reachable-p) #'ignore)
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
            (should (eq (car (card-export-anki-send notes file)) 'file)))
          ;; Asked for the file: no question.
          (should (eq (car (card-export-anki-send notes file 'file)) 'file))
          (with-temp-buffer
            (insert-file-contents file)
            (should (= (count-lines (point-min) (point-max)) 7))))
      (delete-file file))))

(ert-deftest card-export-test-update-changed ()
  (let* ((same (card-export-test--note "same"))
         (edited (card-export-test--note "edited"))
         (gone (card-export-test--note "gone"))
         (sent nil))
    (cl-letf (((symbol-function 'card-export-anki-update-notes)
               (lambda (notes)
                 (setq sent notes)
                 (mapcar (lambda (n) (if (= (plist-get n :id) 3) 'missing t)) notes))))
      (let ((result (card-export-anki-update-changed
                     (list (list 'k1 same 1 (card-export-note-hash same))
                           (list 'k2 edited 2 "old hash")
                           (list 'k3 gone 3 nil)))))
        (should (equal (mapcar #'car sent) '(:deck :deck)))
        (should (equal (mapcar (lambda (n) (plist-get n :id)) sent) '(2 3)))
        (should (equal (mapcar #'cadr result) '(unchanged updated missing)))
        (should (equal (nth 2 (nth 1 result)) (card-export-note-hash edited)))))))

(ert-deftest card-export-test-write-file ()
  (let ((file (make-temp-file "card-export" nil ".txt")))
    (unwind-protect
        (progn
          (card-export-anki-write-file file (list (card-export-test--note "a \"q\"\nb")))
          (card-export-anki-write-file file (list (card-export-test--note "c")))
          (let ((lines (with-temp-buffer
                         (insert-file-contents file)
                         (split-string (buffer-string) "\n" t))))
            ;; The header once, then a line per note.
            (should (= (length lines) 7))
            (should (equal (nth 0 lines) "#separator:Tab"))
            (should (equal (nth 5 lines)
                           "\"Basic\"\t\"D\"\t\"a \"\"q\"\" b\"\t\"B\"\t\"t1 t2\""))))
      (delete-file file))))

(ert-deftest card-export-test-copy-media ()
  (let* ((dir (make-temp-file "card-export" t))
         (src (expand-file-name "src.png" dir))
         (media (expand-file-name "media" dir))
         (notes (list (card-export-test--note "a" :media `(("anki.png" . ,src))))))
    (unwind-protect
        (progn
          (with-temp-file src (insert "png"))
          (make-directory media)
          (should (equal (card-export-anki-copy-media notes nil) `(("anki.png" . ,src))))
          (should-not (card-export-anki-copy-media notes media))
          (should (file-exists-p (expand-file-name "anki.png" media))))
      (delete-directory dir t))))

;;;; Cards that are Org entries

(ert-deftest card-export-test-org-export ()
  (let ((file (make-temp-file "card-export" nil ".org"))
        (import (make-temp-file "card-export" nil ".txt"))
        (anki-up t) (next-id 100) updates)
    (unwind-protect
        (cl-letf (((symbol-function 'card-export-anki-reachable-p) (lambda () anki-up))
                  ((symbol-function 'card-export-anki-add-notes)
                   (lambda (notes)
                     (mapcar (lambda (n)
                               (if (equal (cdar (plist-get n :fields)) "Bad")
                                   '(error . "model was not found")
                                 (setq next-id (1+ next-id))))
                             notes)))
                  ((symbol-function 'card-export-anki-update-notes)
                   (lambda (notes)
                     (setq updates (append updates notes))
                     (mapcar (lambda (n) (if (= (plist-get n :id) 101) 'missing t)) notes))))
          (with-current-buffer (find-file-noselect file)
            (insert "* One\n* Two\n* Bad\n")
            (let ((markers (org-map-entries #'point-marker t 'file))
                  (note (lambda () (card-export-test--note (org-get-heading t t t t)))))
              ;; New cards are added; the one Anki refuses is reported.
              (let ((r (card-export-anki-org-export markers note import)))
                (should (eq (plist-get r :method) 'anki))
                (should (= (plist-get r :added) 2))
                (should (equal (plist-get r :failed) '(("Bad" . "model was not found")))))
              (should (equal (org-entry-get (nth 0 markers) "ANKI_NOTE_ID") "101"))
              (should (org-entry-get (nth 1 markers) "ANKI_HASH"))
              (should-not (org-entry-get (nth 2 markers) "ANKI_EXPORTED"))
              ;; Unchanged: nothing updated.
              (should (= (plist-get (card-export-anki-org-export (list (nth 1 markers)) note import)
                                    :updated)
                         0))
              (should-not updates)
              ;; Edited: updated; deleted in Anki and edited: added anew.
              (dolist (m (list (nth 0 markers) (nth 1 markers)))
                (org-with-point-at m (org-edit-headline (concat (org-get-heading t t t t) "!"))))
              (let ((r (card-export-anki-org-export (butlast markers) note import)))
                (should (= (plist-get r :updated) 1))
                (should (= (plist-get r :added) 1)))
              (should (equal (org-entry-get (nth 0 markers) "ANKI_NOTE_ID") "103"))
              ;; Anki down: the import file, if the user agrees.
              (setq anki-up nil)
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (let ((r (card-export-anki-org-export markers note import)))
                  (should (eq (plist-get r :method) 'file))
                  (should (= (plist-get r :added) 1))))
              (should (org-entry-get (nth 2 markers) "ANKI_EXPORTED"))
              (should-not (org-entry-get (nth 2 markers) "ANKI_NOTE_ID"))
              (set-buffer-modified-p nil)
              (kill-buffer))))
      (delete-file file)
      (delete-file import))))

;;;; org-srs

(defmacro card-export-test--with-org (text &rest body)
  "Run BODY in an Org file holding TEXT, point on its first heading."
  (declare (indent 1))
  `(let ((file (make-temp-file "card-export" nil ".org"))
         (org-id-track-globally nil))
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (insert ,text)
           (goto-char (point-min))
           ,@body
           (set-buffer-modified-p nil)
           (kill-buffer))
       (delete-file file))))

(defun card-export-test--pending ()
  "Return the org-srs items due in the current buffer, as strings."
  (let ((org-srs-review-source (cons (point-min-marker) (point-max-marker))))
    (sort (mapcar (lambda (i) (format "%S" (car i))) (org-srs-review-pending-items))
          #'string<)))

(ert-deftest card-export-test-srs-card ()
  (skip-unless (card-export-srs-available-p))
  (card-export-test--with-org "* Question?\n** Back\nAnswer.\n"
    (card-export-srs-make-card)
    (should (org-entry-get nil "ID"))
    (should (equal (card-export-test--pending) '("(card back)")))))

(ert-deftest card-export-test-srs-cloze-card ()
  (skip-unless (card-export-srs-available-p))
  (card-export-test--with-org "* Heart\nThe {{1}{mitral}} valve has {{2}{two}} cusps.\n"
    (card-export-srs-make-cloze-card '(1 2))
    (should (equal (card-export-test--pending) '("(cloze 1)" "(cloze 2)")))))

(provide 'card-export-test)
;;; card-export-test.el ends here

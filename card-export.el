;;; card-export.el --- Send flashcards to Anki and org-srs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
;; URL: https://github.com/n0w1ht/card-export
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: outlines, hypermedia

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The plumbing that tools making flashcards share; each tool still
;; decides what goes on its cards.
;;
;; Anki:
;;   `card-export-anki'             call an AnkiConnect action
;;   `card-export-anki-reachable-p' is Anki running, with AnkiConnect?
;;   `card-export-anki-add-notes'   add notes, with their images
;;   `card-export-anki-update-notes' replace the fields of notes Anki has
;;   `card-export-note-hash'        to tell whether a note changed since
;;   `card-export-anki-update-changed' update the notes that changed
;;   `card-export-anki-send'        add notes, or write the import file
;;   `card-export-anki-org-export'  all of it, for cards that are Org
;;                                  entries: they record what Anki has
;;   `card-export-anki-write-file'  append notes to a File > Import file
;;   `card-export-anki-copy-media'  copy images to Anki's media folder
;;   `card-export-html-escape'      plain text to put in a field
;;   `card-export-org-to-html'      Org text to put in a field
;;   `card-export-markdown-to-html' inline Markdown to put in a field
;;   `card-export-markdown-to-org'  inline Markdown to put in an Org card
;;
;; A note is a plist:
;;   (:deck "Deck::Subdeck" :model "Basic"
;;    :fields (("Front" . HTML) ("Back" . HTML))
;;    :tags ("tag" ...)
;;    :media (("name-in-anki.png" . "/path/to/file.png") ...)
;;    :id 1234567890)            ; to update a note Anki has
;;
;; org-srs (https://github.com/bohonghuang/org-srs), with point on the
;; card's Org entry:
;;   `card-export-srs-make-card'        the heading (and body) ask, Back answers
;;   `card-export-srs-make-cloze-card'  one review item per cloze id
;;   `card-export-org-body'             text safe for an entry's body
;; and for clozes written the Anki way, {{c1::text::hint}}:
;;   `card-export-anki-cloze'           command: make the region a cloze
;;   `card-export-anki-number-clozes'   {{x}} to {{c1::x}}, {{c2::...}}
;;   `card-export-anki-cloze-to-srs'    to org-srs's {{1}{text}{hint}}
;;   `card-export-anki-cloze-ids'       the cloze numbers, for the items

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org-macs)                    ; `org-with-point-at'

(defgroup card-export nil
  "Send flashcards to Anki and org-srs."
  :group 'applications
  :prefix "card-export-")

(defcustom card-export-anki-connect-url "http://127.0.0.1:8765"
  "Address of the AnkiConnect add-on."
  :type 'string)

;;;; Anki

(defvar url-http-end-of-headers)
(defvar url-request-method)
(defvar url-request-data)
(defvar url-request-extra-headers)
(defvar url-proxy-services)
(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)
(declare-function json-encode "json" (object))
(declare-function json-read-from-string "json" (string))
(declare-function url-do-setup "url" ())

(defun card-export-anki (action &optional params)
  "Call the AnkiConnect ACTION with PARAMS (an alist) and return its result.
Signal an error when Anki does not answer or reports one."
  (require 'url)
  (require 'json)
  ;; Read proxy settings now, so that the binding below (Anki runs on
  ;; this computer, never behind a proxy) is not overridden by them.
  (url-do-setup)
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data
          (encode-coding-string
           (json-encode `((action . ,action) (version . 6)
                          ,@(and params `((params . ,params)))))
           'utf-8))
         (url-proxy-services nil)
         (buf (ignore-errors
                (url-retrieve-synchronously card-export-anki-connect-url t t 15))))
    (unless buf
      (error "No answer from AnkiConnect at %s" card-export-anki-connect-url))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (or (bound-and-true-p url-http-end-of-headers) (point-min)))
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (response (json-read-from-string
                            (decode-coding-string
                             (buffer-substring-no-properties (point) (point-max))
                             'utf-8))))
            (when (cdr (assq 'error response))
              (error "AnkiConnect: %s" (cdr (assq 'error response))))
            (cdr (assq 'result response))))
      (kill-buffer buf))))

(defun card-export-anki-reachable-p ()
  "Return non-nil when AnkiConnect answers."
  (condition-case nil (progn (card-export-anki "version") t) (error nil)))

;;;; HTML for fields

(declare-function org-export-string-as "ox" (string backend &optional body-only ext-plist))

(defun card-export-html-escape (text)
  "Escape TEXT for an HTML field."
  (replace-regexp-in-string
   ">" "&gt;" (replace-regexp-in-string
               "<" "&lt;" (replace-regexp-in-string "&" "&amp;" text))))

(defun card-export-org-to-html (text)
  "Convert the Org TEXT to HTML for a field: lists, tables, emphasis, links.
Text that is a single paragraph isn't wrapped in <p>.  If the Org
export fails, TEXT is escaped and its line breaks kept."
  (if (string-empty-p (string-trim (or text "")))
      ""
    (condition-case nil
        (progn
          (require 'ox-html)
          (let ((html (string-trim
                       (org-export-string-as text 'html t
                                             '(:with-toc nil :section-numbers nil
                                               :with-sub-superscript nil :with-smart-quotes nil
                                               :with-latex verbatim)))))
            ;; A single paragraph needs no <p>, which adds space in Anki.
            (if (string-match "\\`<p>\n?\\(\\(?:.\\|\n\\)*?\\)</p>\\'" html)
                (let ((inner (match-string 1 html)))
                  (if (string-match-p "<p>" inner) html inner))
              html)))
      (error (replace-regexp-in-string "\n" "<br>" (card-export-html-escape text))))))

(defun card-export-markdown-to-html (text)
  "Convert the inline Markdown of TEXT to HTML for a field.
Handles `code', **bold**, __bold__, *italic* and _italic_; line breaks
become <br>.  Code is left as it is inside."
  (let ((codes nil))
    (setq text (replace-regexp-in-string
                "`\\([^`\n]+\\)`"
                (lambda (m)
                  (push (card-export-html-escape (match-string 1 m)) codes)
                  (format "\0%d\0" (1- (length codes))))
                text t t))
    (setq codes (nreverse codes))
    (setq text (card-export-html-escape text))
    (dolist (rule '(("\\*\\*\\([^*\n]+\\)\\*\\*" . "<b>\\1</b>")
                    ("__\\([^_\n]+\\)__" . "<b>\\1</b>")
                    ("\\*\\([^*\n]+\\)\\*" . "<i>\\1</i>")
                    ;; Not inside words, as in snake_case_names.
                    ("\\(^\\|[^[:alnum:]_]\\)_\\([^_\n]+\\)_\\([^[:alnum:]_]\\|$\\)"
                     . "\\1<i>\\2</i>\\3")))
      (setq text (replace-regexp-in-string (car rule) (cdr rule) text t)))
    (replace-regexp-in-string
     "\n" "<br>"
     (replace-regexp-in-string
      "\0\\([0-9]+\\)\0"
      (lambda (m) (concat "<code>" (nth (string-to-number (match-string 1 m)) codes) "</code>"))
      text t t))))

(defun card-export-markdown-to-org (text)
  "Convert the inline Markdown of TEXT to Org: bold, italic and code."
  (let ((codes nil))
    (setq text (replace-regexp-in-string
                "`\\([^`\n]+\\)`"
                (lambda (m) (push (match-string 1 m) codes)
                  (format "\0%d\0" (1- (length codes))))
                text t t))
    (setq codes (nreverse codes))
    ;; Italic first, so that the * of Org bold isn't taken for it.
    (dolist (rule '(("\\(^\\|[^*]\\)\\*\\([^*\n]+\\)\\*\\([^*]\\|$\\)" . "\\1/\\2/\\3")
                    ("\\(^\\|[^[:alnum:]_]\\)_\\([^_\n]+\\)_\\([^[:alnum:]_]\\|$\\)"
                     . "\\1/\\2/\\3")
                    ("\\*\\*\\([^*\n]+\\)\\*\\*" . "*\\1*")
                    ("__\\([^_\n]+\\)__" . "*\\1*")))
      (setq text (replace-regexp-in-string (car rule) (cdr rule) text t)))
    (replace-regexp-in-string
     "\0\\([0-9]+\\)\0"
     (lambda (m) (concat "~" (nth (string-to-number (match-string 1 m)) codes) "~"))
     text t t)))

;;;; Adding and updating notes

(defun card-export-anki-add-notes (notes)
  "Add NOTES to Anki through AnkiConnect, creating their decks.
Each note is a plist, see the Commentary of card-export.el; its
:media files are stored in Anki's media folder first.  Return a list
with one element per note: its Anki note id, `duplicate' when Anki
already has it, or (error . MESSAGE)."
  (dolist (deck (delete-dups (mapcar (lambda (n) (plist-get n :deck)) notes)))
    (card-export-anki "createDeck" `((deck . ,deck))))
  (mapcar
   (lambda (note)
     (condition-case err
         (progn
           (pcase-dolist (`(,name . ,file) (plist-get note :media))
             (card-export-anki "storeMediaFile"
                               `((filename . ,name) (path . ,(expand-file-name file)))))
           (card-export-anki
            "addNote"
            `((note . ((deckName . ,(plist-get note :deck))
                       (modelName . ,(plist-get note :model))
                       (fields . ,(plist-get note :fields))
                       (tags . ,(vconcat (plist-get note :tags)))
                       (options . ((allowDuplicate . :json-false))))))))
       (error
        (let ((msg (error-message-string err)))
          (if (string-match-p "duplicate" msg) 'duplicate (cons 'error msg))))))
   notes))

(defun card-export-note-hash (note)
  "Return a hash of what NOTE puts in Anki: its fields and media.
Keep it with the note's id to tell, later, whether the note changed."
  (secure-hash 'sha1 (encode-coding-string
                      (prin1-to-string (list (plist-get note :fields)
                                             (plist-get note :media)))
                      'utf-8)))

(defun card-export-anki-update-notes (notes)
  "Replace the fields of NOTES in Anki, which already has them.
Each note is a plist as for `card-export-anki-add-notes', with its Anki
note id in :id; its :media are stored again first.  Deck, note type and
tags are left as they are in Anki, so tags added there (such as leech)
stay.  Return a list with one element per note: t when updated,
`missing' when Anki no longer has the note, or (error . MESSAGE).

Anki does not update a note that is open in its Browse window."
  (mapcar
   (lambda (note)
     (condition-case err
         (progn
           (pcase-dolist (`(,name . ,file) (plist-get note :media))
             (card-export-anki "storeMediaFile"
                               `((filename . ,name) (path . ,(expand-file-name file)))))
           (card-export-anki
            "updateNoteFields"
            `((note . ((id . ,(plist-get note :id))
                       (fields . ,(plist-get note :fields))))))
           t)
       (error
        (let ((msg (error-message-string err)))
          (if (string-match-p "not found" msg) 'missing (cons 'error msg))))))
   notes))

(defun card-export--tsv-field (string)
  "Quote STRING as a field of Anki's import file."
  (concat "\"" (replace-regexp-in-string
                "\"" "\"\"" (replace-regexp-in-string "[\t\n\r]+" " " string))
          "\""))

(defun card-export-anki-write-file (file notes)
  "Append NOTES to FILE, for Anki's File > Import.
The file has the note type, deck, the note's first two fields and its
tags in columns; a new file starts with the header saying so.  Line
breaks in fields become spaces, as HTML would show them: put <br>
where a field needs one.  Images can't go in the file, see
`card-export-anki-copy-media'."
  (let* ((file (expand-file-name file))
         (new (not (and (file-exists-p file)
                        (> (or (file-attribute-size (file-attributes file)) 0) 0)))))
    (with-temp-buffer
      (when new
        (insert "#separator:Tab\n#html:true\n#notetype column:1\n#deck column:2\n"
                "#tags column:5\n"))
      (dolist (note notes)
        (let ((fields (mapcar #'cdr (plist-get note :fields))))
          (insert (mapconcat #'card-export--tsv-field
                             (list (plist-get note :model) (plist-get note :deck)
                                   (or (nth 0 fields) "") (or (nth 1 fields) "")
                                   (mapconcat #'identity (plist-get note :tags) " "))
                             "\t")
                  "\n")))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) file (not new) 'silent)))))

(defun card-export-anki-copy-media (notes directory)
  "Copy the :media files of NOTES to DIRECTORY, Anki's collection.media.
With DIRECTORY nil, copy nothing.  Return the (NAME . FILE) pairs not
copied, for the user to copy by hand."
  (let ((media (delete-dups (apply #'append (mapcar (lambda (n) (plist-get n :media))
                                                    notes)))))
    (if (not directory)
        media
      (pcase-dolist (`(,name . ,file) media)
        (when (file-exists-p file)
          (copy-file file (expand-file-name name directory) t)))
      nil)))

(defun card-export-anki-send (notes file &optional method)
  "Send NOTES to Anki, or write them to the import FILE.
With METHOD `file', write FILE.  Otherwise add them through
AnkiConnect; when Anki can't be reached, offer to write FILE instead.
Return (anki . RESULTS), RESULTS as from `card-export-anki-add-notes',
or (file . NOTES).  Signal a `user-error' if nothing is sent."
  (cond
   ((eq method 'file)
    (card-export-anki-write-file file notes)
    (cons 'file notes))
   ((card-export-anki-reachable-p)
    (cons 'anki (card-export-anki-add-notes notes)))
   ((y-or-n-p "Cannot reach Anki (is it running, with the AnkiConnect add-on?).  \
Write an import file instead? ")
    (card-export-anki-write-file file notes)
    (cons 'file notes))
   (t (user-error "Nothing exported; start Anki and try again"))))

(defun card-export-anki-update-changed (cards)
  "Update the Anki notes of CARDS whose content changed since sent.
Each card is (KEY NOTE ID HASH): NOTE as it is now, ID its note in
Anki, HASH what `card-export-note-hash' gave when it was last sent;
KEY is anything identifying the card for the caller.  Return a list
of (KEY STATUS HASH), one per card: STATUS is `unchanged', `updated',
`missing' (deleted in Anki) or (error . MESSAGE), and HASH the note's
hash now, to keep after `updated'."
  (let* ((cards (mapcar (lambda (c) (append c (list (card-export-note-hash (nth 1 c)))))
                        cards))
         (changed (cl-remove-if (lambda (c) (equal (nth 3 c) (nth 4 c))) cards))
         (results (card-export-anki-update-notes
                   (mapcar (lambda (c) (append (nth 1 c) (list :id (nth 2 c)))) changed))))
    (mapcar (lambda (c)
              (let ((pos (cl-position c changed :test #'eq)))
                (list (car c)
                      (pcase (and pos (nth pos results))
                        ('nil 'unchanged)
                        ('t 'updated)
                        (r r))
                      (nth 4 c))))
            cards)))

;;;; Cards that are Org entries

;; A card kept as an Org entry records what Anki has of it in the
;; entry's properties:
;;   ANKI_EXPORTED  when it was sent (or written to the import file)
;;   ANKI_NOTE_ID   its Anki note, or "duplicate" if Anki had it already
;;   ANKI_HASH      `card-export-note-hash' of what was sent

(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-entry-put "org" (epom property value))
(declare-function org-entry-delete "org" (epom property))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))

(defun card-export--org-mark-sent (note result)
  "Record on the entry at point that NOTE went to Anki with RESULT.
RESULT is from `card-export-anki-add-notes', or `file'."
  (cond
   ((numberp result)
    (org-entry-put nil "ANKI_NOTE_ID" (number-to-string result))
    (org-entry-put nil "ANKI_HASH" (card-export-note-hash note)))
   ((eq result 'duplicate)
    (org-entry-put nil "ANKI_NOTE_ID" "duplicate")))
  (org-entry-put nil "ANKI_EXPORTED" (format-time-string "[%Y-%m-%d %a]")))

(defun card-export-anki-org-export (markers note-function file)
  "Bring Anki up to date with the cards that are the Org entries at MARKERS.
NOTE-FUNCTION, called with point on an entry, returns its note (see
the Commentary).  When Anki is running, the entries edited since they
were sent update their notes, and one whose note was deleted in Anki
is sent again.  Entries not sent yet are added; if Anki can't be
reached, the user may have them written to the import FILE instead.
What was sent is recorded in each entry's properties; saving the
buffers is up to the caller.

Return a plist: :method `anki', `file' or nil (nothing sent),
:added and :updated the numbers of notes, and :failed a list of
\(HEADING . MESSAGE) for the entries Anki refused."
  (let ((updated 0) (added 0) failed method)
    (cl-flet ((note-at (m) (org-with-point-at m (funcall note-function))))
      ;; Edited entries first, so that one deleted in Anki is added anew.
      (when (card-export-anki-reachable-p)
        (setq method 'anki)
        (let (cards)
          (dolist (m markers)
            (let ((id (org-entry-get m "ANKI_NOTE_ID")))
              (when (and id (string-match-p "\\`[0-9]+\\'" id))
                (push (list m (note-at m) (string-to-number id)
                            (org-entry-get m "ANKI_HASH"))
                      cards))))
          (pcase-dolist (`(,m ,status ,hash) (card-export-anki-update-changed (nreverse cards)))
            (org-with-point-at m
              (pcase status
                ('updated (org-entry-put nil "ANKI_HASH" hash)
                          (setq updated (1+ updated)))
                ('missing (dolist (p '("ANKI_NOTE_ID" "ANKI_HASH" "ANKI_EXPORTED"))
                            (org-entry-delete nil p)))
                (`(error . ,msg) (push (cons (org-get-heading t t t t) msg) failed)))))))
      (let* ((new (cl-remove-if (lambda (m) (org-entry-get m "ANKI_EXPORTED")) markers))
             (notes (mapcar #'note-at new))
             (sent (and new (condition-case nil
                                (card-export-anki-send notes file)
                              (user-error nil)))))
        (when sent
          (setq method (car sent))
          (cl-loop for m in new
                   for note in notes
                   for result in (if (eq (car sent) 'anki)
                                     (cdr sent)
                                   (make-list (length notes) 'file))
                   do (org-with-point-at m
                        (if (eq (car-safe result) 'error)
                            (push (cons (org-get-heading t t t t) (cdr result)) failed)
                          (card-export--org-mark-sent note result)
                          (setq added (1+ added))))))
        (when (and new (not sent)) (setq method nil))))
    (list :method method :added added :updated updated :failed (nreverse failed))))

;;;; Clozes

(defconst card-export-anki-cloze-regexp "{{\\(\\(?:.\\|\n\\)+?\\)}}"
  "Regexp matching a cloze deletion written the Anki way; group 1 its contents.")

;;;###autoload
(defun card-export-anki-cloze (beg end &optional hint)
  "Hide the text between BEG and END in a cloze deletion: {{text}}.
With a prefix argument, ask for a HINT shown in place of the text:
{{text::hint}}.  `card-export-anki-number-clozes' numbers the clozes
when the card is made."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end)
             (and current-prefix-arg (read-string "Hint: ")))
     (user-error "Select the text to hide first")))
  (save-excursion
    (goto-char end)
    (insert (if (and hint (not (string-empty-p hint))) (concat "::" hint) "") "}}")
    (goto-char beg)
    (insert "{{"))
  (deactivate-mark))

(defun card-export-anki-number-clozes (text)
  "Number the clozes of TEXT the Anki way: {{x}} becomes {{cN::x}}.
Clozes already numbered keep their number; each other one gets the
next free number, so it becomes a card of its own."
  (let ((n 0) (start 0))
    (while (string-match "{{c\\([0-9]+\\)::" text start)
      (setq n (max n (string-to-number (match-string 1 text)))
            start (match-end 0)))
    (replace-regexp-in-string
     card-export-anki-cloze-regexp
     (lambda (m)
       (save-match-data
         (let ((inner (progn (string-match card-export-anki-cloze-regexp m)
                             (match-string 1 m))))
           (if (string-match-p "\\`c[0-9]+::" inner)
               m
             (setq n (1+ n))
             (format "{{c%d::%s}}" n inner)))))
     text t t)))

(defun card-export-anki-cloze-to-srs (text)
  "Convert the {{cN::x::hint}} clozes of TEXT to org-srs's {{N}{x}{hint}}.
Clozes with the same number get the same id, so they are hidden
together; a cloze without a number gets 1.  A cloze is put on one
line, as org-srs finds them by line."
  (replace-regexp-in-string
   card-export-anki-cloze-regexp
   (lambda (m)
     (save-match-data
       (let* ((inner (progn (string-match card-export-anki-cloze-regexp m)
                            (match-string 1 m)))
              (num (if (string-match "\\`c\\([0-9]+\\)::" inner)
                       (match-string 1 inner)
                     "1"))
              (parts (split-string (replace-regexp-in-string "\\`c[0-9]+::" "" inner)
                                   "::")))
         (concat "{{" num "}{"
                 (replace-regexp-in-string "[ \t]*\n[ \t]*" " " (car parts)) "}"
                 (if (cadr parts) (concat "{" (cadr parts) "}") "")
                 "}"))))
   text t t))

(defun card-export-anki-cloze-ids (text)
  "Return the distinct numbers of the {{cN::...}} clozes of TEXT, in order."
  (let (ids (start 0))
    (while (string-match "{{c\\([0-9]+\\)::" text start)
      (cl-pushnew (string-to-number (match-string 1 text)) ids)
      (setq start (match-end 0)))
    (nreverse ids)))

;;;; org-srs

(declare-function org-id-get-create "org-id" (&optional force))
(declare-function org-srs-item-new "org-srs-item" (type &rest args))
(declare-function org-srs-log-hide-drawer "org-srs-log" (&optional position))

(defun card-export-org-body (text)
  "Return TEXT safe to put in the body of an Org entry.
A line starting with * would start a heading, so it gets a space first."
  (replace-regexp-in-string "^\\*" " *" text))

(defun card-export-srs-available-p ()
  "Return non-nil when org-srs is installed (and load it)."
  (require 'org-srs nil t))

(defun card-export--srs-require ()
  "Load org-srs, or signal that it is needed."
  (unless (card-export-srs-available-p)
    (user-error "org-srs is not installed (https://github.com/bohonghuang/org-srs)")))

(defun card-export-srs-make-card ()
  "Make the Org entry at point an org-srs flashcard.
The heading and the entry's text are the front; a Back subheading, if
there is one, is the answer, otherwise the entry's text is."
  (card-export--srs-require)
  (save-excursion
    (org-id-get-create)
    (org-srs-item-new '(card back))
    (org-srs-log-hide-drawer)))

(defun card-export-srs-make-cloze-card (ids)
  "Make the Org entry at point an org-srs cloze card with the cloze IDS.
Its {{ID}{text}} clozes with the same id are hidden together, and each
id is reviewed on its own."
  (card-export--srs-require)
  (save-excursion
    (org-id-get-create)
    (dolist (id ids)
      (org-srs-item-new (list 'cloze id)))
    (org-srs-log-hide-drawer)))

(provide 'card-export)
;;; card-export.el ends here

;;; org-overdrive.el --- Ultimate Anki integration for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2023-2024 Martin Edström <meedstrom91@gmail.com>

;; Author: Ad <me@skissue.xyz>
;; Original Author: Martin Edström
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (asyncloop "0.5") (pcre2el "1.12") (request "0.3.3") (dash "2.19.1"))
;; URL: https://github.com/skissue/org-overdrive

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Custom, opinionated fork of inline-anki

;;; Code:

(require 'asyncloop)
(require 'org)
(require 'org-overdrive-api)
(require 'pcre2el)

(defgroup org-overdrive nil
  "Customizations for org-overdrive."
  :group 'org)

(defcustom org-overdrive-default-deck "Default"
  "Name of default deck to upload to."
  :type 'string)

(defcustom org-overdrive-default-cloze-note-type "Overdrive Cloze"
  "Name of default cloze note type.
Will fail silently if the note type doesn't exist, so get it
right!"
  :type 'string)

(defcustom org-overdrive-inline-emphasis-type "_"
  "The kind of emphasis you want to indicate a cloze deletion.
Whatever you choose, it MUST be found in `org-emphasis-alist' and
can only be one character long."
  :type 'string)

(defcustom org-overdrive-send-tags nil
  "List of tags to include when sending flashcards to Anki.
This doesn't mean extra tags injected into every flashcard, but
rather that if the subtree has a tag in this list, then to
send the tag.  Special value t means include all tags.

Defaults to nil because users may be distraught to find a load of
new tags in their Anki database.  Also, the nil value lets the
command `org-overdrive-push-notes-in-directory' work faster, since it won't
have to turn on Org-mode for each file visited.

A list of strings means include the tag only if it's in this
list.  Or if the first element is the symbol `not', then include
the tag only if it's NOT in this list.

A reasonable value is '\(not \"noexport\" \"archive\"\).

Case-insensitive.

If you want to include the local subtree tags only and exclude
global tags, that cannot be expressed here; you need
`org-use-tag-inheritance' at nil."
  :type '(choice
          (const :tag "All" t)
          (const :tag "None" nil)
          (repeat sexp)))

(defcustom org-overdrive-ignore-file-regexps
  '("/logseq/version-files/"
    "/logseq/bak/"
    "/.git/")
  "List of regexps that bar a file-path from being visited.
Used by the command `org-overdrive-push-notes-in-directory'.  Note
that the command only considers file-paths ending in .org, so
backup and auto-save files ending in ~ or # are already barred by
that fact."
  :type '(repeat string))

(defcustom org-overdrive-cloze-fields
  '(("Outline" . org-overdrive-outline-at-point)
    ("Text" . t))
  "Alist specifying note fields and how to populate them.
The cdrs may be either t, a string or a function.  The symbol t
is replaced with the full HTML of the note, so you probably
only want t for one of the fields.

If the cdr is a function, it's evaluated with the appropriate
buffer set as current, with point on the first line of the
flashcard expression.  (In the case of a #+begin_flashcard
template, point is on that line.)

You have to create a field with the same name in Anki's \"Manage
note types\" before it will work.  Fields unknown to Anki will
not be filled in.  Conversely, it's OK if Anki defines more
fields than this variable has, they will not be edited."
  :type '(alist
          :key-type string
          :value-type (choice function
                              string
                              (const :tag "The full HTML content" t)
                              sexp)))

(defcustom org-overdrive-occluder
  #'org-overdrive-dots-logarithmic
  "Function that occludes a string, for use in cloze.
Takes the string to be occluded \(replaced by dots or whatever).

To get the Anki default of three dots, set this variable to nil."
  :type '(choice function
                 (const :tag "Anki default of three dots" nil)))

(defcustom org-overdrive-extra-tag "from-emacs-%F"
  "Tag added to every note sent to Anki.
Will be passed through `format-time-string'.  Cannot be nil."
  :type 'string)

(defconst org-overdrive-list-bullet-re
  (rx (or (any "-+*") (seq (*? digit) (any ").") " "))))

(defconst org-overdrive-rx-eol-new
  (rx (or "@anki" "^{anki}") (*? space) eol))

(defconst org-overdrive-rx-eol
  (rx (?? "@") "^{" (group (= 13 digit)) "}" (*? space) eol))

(defconst org-overdrive-rx-struct-new
  (rx bol (*? space) "#+begin_flashcard" (*? space) eol))

(defconst org-overdrive-rx-struct
  (rx bol (*? space) (?? "# ") (*? space) "#+begin_flashcard " (group (= 13 digit)) (or eol (not digit))))

(defvar org-overdrive--known-flashcard-places nil
  "Internal use only.")

;; TODO: make a version that Vertico/Helm can make interactive
;;;###autoload
(defun org-overdrive-occur ()
  "Use `occur' to show all flashcards in the buffer."
  (interactive)
  (occur (rx (or (regexp org-overdrive-rx-struct)
                 (regexp org-overdrive-rx-struct-new)
                 (regexp org-overdrive-rx-eol)
                 (regexp org-overdrive-rx-eol-new)))))

;;;###autoload
(defun org-overdrive-rgrep ()
  "Find all flashcards in current directory and descendants."
  (interactive)
  ;; Override rgrep's command to add -P for PCRE
  (let ((grep-find-template "find -H <D> <X> -type f <F> -exec grep <C> -nH -P --null -e <R> \\{\\} +"))
    (rgrep (rxt-elisp-to-pcre
            (rx (or (regexp org-overdrive-rx-struct)
                    (regexp org-overdrive-rx-struct-new)
                    (regexp org-overdrive-rx-eol)
                    (regexp org-overdrive-rx-eol-new))))
           "*.org")))

;; This does its own regexp searches because it's used as a callback with no
;; context.  But it'd be possible to pass another argument to
;; `org-overdrive--create-note' that could let it choose one of 3 different
;; callbacks.  Anyway, tiny diff to code complexity in the end.
(defun org-overdrive--dangerously-write-id (id)
  "Assign ID to the unlabeled flashcard at point."
  (unless id
    (error "Note creation failed for unknown reason (no ID returned)"))
  ;; Point is already on the correct line, at least
  (goto-char (line-beginning-position))
  (cond
   ;; Replace "@anki" with ID
   ((search-forward "@anki" (line-end-position) t)
    (delete-char -4)
    (insert "^{" (number-to-string id) "}"))
   ;; Replace "^{anki}" with ID
   ((re-search-forward (rx "^{" (group "anki") "}" (*? space) eol)
                       (line-end-position)
                       t)
    (replace-match (number-to-string id) nil nil nil 1))
   ;; Insert ID after "#+begin_flashcard"
   ((re-search-forward (rx (*? space) "#+begin_flashcard") (line-end-position) t)
    (insert " " (number-to-string id)))
   (t
    (error "No org-overdrive magic string found"))))

(defun org-overdrive-dots-logarithmic (text)
  "Return TEXT replaced by dots.
Longer TEXT means more dots, but along a log-2 algorithm so it
doesn't get crazy-long in extreme cases."
  (make-string (max 3 (* 2 (round (log (length text) 2)))) ?\.))

(defconst org-overdrive-rx-comment-glyph
  (rx bol (*? space) "# "))

(defun org-overdrive--convert-implicit-clozes (text)
  "Return TEXT with emphasis replaced by Anki {{c::}} syntax."
  (with-temp-buffer
    (insert " ") ;; workaround bug where the regexp misses emph @ BoL
    (insert (substring-no-properties text))
    (insert " ")
    (goto-char (point-min))
    ;; comment means suspend card, but don't also blank-out the html
    (while (re-search-forward org-overdrive-rx-comment-glyph nil t)
      (delete-char -2))
    (let ((n 0))
      (goto-char (point-min))
      (while (re-search-forward org-emph-re nil t)
        (when (equal (match-string 3) org-overdrive-inline-emphasis-type)
          (let ((truth (match-string 4)))
            (replace-match (concat "{{c"
                                   (number-to-string (cl-incf n))
                                   "::"
                                   truth
                                   (when org-overdrive-occluder
                                     (concat
                                      "::"
                                      (funcall org-overdrive-occluder truth)))
                                   "}}")
                           nil nil nil 2))))
      (if (= n 0)
          nil ;; Nil signals that no clozes found
        (string-trim (buffer-string))))))

;; TODO: make capable of basic flashcard
(cl-defun org-overdrive--push-note (&key field-beg field-end note-id)
  "Push a flashcard to Anki, identified by NOTE-ID.
Use the buffer substring delimited by FIELD-BEG and FIELD-END.

If a flashcard doesn't exist (indicated by a NOTE-ID
value of -1), create it."
  (let ((this-line (line-number-at-pos)))
    (if (member this-line org-overdrive--known-flashcard-places)
        (error "Two magic strings on same line: %d" this-line)
      (push this-line org-overdrive--known-flashcard-places)))
  (if-let* ((text (buffer-substring field-beg field-end))
            (clozed (org-overdrive--convert-implicit-clozes text))
            (html
             ;; REVIEW: Maybe empty these hooks? Can be source of user error.
             ;; let ((org-export-before-parsing-functions nil)
             ;;      (org-export-before-processing-functions nil))
             (org-export-string-as clozed
                                   org-overdrive--ox-anki-html-backend
                                   t
                                   '(:with-toc nil))))
      (prog1 t
        ;; When `org-overdrive-push-notes-in-directory' calls this, the buffer is
        ;; in fundamental-mode. Switch to org-mode if we need to read tags.
        (when (and org-overdrive-send-tags
                   (not (derived-mode-p 'org-mode)))
          (delay-mode-hooks
            (org-mode)))
        (funcall
         (if (= -1 note-id)
             #'org-overdrive--create-note
           #'org-overdrive--update-note)
         (list
          (cons 'deck org-overdrive-default-deck)
          (cons 'note-type org-overdrive-default-cloze-note-type)
          (cons 'note-id note-id)
          (cons 'tags
                (delq nil
                      (cons
                       (when org-overdrive-extra-tag
                         (format-time-string org-overdrive-extra-tag))
                       (mapcar #'substring-no-properties
                               (cond ((eq t org-overdrive-send-tags)
                                      (org-get-tags))
                                     ((null org-overdrive-send-tags)
                                      nil)
                                     ((eq (car org-overdrive-send-tags) 'not)
                                      (cl-set-difference
                                       (org-get-tags)
                                       (cdr org-overdrive-send-tags)
                                       :test #'string-equal-ignore-case))
                                     (t
                                      (cl-set-difference
                                       org-overdrive-send-tags
                                       (org-get-tags)
                                       :test #'string-equal-ignore-case)))))))
          (cons 'fields (cl-loop
                         for (field . value) in org-overdrive-cloze-fields
                         as string = (org-overdrive--instantiate value)
                         if (eq t value)
                         collect (cons field html)
                         else unless (null string)
                         collect (cons field string)))
          (cons 'suspend? (save-excursion
                            (goto-char (line-beginning-position))
                            (looking-at-p org-overdrive-rx-comment-glyph))))))
    (message "No implicit clozes found, skipping:  %s" text)
    nil))

(defun org-overdrive--instantiate (input)
  "Return INPUT if it's a string, else funcall or eval it."
  (condition-case signal
      (cond ((stringp input)
             input)
            ((functionp input)
             (save-excursion
               (save-match-data
                 (funcall input))))
            ((null input)
             (display-warning
              'org-overdrive "A cdr of `org-overdrive-cloze-fields' appears to be nil")
             "")
            ((listp input)
             (eval input t))
            (t ""))
    ;; IME this is a common source of errors (and I'm the package dev!), so
    ;; help tell the user where the error's coming from.
    ((error debug)
     (error "There was likely a problem evaluating a member of `org-overdrive-cloze-fields':  %s signaled %s"
            input
            signal))))

(defun org-overdrive-outline-at-point ()
  "Return the Org heading outline at point."
  (let ((outline (list (org-get-title))))
    (save-excursion
      (while (org-up-heading-safe)
        (push (org-no-properties (org-get-heading)) outline)))
    (string-join (nreverse outline) " > ")))

(defun org-overdrive-check ()
  "Check that everything is ready, else return nil."
  (unless (assoc org-overdrive-inline-emphasis-type
                 org-emphasis-alist)
    (user-error "Invalid value for `org-overdrive-inline-emphasis-type'"))
  (unless (executable-find "pgrep")
    (user-error "Could not find executable `pgrep'"))
  (when (string-empty-p (shell-command-to-string "pgrep anki"))
    (user-error "Anki doesn't seem to be running")))

(defun org-overdrive-push-notes-in-buffer-1 ()
  "Push notes in buffer, and return the count of pushes made."
  ;; NOTE: Scan for new flashcards last, otherwise you waste compute
  ;; cycles because you submit the new ones twice
  (save-mark-and-excursion
    (+
     (cl-loop initially (goto-char (point-min))
              while (re-search-forward org-overdrive-rx-eol nil t)
              count (org-overdrive--push-note
                     :field-beg (save-excursion
                                  (save-match-data
                                    (goto-char (line-beginning-position))
                                    (re-search-forward (rx bol (* space))
                                                       (line-end-position) t)
                                    (if (looking-at org-overdrive-list-bullet-re)
                                        (match-end 0)
                                      (point))))
                     :field-end (match-beginning 0)
                     :note-id (string-to-number (match-string 1))))

     (cl-loop initially (goto-char (point-min))
              while (re-search-forward org-overdrive-rx-eol-new nil t)
              count (org-overdrive--push-note
                     :field-beg (save-excursion
                                  (save-match-data
                                    (goto-char (line-beginning-position))
                                    (re-search-forward (rx bol (* space))
                                                       (line-end-position) t)
                                    (if (looking-at org-overdrive-list-bullet-re)
                                        (match-end 0)
                                      (point))))
                     :field-end (match-beginning 0)
                     :note-id -1))

     (cl-loop initially (goto-char (point-min))
              while (re-search-forward org-overdrive-rx-struct nil t)
              count (org-overdrive--push-note
                     :field-beg (1+ (line-end-position))
                     :field-end (save-excursion
                                  (save-match-data
                                    (search-forward "#+end_flashcard")
                                    (1- (line-beginning-position))))
                     :note-id (string-to-number (match-string 1))))

     (cl-loop initially (goto-char (point-min))
              while (re-search-forward org-overdrive-rx-struct-new nil t)
              count (org-overdrive--push-note
                     :field-beg (1+ (line-end-position))
                     :field-end (save-excursion
                                  (save-match-data
                                    (search-forward "#+end_flashcard")
                                    (1- (line-beginning-position))))
                     :note-id -1)))))

;;;###autoload
(defun org-overdrive-push-notes-in-buffer (&optional called-interactively)
  "Push all flashcards in the buffer to Anki.
Argument CALLED-INTERACTIVELY sets itself."
  (interactive "p")
  (org-overdrive-check)
  (setq org-overdrive--known-flashcard-places nil)
  (unless (file-writable-p buffer-file-name)
    (error "Can't write to path (no permissions?): %s"
           buffer-file-name))
  (let (pushed
        (already-modified (buffer-modified-p)))
    (unwind-protect
        (progn
          (advice-add 'org-html-link :around #'org-overdrive--ox-html-link)
          (setq pushed (org-overdrive-push-notes-in-buffer-1)))
      (advice-remove 'org-html-link #'org-overdrive--ox-html-link))
    (if already-modified
        (message "Not saving buffer %s" (current-buffer))
      (save-buffer))
    (if called-interactively
        (message "Pushed %d notes!" pushed)
      pushed)))

(defvar org-overdrive--directory nil
  "Directory in which to look for Org files.
Set by `org-overdrive-push-notes-in-directory'.")

(defvar org-overdrive--file-list nil
  "Internal use only.")

(defun org-overdrive--prep-file-list (_)
  "Populate `org-overdrive--file-list'.
Do so with files found in `org-overdrive--directory'."
  (setq org-overdrive--file-list
        (cl-loop for path in (directory-files-recursively
                              org-overdrive--directory "\\.org$" nil t)
                 ;; Filter out ignores
                 unless (cl-find-if (lambda (re) (string-match-p re path))
                                    org-overdrive-ignore-file-regexps)
                 collect path))
  (format "Will push from %d files in %s"
          (length org-overdrive--file-list)
          org-overdrive--directory))

(defun org-overdrive--next (loop)
  "Visit the next file and maybe push notes.
Next file is taken off `org-overdrive--file-list'. If called by an
asyncloop LOOP, repeat until the file list is empty."
  (if (null org-overdrive--file-list)
      "All done"
    (let* ((path (car org-overdrive--file-list))
           (buf (or (find-buffer-visiting path)
                    ;; Skip org-mode for speed
                    (let ((auto-mode-alist nil)
                          (magic-mode-alist nil)
                          (find-file-hook nil))
                      ;; This really speeds things up but a bit breaky
                      ;; cl-letf (((symbol-function #'after-find-file) #'ignore))
                      (find-file-noselect path))))
           (pushed (with-current-buffer buf
                     (org-overdrive-push-notes-in-buffer)))
           (file (buffer-name buf))
           (modified (buffer-modified-p buf)))
      (if (= 0 pushed)
          (progn
            (cl-assert (not modified))
            (kill-buffer buf))
        ;; TODO: merge this with the final sexp in this function
        (message "%sPushed %d notes in %s"
                 (if modified
                     "Not saving! "
                   ;; When cards were pushed, we left the buffer open for
                   ;; inspection, so switch from fundamental-mode to org-mode
                   ;; to avoid shocking user.
                   (with-current-buffer buf
                     (normal-mode))
                   "")
                 pushed
                 buf))
      ;; Eat the file list, one item at a time
      (pop org-overdrive--file-list)
      ;; Repeat this function
      (push t (asyncloop-remainder loop))
      (format " %d files to go, %s"
              (length org-overdrive--file-list)
              (if (= 0 pushed)
                  (format "no cards in:   %s" file)
                (format   "pushed %d from: %s" pushed file))))))

;;;###autoload
(defun org-overdrive-push-notes-in-directory (dir)
  "Push notes from every file in DIR and nested subdirs."
  (interactive "DSend flashcards from all files in directory: ")
  (setq org-overdrive--directory dir)
  (org-overdrive-check)
  (asyncloop-run (list #'org-overdrive--prep-file-list
                       #'org-overdrive--next)
    :log-buffer-name "*org-overdrive*")
  (unless (get-buffer-window "*org-overdrive*" 'visible)
    (display-buffer "*org-overdrive*")))

;;;###autoload
(defun org-overdrive-delete-note-here ()
  "Delete inline cloze note on current line."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (unless (re-search-forward org-overdrive-rx-eol (line-end-position) t)
      (user-error "No card found on current line"))
    (org-overdrive--delete-note (string-to-number (match-string 1)))))

(provide 'org-overdrive)

;;; org-overdrive.el ends here

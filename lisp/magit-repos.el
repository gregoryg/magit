;;; magit-repos.el --- Listing repositories  -*- lexical-binding:t -*-

;; Copyright (C) 2008-2026 The Magit Project Contributors

;; Author: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>
;; Maintainer: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library implements support for listing repositories.  This
;; includes getting a Lisp list of known repositories as well as a
;; mode for listing repositories in a buffer.

;;; Code:

(require 'magit-core)

(declare-function magit-status-setup-buffer "magit-status" (&optional directory))
(declare-function magit-dired-jump "magit-dired" (&optional other-window))

(defvar x-stretch-cursor)

;;; Options

(defcustom magit-repository-directories nil
  "List of directories that are or contain Git repositories.

Each element has the form (DIRECTORY . DEPTH).  DIRECTORY has to be a
directory or a directory file-name, a string.  DEPTH, is an integer, its
absolute value specifies the maximum depth to look for Git repositories.
If it is 0, only add DIRECTORY itself.  If it is positive, do not list
nested repositories.  If it is negative, descend into repositories as
for any other directory.

This option controls which repositories are being listed by
`magit-list-repositories'.  It also affects `magit-status'
\(which see) in potentially surprising ways."
  :package-version '(magit . "3.0.0")
  :group 'magit-essentials
  :safe #'listp
  :type '(repeat (cons directory (integer :tag "Depth"))))

(defgroup magit-repolist nil
  "List repositories in a buffer."
  :link '(info-link "(magit)Repository List")
  :group 'magit-modes)

(defcustom magit-repolist-mode-hook (list #'hl-line-mode)
  "Hook run after entering Magit-Repolist mode."
  :package-version '(magit . "2.9.0")
  :group 'magit-repolist
  :type 'hook
  :get #'magit-hook-custom-get
  :options (list #'hl-line-mode))

(defcustom magit-repolist-columns
  `(("Name"    25 ,#'magit-repolist-column-ident
     ())
    ("Version" 25 ,#'magit-repolist-column-version
     ((:sort magit-repolist-version<)))
    ("B<U"      3 ,#'magit-repolist-column-unpulled-from-upstream
     (;; (:help-echo "Upstream changes not in branch")
      (:right-align t)
      (:sort <)))
    ("B>U"      3 ,#'magit-repolist-column-unpushed-to-upstream
     (;; (:help-echo "Local changes not in upstream")
      (:right-align t)
      (:sort <)))
    ("Path"    99 ,#'magit-repolist-column-path
     ()))
  "List of columns displayed by `magit-list-repositories'.

Each element has the form (HEADER WIDTH FORMAT PROPS).

HEADER is the string displayed in the header.  WIDTH is the width
of the column.  FORMAT is a function that is called with one
argument, the repository identification (usually its basename),
and with `default-directory' bound to the toplevel of its working
tree.  It has to return a string to be inserted or nil.  PROPS is
an alist that supports the keys `:right-align', `:pad-right' and
`:sort'.

The `:sort' function has a weird interface described in the
docstring of `tabulated-list--get-sort'.  Alternatively `<' and
`magit-repolist-version<' can be used as those functions are
automatically replaced with functions that satisfy the interface.
Set `:sort' to nil to inhibit sorting; if unspecified, then the
column is sortable using the default sorter.

You may wish to display a range of numeric columns using just one
character per column and without any padding between columns, in
which case you should use an appropriate HEADER, set WIDTH to 1,
and set `:pad-right' to 0.  \"+\" is substituted for numbers higher
than 9."
  :package-version '(magit . "2.12.0")
  :group 'magit-repolist
  :type '(repeat (list :tag "Column"
                       (string   :tag "Header Label")
                       (integer  :tag "Column Width")
                       (function :tag "Inserter Function")
                       (repeat   :tag "Properties"
                                 (list (choice :tag "Property"
                                               (const :right-align)
                                               (const :pad-right)
                                               (const :sort)
                                               (symbol))
                                       (sexp   :tag "Value"))))))

(defcustom magit-repolist-column-flag-alist
  `((,#'magit-untracked-files . "N")
    (,#'magit-unstaged-files . "U")
    (,#'magit-staged-files . "S"))
  "Association list of predicates and flags for `magit-repolist-column-flag'.

Each element is of the form (FUNCTION . FLAG).  Each FUNCTION is
called with no arguments, with `default-directory' bound to the
top level of a repository working tree, until one of them returns
a non-nil value.  FLAG corresponding to that function is returned
as the value of `magit-repolist-column-flag'."
  :package-version '(magit . "3.0.0")
  :group 'magit-repolist
  :type '(alist :key-type (function :tag "Predicate Function")
                :value-type (string :tag "Flag")))

(defcustom magit-repolist-sort-key '("Path" . nil)
  "Initial sort key for buffer created by `magit-list-repositories'.
If nil, no additional sorting is performed.  Otherwise, this
should be a cons cell (NAME . FLIP).  NAME is a string matching
one of the column names in `magit-repolist-columns'.  FLIP, if
non-nil, means to invert the resulting sort."
  :package-version '(magit . "3.2.0")
  :group 'magit-repolist
  :type '(choice (const nil)
                 (cons (string :tag "Column name")
                       (boolean :tag "Flip order"))))

;;; List Repositories
;;;; List Commands
;;;###autoload
(defun magit-list-repositories (&optional force-global)
  "Display a list of repositories.

Use option `magit-repository-directories' to control which repositories
are displayed.  Use \".dir-locals.el\" to specify a different set of
repositories to be listed, when invoked from below a certain directory.
With a prefix argument, always display the global list."
  (interactive "P")
  (magit-repolist-setup (default-value 'magit-repolist-columns) force-global))

;;;; Mode Commands

(defun magit-repolist-status (&optional _button)
  "Show the status for the repository at point."
  (interactive)
  (if-let ((id (tabulated-list-get-id)))
      (magit-status-setup-buffer (expand-file-name id))
    (user-error "There is no repository at point")))

(defun magit-repolist-mark ()
  "Mark a repository and move to the next line."
  (interactive)
  (magit-repolist--ensure-padding)
  (tabulated-list-put-tag "*" t))

(defun magit-repolist-unmark ()
  "Unmark a repository and move to the next line."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun magit-repolist-fetch (repos)
  "Fetch all marked or listed repositories.

Fetch asynchronously, one repository at a time, and update each
repository's line once its fetch is done.  If Git or SSH asks for a
passphrase, password, username or confirmation, stop that fetch
instead of asking.  When all fetches are done, mark exactly those
repositories for which fetching failed, so that calling this command
again retries only those.

If a fetch is already running, offer to cancel it instead.  The
repositories that were not fetched then remain marked."
  (interactive
   (list (and (not (magit-repolist--fetch-running-p))
              (magit-repolist--get-repos ?*))))
  (cond ((magit-repolist--fetch-running-p)
         (when (magit-confirm 'repolist-cancel-fetch
                 "A fetch is running.  Cancel it")
           (magit-repolist--fetch-cancel)))
        (repos
         (run-hooks 'magit-credential-hook)
         (magit-repolist--fetch-start
          (if (eq repos 'all) (magit-repolist--displayed-repos) repos)))))

(defun magit-repolist-find-file-other-frame (repos file)
  "Find a file in all marked or listed repositories."
  (interactive (list (magit-repolist--get-repos ?*)
                     (read-string "Find file in repositories: ")))
  (magit-repolist--mapc (##find-file-other-frame file) repos))

(defun magit-repolist--ensure-padding ()
  "Set `tabulated-list-padding' to 2, unless that is already non-zero."
  (when (zerop tabulated-list-padding)
    (setq tabulated-list-padding 2)
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun magit-repolist--get-repos (&optional char)
  "Return marked repositories or `all' if none are marked.
If optional CHAR is non-nil, then only return repositories
marked with that character.  If no repositories are marked
then ask whether to act on all repositories instead."
  (or (magit-repolist--marked-repos char)
      (if (magit-confirm 'repolist-all
            "Nothing selected.  Act on ALL displayed repositories")
          'all
        (user-error "Abort"))))

(defun magit-repolist--marked-repos (&optional char)
  "Return marked repositories.
If optional CHAR is non-nil, then only return repositories
marked with that character."
  (let (c list)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let ((id (tabulated-list-get-id)))
          (setq c (char-after))
          (unless (eq c ?\s)
            (if char
                (when (eq c char)
                  (push id list))
              (push (cons c id) list))))
        (forward-line)))
    list))

(defun magit-repolist--mapc (fn repos &optional msg)
  "Apply FN to each directory in REPOS for side effects only.
If REPOS is the symbol `all', then call FN for all displayed
repositories.  When FN is called, `default-directory' is bound to
the top-level directory of the current repository.  If optional
MSG is non-nil then that is displayed around each call to FN.
If it contains \"%s\" then the directory is substituted for that."
  (when (eq repos 'all)
    (setq repos (magit-repolist--displayed-repos)))
  (let ((base default-directory)
        (len (length repos))
        (i 0))
    (dolist (repo repos)
      (let ((default-directory
             (file-name-as-directory (expand-file-name repo base))))
        (if msg
            (let ((msg (concat (format "(%s/%s) " (incf i) len)
                               (format msg default-directory))))
              (message msg)
              (funcall fn)
              (message (concat msg "done")))
          (funcall fn))))))

(defun magit-repolist--displayed-repos ()
  "Return the ids of all displayed repositories, in display order."
  (let (repos)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let ((id (tabulated-list-get-id)))
          (push id repos))
        (forward-line)))
    (nreverse repos)))

;;;; Fetch

(defvar-local magit-repolist--fetch-queue nil
  "Repositories that remain to be fetched.")

(defvar-local magit-repolist--fetch-process nil
  "The process of the running fetch, if any.")

(defvar-local magit-repolist--fetch-total 0
  "The number of repositories in the running fetch.")

(defvar-local magit-repolist--fetch-failed nil
  "Alist of repositories for which fetching failed and why.")

(defun magit-repolist--fetch-running-p ()
  "Return non-nil if a fetch is running in the current buffer."
  (process-live-p magit-repolist--fetch-process))

(defun magit-repolist--fetch-start (repos)
  "Start fetching REPOS, one at a time."
  (setq magit-repolist--fetch-queue repos)
  (setq magit-repolist--fetch-total (length repos))
  (setq magit-repolist--fetch-failed nil)
  (magit-repolist--fetch-next))

(defun magit-repolist--fetch-next ()
  "Start fetching the next repository, or finish if there is none."
  (if-let ((repo (pop magit-repolist--fetch-queue)))
      (let* ((buffer (current-buffer))
             (default-directory (file-name-as-directory repo))
             (process (magit-start-git nil "remote" "update")))
        (process-put process 'magit-repolist-buffer buffer)
        (process-put process 'magit-repolist-repo repo)
        (set-process-filter process #'magit-repolist--fetch-filter)
        (set-process-sentinel process #'magit-repolist--fetch-sentinel)
        (setq magit-repolist--fetch-process process)
        (message "(%s/%s) Fetching in %s..."
                 (- magit-repolist--fetch-total
                    (length magit-repolist--fetch-queue))
                 magit-repolist--fetch-total
                 (abbreviate-file-name repo)))
    (setq magit-repolist--fetch-process nil)
    (magit-repolist--fetch-finish)))

(defun magit-repolist--fetch-filter (process string)
  "Insert STRING into PROCESS's buffer, but stop PROCESS if it prompts.
Recognize prompts using the same options as `magit-process-filter',
and record the prompt as the reason why fetching failed.  Look for a
prompt in the last line of output, not just in STRING, because the
output of a prompt may arrive in several pieces."
  (let ((magit-process-yes-or-no-prompt-regexp regexp-unmatchable)
        (magit-process-username-prompt-regexps nil)
        (magit-process-password-prompt-regexps nil)
        (magit-process-prompt-functions nil))
    (magit-process-filter process string))
  (when-let ((prompt (magit-repolist--fetch-prompt
                      (with-current-buffer (process-buffer process)
                        (let ((end (process-mark process)))
                          (buffer-substring-no-properties
                           (save-excursion (goto-char end) (pos-bol))
                           end))))))
    (process-put process 'magit-repolist-reason prompt)
    (kill-process process)))

(defun magit-repolist--fetch-prompt (string)
  "Return the prompt in STRING, if any, without trailing whitespace."
  (and-let* ((prompt
              (or (magit-process-match-prompt
                   magit-process-password-prompt-regexps string)
                  (magit-process-match-prompt
                   magit-process-username-prompt-regexps string)
                  (and-let* ((beg (string-match
                                   magit-process-yes-or-no-prompt-regexp
                                   string)))
                    (substring string 0 beg)))))
    (string-trim prompt)))

(defun magit-repolist--fetch-sentinel (process _event)
  "Record the outcome of fetching with PROCESS and fetch the next repository."
  (unless (process-live-p process)
    (when (eq process magit-this-process)
      (setq magit-this-process nil))
    (let ((inhibit-message t))
      (magit-process-finish process))
    (let ((buffer (process-get process 'magit-repolist-buffer))
          (repo (process-get process 'magit-repolist-repo)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (unless (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
            (push (cons repo
                        (or (process-get process 'magit-repolist-reason)
                            (magit-process-error-summary
                             (process-buffer process)
                             (process-get process 'section))
                            (format "exit status %s"
                                    (process-exit-status process))))
                  magit-repolist--fetch-failed))
          (magit-repolist--update-entry repo)
          (when (eq process magit-repolist--fetch-process)
            (magit-repolist--fetch-next)))))))

(defun magit-repolist--fetch-cancel ()
  "Cancel the running fetch.
The repositories that were not fetched count as failed."
  (dolist (repo magit-repolist--fetch-queue)
    (push (cons repo "not fetched") magit-repolist--fetch-failed))
  (setq magit-repolist--fetch-queue nil)
  (when-let ((process magit-repolist--fetch-process))
    (process-put process 'magit-repolist-reason "cancelled")
    (kill-process process)))

(defun magit-repolist--fetch-finish ()
  "Mark the repositories for which fetching failed and report the outcome."
  (let ((failed (reverse magit-repolist--fetch-failed))
        (total magit-repolist--fetch-total))
    (when failed
      (magit-repolist--ensure-padding))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (cond ((not id) (forward-line))
                ((assoc id failed) (magit-repolist-mark))
                ((> tabulated-list-padding 0) (magit-repolist-unmark))
                ((forward-line))))))
    (if failed
        (message "Fetched %s of %s repositories; failed (and marked):\n%s"
                 (- total (length failed)) total
                 (mapconcat (pcase-lambda (`(,repo . ,reason))
                              (format "  %s: %s"
                                      (file-name-nondirectory
                                       (directory-file-name repo))
                                      reason))
                            failed "\n"))
      (message "Fetched %s repositories" total))))

(defun magit-repolist--update-entry (id)
  "Recompute the columns of the repository ID and print its line again."
  (when-let ((entry (assoc id tabulated-list-entries)))
    (let* ((name (car (rassoc id (magit-list-repos-uniquify
                                  (mapcar (##cons (file-name-nondirectory
                                                   (directory-file-name %))
                                                  %)
                                          (mapcar #'car
                                                  tabulated-list-entries))))))
           (new (magit-repolist--format-entry (cons name id))))
      (setcar (cdr entry) (cadr new))
      (save-excursion
        (goto-char (point-min))
        (while (and (not (equal (tabulated-list-get-id) id))
                    (zerop (forward-line))))
        (when (equal (tabulated-list-get-id) id)
          (let ((inhibit-read-only t)
                (tag (buffer-substring (point)
                                       (+ (point) tabulated-list-padding))))
            (delete-region (point) (progn (forward-line) (point)))
            (apply tabulated-list-printer entry)
            (when (> tabulated-list-padding 0)
              (forward-line -1)
              (tabulated-list-put-tag tag))))))))

;;;; Mode

(defvar-keymap magit-repolist-mode-map
  :doc "Local keymap for Magit-Repolist mode buffers."
  :parent tabulated-list-mode-map
  "C-m" #'magit-repolist-status
  "m"   #'magit-repolist-mark
  "u"   #'magit-repolist-unmark
  "f"   #'magit-repolist-fetch
  "5"   #'magit-repolist-find-file-other-frame
  "<remap> <dired-jump>" #'magit-dired-jump)

(define-derived-mode magit-repolist-mode tabulated-list-mode "Repos"
  "Major mode for browsing a list of Git repositories."
  :interactive nil
  :group 'magit-repolist
  (setq-local x-stretch-cursor nil)
  (setq tabulated-list-padding 0)
  (setq-local tabulated-list-revert-hook (list #'magit-repolist-refresh t))
  (setq imenu-prev-index-position-function
        #'magit-repolist--imenu-prev-index-position)
  (setq imenu-extract-index-name-function #'tabulated-list-get-id))

(defun magit-repolist-setup (columns &optional force-global)
  (unless magit-repository-directories
    (user-error "You need to customize `magit-repository-directories' %s"
                "before you can list repositories"))
  (let ((dir (and (not force-global)
                  (buffer-local-boundp 'magit-repository-directories
                                       (current-buffer))
                  (or (locate-dominating-file default-directory
                                              #'dir-locals--all-files)
                      default-directory))))
    (with-current-buffer
        (get-buffer-create
         (if dir
             (let ((magit-uniquify-buffer-names nil))
               (funcall magit-generate-buffer-name-function
                        'magit-repo-list-mode))
           "*Magit Repositories*"))
      (setq default-directory (or dir (expand-file-name "~")))
      (magit-repolist-mode)
      (setq-local magit-repolist-columns columns)
      (when dir
        (hack-local-variables 'only))
      (magit-repolist-setup-1)
      (magit-repolist-refresh)
      (switch-to-buffer (current-buffer)))))

(defun magit-repolist-setup-1 ()
  (unless tabulated-list-sort-key
    (setq tabulated-list-sort-key
          (pcase-let ((`(,column . ,flip) magit-repolist-sort-key))
            (cons (or (car (assoc column magit-repolist-columns))
                      (caar magit-repolist-columns))
                  flip))))
  (setq tabulated-list-format
        (vconcat (seq-map-indexed
                  (lambda (column idx)
                    (pcase-let* ((`(,title ,width ,_fn ,props) column)
                                 (sort-set (assoc :sort props))
                                 (sort-fn (cadr sort-set)))
                      (nconc (list title width
                                   (cond ((eq sort-fn '<)
                                          (magit-repolist-make-sorter
                                           sort-fn #'string-to-number idx))
                                         ((eq sort-fn 'magit-repolist-version<)
                                          (magit-repolist-make-sorter
                                           sort-fn #'identity idx))
                                         (sort-fn sort-fn)
                                         (sort-set nil)
                                         (t)))
                             (flatten-tree props))))
                  magit-repolist-columns))))

(defun magit-repolist-refresh ()
  (setq tabulated-list-entries
        (mapcar #'magit-repolist--format-entry
                (magit-list-repos-uniquify
                 (mapcar (##cons (file-name-nondirectory (directory-file-name %))
                                 %)
                         (magit-list-repos)))))
  (message "Listing repositories...")
  (tabulated-list-init-header)
  (tabulated-list-print t)
  (message "Listing repositories...done"))

(defun magit-repolist--format-entry (entry)
  (pcase-let ((`(,id . ,default-directory) entry))
    (list default-directory
          (vconcat
           (mapcar (pcase-lambda (`(,title ,width ,fn ,props))
                     (or (funcall fn `((:id ,id)
                                       (:title ,title)
                                       (:width ,width)
                                       ,@props))
                         ""))
                   magit-repolist-columns)))))

(defun magit-repolist--imenu-prev-index-position ()
  (and (not (bobp))
       (forward-line -1)))

;;;; Columns

(defun magit-repolist-make-sorter (sort-predicate convert-cell column-idx)
  "Return a function suitable as a sorter for tabulated lists.
See `tabulated-list--get-sorter'.  Given a more reasonable API
this would not be necessary and one could just use SORT-PREDICATE
directly.  CONVERT-CELL can be used to turn the cell value, which
is always a string back into, e.g., a number.  COLUMN-IDX has to
be the index of the column that uses the returned sorter function."
  (lambda (a b)
    (funcall sort-predicate
             (funcall convert-cell (aref (cadr a) column-idx))
             (funcall convert-cell (aref (cadr b) column-idx)))))

(defun magit-repolist-column-ident (spec)
  "Insert the identification of the repository.
Usually this is just its basename."
  (cadr (assq :id spec)))

(defun magit-repolist-column-path (_)
  "Insert the absolute path of the repository."
  (abbreviate-file-name default-directory))

(defvar magit-repolist-column-version-regexp "\
\\(?1:-\\(?2:[0-9]*\\)\
\\(?3:-g[a-z0-9]*\\)\\)?\
\\(?:-\\(?4:dirty\\)\\)\
?\\'")

(defun magit-repolist-column-version (_)
  "Insert a description of the repository's `HEAD' revision."
  (cond-let
    ([v (magit-git-string "describe" "--tags" "--dirty")]
     (save-match-data
       (when (string-match magit-repolist-column-version-regexp v)
         (magit--put-face (match-beginning 0) (match-end 0) 'shadow v)
         (when (match-end 2)
           (magit--put-face (match-beginning 2) (match-end 2) 'bold v))
         (when (match-end 4)
           (magit--put-face (or (match-beginning 3) (match-beginning 4))
                            (match-end 4) 'error v)))
       (when (string-match-p "\\`[0-9]" v)
         (setq v (concat " " v)))
       v))
    ([v (magit-rev-format "#%cd-g%h" nil "--date=format:%Y%m%d")]
     (magit--put-face 0 (length v) 'shadow v)
     (when (magit-anything-modified-p)
       (setq v (concat v "-dirty"))
       (magit--put-face 9 (length v) 'error v))
     v)))

(defun magit-repolist-version< (a b)
  (save-match-data
    (let ((re "[0-9]+\\(\\.[0-9]*\\)*"))
      (setq a (and (string-match re a) (match-str 0 a)))
      (setq b (and (string-match re b) (match-str 0 b)))
      (cond ((and a b) (version< a b))
            (b nil)
            (t)))))

(defun magit-repolist-column-branch (_)
  "Insert the current branch."
  (if (file-exists-p ".git")
      (let ((branch (magit-get-current-branch)))
        (if (member branch magit-main-branch-names)
            (magit--propertize-face branch 'shadow)
          branch))
    (magit--propertize-face "(unpopulated)" 'warning)))

(defun magit-repolist-column-upstream (_)
  "Insert the upstream branch of the current branch."
  (magit-get-upstream-branch))

(defun magit-repolist-column-flag (_)
  "Insert a flag as specified by `magit-repolist-column-flag-alist'.

By default this indicates whether there are uncommitted changes.
- N if there is at least one untracked file.
- U if there is at least one unstaged file.
- S if there is at least one staged file.
Only one letter is shown, the first that applies."
  (seq-some (pcase-lambda (`(,fun . ,flag))
              (and (funcall fun) flag))
            magit-repolist-column-flag-alist))

(defun magit-repolist-column-flags (_)
  "Insert all flags as specified by `magit-repolist-column-flag-alist'.
This is an alternative to function `magit-repolist-column-flag',
which only lists the first one found."
  (mapconcat (pcase-lambda (`(,fun . ,flag))
               (if (funcall fun) flag " "))
             magit-repolist-column-flag-alist
             ""))

(defun magit-repolist-column-unpulled-from-upstream (spec)
  "Insert number of upstream commits not in the current branch."
  (and$ (magit-get-upstream-branch)
        (magit-repolist-insert-count (cadr (magit-rev-diff-count "HEAD" $))
                                     spec)))

(defun magit-repolist-column-unpulled-from-pushremote (spec)
  "Insert number of commits in the push branch but not the current branch."
  (and$ (magit-get-push-branch nil t)
        (magit-repolist-insert-count (cadr (magit-rev-diff-count "HEAD" $))
                                     spec)))

(defun magit-repolist-column-unpushed-to-upstream (spec)
  "Insert number of commits in the current branch but not its upstream."
  (and$ (magit-get-upstream-branch)
        (magit-repolist-insert-count (car (magit-rev-diff-count "HEAD" $))
                                     spec)))

(defun magit-repolist-column-unpushed-to-pushremote (spec)
  "Insert number of commits in the current branch but not its push branch."
  (and$ (magit-get-push-branch nil t)
        (magit-repolist-insert-count (car (magit-rev-diff-count "HEAD" $))
                                     spec)))

(defun magit-repolist-column-branches (spec)
  "Insert number of branches."
  (magit-repolist-insert-count (length (magit-list-local-branches))
                               `((:normal-count 1) ,@spec)))

(defun magit-repolist-column-stashes (spec)
  "Insert number of stashes."
  (magit-repolist-insert-count (length (magit-list-stashes)) spec))

(defun magit-repolist-insert-count (n spec)
  (magit--propertize-face
   (if (and  (> n 9) (= (cadr (assq :width spec)) 1))
       "+"
     (number-to-string n))
   (if (> n (or (cadr (assq :normal-count spec)) 0)) 'bold 'shadow)))

;;; Read Repository

(defun magit-read-repository (&optional read-directory-name)
  "Read a Git repository in the minibuffer, with completion.

The completion choices are the basenames of top-levels of
repositories found in the directories specified by option
`magit-repository-directories'.  In case of name conflicts
the basenames are prefixed with the name of the respective
parent directories.  The returned value is the actual path
to the selected repository.

If READ-DIRECTORY-NAME is non-nil or no repositories can be
found based on the value of `magit-repository-directories',
then read an arbitrary directory using `read-directory-name'
instead."
  (if-let ((repos (and (not read-directory-name)
                       magit-repository-directories
                       (magit-repos-alist))))
      (let ((reply (magit-completing-read
                    "Git repository" repos nil 'any nil nil
                    (and-let* ((_(derived-mode-p 'dired-mode))
                               (path (and (fboundp 'dired-get-filename)
                                          (dired-get-filename nil t)))
                               (_(magit-git-repo-p path))
                               (name (file-relative-name path)))
                      (if (member (cdr (assoc name repos)) (list path nil))
                          name
                        path)))))
        (file-name-as-directory
         (or (cdr (assoc reply repos))
             (if (file-directory-p reply)
                 (expand-file-name reply)
               (user-error "Not a repository or a directory: %s" reply)))))
    (file-name-as-directory
     (read-directory-name "Git repository: "
                          (or (magit-toplevel) default-directory)))))

(defun magit-list-repos ()
  (mapcan (pcase-lambda (`(,dir . ,depth))
            (magit-list-repos-1 dir (abs depth) (< depth 0)))
          magit-repository-directories))

(defun magit-list-repos-1 (directory depth nested)
  (let ((repop (file-readable-p (expand-file-name ".git" directory))))
    (nconc
     (and repop (list (file-name-as-directory directory)))
     (and (> depth 0)
          (or nested (not repop))
          (file-accessible-directory-p directory)
          (mapcan (##and (file-directory-p %)
                         (magit-list-repos-1 % (1- depth) nested))
                  (directory-files directory t
                                   directory-files-no-dot-files-regexp t))))))

(defun magit-list-repos-uniquify (alist)
  (let (result (dict (make-hash-table :test #'equal)))
    (dolist (a (delete-dups alist))
      (puthash (car a) (cons (cdr a) (gethash (car a) dict)) dict))
    (maphash
     (lambda (key value)
       (if (length= value 1)
           (push (cons key (car value)) result)
         (setq result
               (append
                result
                (magit-list-repos-uniquify
                 (mapcar (lambda (v)
                           (cons (concat
                                  key
                                  (or (bound-and-true-p uniquify-separator)
                                      "\\")
                                  (file-name-nondirectory
                                   (directory-file-name
                                    (substring v 0 (- (1+ (length key)))))))
                                 v))
                         value))))))
     dict)
    result))

(defun magit-repos-alist ()
  (magit-list-repos-uniquify
   (mapcar (##cons (file-name-nondirectory (directory-file-name %)) %)
           (magit-list-repos))))

;;; _
(provide 'magit-repos)
;; Local Variables:
;; read-symbol-shorthands: (
;;   ("and$"         . "cond-let--and$")
;;   ("thread$"      . "cond-let--thread$")
;;   ("when$"        . "cond-let--when$")
;;   ("and-let*"     . "cond-let--and-let*")
;;   ("and-let"      . "cond-let--and-let")
;;   ("if-let*"      . "cond-let--if-let*")
;;   ("if-let"       . "cond-let--if-let")
;;   ("when-let*"    . "cond-let--when-let*")
;;   ("when-let"     . "cond-let--when-let")
;;   ("while-let*"   . "cond-let--while-let*")
;;   ("while-let"    . "cond-let--while-let")
;;   ("match-string" . "match-string")
;;   ("match-str"    . "match-string-no-properties"))
;; End:
;;; magit-repos.el ends here

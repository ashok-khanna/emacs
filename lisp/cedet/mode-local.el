;;; mode-local.el --- Support for mode local facilities  -*- lexical-binding:t -*-
;;
;; Copyright (C) 2004-2005, 2007-2021 Free Software Foundation, Inc.
;;
;; Author: David Ponce <david@dponce.com>
;; Created: 27 Apr 2004
;; Keywords: syntax

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Each major mode will want to support a specific set of behaviors.
;; Usually generic behaviors that need just a little bit of local
;; specifics.
;;
;; This library permits the setting of override functions for tasks of
;; that nature, and also provides reasonable defaults.
;;
;; There are buffer local variables (and there were frame local variables).
;; This library gives the illusion of mode specific variables.
;;
;; You should use a mode-local variable or override to allow extension
;; only if you expect a mode author to provide that extension.  If a
;; user might wish to customize a given variable or function then
;; the existing customization mechanism should be used.

;; To Do:
;; Allow customization of a variable for a specific mode?
;;
;; Add macro for defining the '-default' functionality.

;;; Code:

(require 'find-func)
;; For find-function-regexp-alist. It is tempting to replace this
;; ‘require’ by (defvar find-function-regexp-alist) and
;; with-eval-after-load, but model-local.el is typically loaded when a
;; semantic autoload is invoked, and something in semantic loads
;; find-func.el before mode-local.el, so the eval-after-load is lost.

;;; Misc utilities
;;
(defun mode-local-map-file-buffers (function &optional predicate buffers)
  "Run FUNCTION on every file buffer found.
FUNCTION does not have arguments; when it is entered `current-buffer'
is the currently selected file buffer.
If optional argument PREDICATE is non-nil, only select file buffers
for which the function PREDICATE returns non-nil.
If optional argument BUFFERS is non-nil, it is a list of buffers to
walk through.  It defaults to `buffer-list'."
  (dolist (b (or buffers (buffer-list)))
    (and (buffer-live-p b) (buffer-file-name b)
         (with-current-buffer b
           (when (or (not predicate) (funcall predicate))
             (funcall function))))))

(defsubst get-mode-local-parent (mode)
  "Return the mode parent of the major mode MODE.
Return nil if MODE has no parent."
  (or (get mode 'mode-local-parent)
      (get mode 'derived-mode-parent)))

;; FIXME doc (and function name) seems wrong.
;; Return a list of MODE and all its parent modes, if any.
;; Lists parent modes first.
(defun mode-local-equivalent-mode-p (mode)
  "Is the major-mode in the current buffer equivalent to a mode in MODES."
  (let ((modes nil))
    (while mode
      (setq modes (cons mode modes)
	    mode  (get-mode-local-parent mode)))
    modes))

(defun mode-local-map-mode-buffers (function modes)
  "Run FUNCTION on every file buffer with major mode in MODES.
MODES can be a symbol or a list of symbols.
FUNCTION does not have arguments."
  (or (listp modes) (setq modes (list modes)))
  (mode-local-map-file-buffers
   function (lambda ()
              (let ((mm (mode-local-equivalent-mode-p major-mode))
                    (ans nil))
                (while (and (not ans) mm)
                  (setq ans (memq (car mm) modes)
                        mm (cdr mm)) )
                ans))))

;;; Hook machinery
;;
(defvar mode-local-init-hook nil
  "Hook run after a new file buffer is created.
The current buffer is the newly created file buffer.")

(defvar mode-local-changed-mode-buffers nil
  "List of buffers whose `major-mode' has changed recently.")

(defvar mode-local--init-mode nil)

(defsubst mode-local-initialized-p ()
  "Return non-nil if mode local is initialized in current buffer.
That is, if the current `major-mode' is equal to the major mode for
which mode local bindings have been activated."
  (eq mode-local--init-mode major-mode))

(defun mode-local-post-major-mode-change ()
  "Initialize mode-local facilities.
This is run from `find-file-hook', and from `post-command-hook'
after changing the major mode."
  (remove-hook 'post-command-hook #'mode-local-post-major-mode-change nil)
  (let ((buffers mode-local-changed-mode-buffers))
    (setq mode-local-changed-mode-buffers nil)
    (mode-local-map-file-buffers
     (lambda ()
       ;; Make sure variables are set up for this mode.
       (mode-local--activate-bindings)
       (run-hooks 'mode-local-init-hook))
     (lambda ()
       (not (mode-local-initialized-p)))
     buffers)))

(defun mode-local-on-major-mode-change ()
  "Function called in `change-major-mode-hook'."
  (add-to-list 'mode-local-changed-mode-buffers (current-buffer))
  (add-hook 'post-command-hook #'mode-local-post-major-mode-change t nil))

;;; Mode lineage
;;
(define-obsolete-function-alias 'set-mode-local-parent
  #'mode-local--set-parent "27.1")
(defsubst mode-local--set-parent (mode parent)
  "Set parent of major mode MODE to PARENT mode.
To work properly, this function should be called after PARENT mode
local variables have been defined."
  (put mode 'mode-local-parent parent)
  ;; Refresh mode bindings to get mode local variables inherited from
  ;; PARENT. To work properly, the following should be called after
  ;; PARENT mode local variables have been defined.
  (mode-local-map-mode-buffers #'mode-local--activate-bindings mode))

(defmacro define-child-mode (mode parent &optional _docstring)
  "Make major mode MODE inherit behavior from PARENT mode.
DOCSTRING is optional and not used.
To work properly, this should be put after PARENT mode local variables
definition."
  (declare (obsolete define-derived-mode "27.1"))
  `(mode-local--set-parent ',mode ',parent))

(defun mode-local-use-bindings-p (this-mode desired-mode)
  "Return non-nil if THIS-MODE can use bindings of DESIRED-MODE."
  (let ((ans nil))
    (while (and (not ans) this-mode)
      (setq ans (eq this-mode desired-mode))
      (setq this-mode (get-mode-local-parent this-mode)))
    ans))


;;; Core bindings API
;;
(defvar-local mode-local-symbol-table nil
  "Buffer local mode bindings.
These symbols provide a hook for a `major-mode' to specify specific
behaviors.  Use the function `mode-local-bind' to define new bindings.")

(defvar mode-local-active-mode nil
  "Major mode in which bindings are active.")

(define-obsolete-function-alias 'new-mode-local-bindings
  #'mode-local--new-bindings "27.1")
(defsubst mode-local--new-bindings ()
  "Return a new empty mode bindings symbol table."
  (obarray-make 13))

(defun mode-local-bind (bindings &optional plist mode)
  "Define BINDINGS in the specified environment.
BINDINGS is a list of (VARIABLE . VALUE).
Optional argument PLIST is a property list each VARIABLE symbol will
be set to.  The following properties have special meaning:

- `constant-flag' if non-nil, prevent rebinding variables.
- `mode-variable-flag' if non-nil, define mode variables.
- `override-flag' if non-nil, define override functions.

The `override-flag' and `mode-variable-flag' properties are mutually
exclusive.

If optional argument MODE is non-nil, it must be a major mode symbol.
BINDINGS will be defined globally for this major mode.  If MODE is
nil, BINDINGS will be defined locally in the current buffer, in
variable `mode-local-symbol-table'.  The later should be done in MODE
hook."
  ;; Check plist consistency
  (and (plist-get plist 'mode-variable-flag)
       (plist-get plist 'override-flag)
       (error "Bindings can't be both overrides and mode variables"))
  (let (table variable varname value binding)
    (if mode
        (progn
          ;; Install in given MODE symbol table.  Create a new one if
          ;; needed.
          (setq table (or (get mode 'mode-local-symbol-table)
                          (mode-local--new-bindings)))
          (put mode 'mode-local-symbol-table table))
      ;; Fail if trying to bind mode variables in local context!
      (if (plist-get plist 'mode-variable-flag)
          (error "Mode required to bind mode variables"))
      ;; Install in buffer local symbol table.  Create a new one if
      ;; needed.
      (setq table (or mode-local-symbol-table
                      (setq mode-local-symbol-table
                            (mode-local--new-bindings)))))
    (while bindings
      (setq binding  (car bindings)
            bindings (cdr bindings)
            varname  (symbol-name (car binding))
            value    (cdr binding))
      (if (setq variable (intern-soft varname table))
          ;; Binding already exists
          ;; Check rebind consistency
          (cond
           ((equal (symbol-value variable) value)
            ;; Just ignore rebind with the same value.
            )
           ((get variable 'constant-flag)
            (error "Can't change the value of constant `%s'"
                   variable))
           ((and (get variable 'mode-variable-flag)
                 (plist-get plist 'override-flag))
            (error "Can't rebind override `%s' as a mode variable"
                   variable))
           ((and (get variable 'override-flag)
                 (plist-get plist 'mode-variable-flag))
            (error "Can't rebind mode variable `%s' as an override"
                   variable))
           (t
            ;; Merge plist and assign new value
            (setplist variable (append plist (symbol-plist variable)))
            (set variable value)))
        ;; New binding
        (setq variable (intern varname table))
        ;; Set new plist and assign initial value
        (setplist variable plist)
        (set variable value)))
    ;; Return the symbol table used
    table))

(defsubst mode-local-symbol (symbol &optional mode)
  "Return the mode local symbol bound with SYMBOL's name.
Return nil if the  mode local symbol doesn't exist.
If optional argument MODE is nil, lookup first into locally bound
symbols, then in those bound in current `major-mode' and its parents.
If MODE is non-nil, lookup into symbols bound in that major mode and
its parents."
  (let ((name (symbol-name symbol)) bind)
    (or mode
        (setq mode mode-local-active-mode)
        (setq mode major-mode
              bind (and mode-local-symbol-table
                        (intern-soft name mode-local-symbol-table))))
    (while (and mode (not bind))
      (or (and (get mode 'mode-local-symbol-table)
               (setq bind (intern-soft
                           name (get mode 'mode-local-symbol-table))))
          (setq mode (get-mode-local-parent mode))))
    bind))

(defsubst mode-local-symbol-value (symbol &optional mode property)
  "Return the value of the mode local symbol bound with SYMBOL's name.
If optional argument MODE is non-nil, restrict lookup to that mode and
its parents (see the function `mode-local-symbol' for more details).
If optional argument PROPERTY is non-nil the mode local symbol must
have that property set.  Return nil if the symbol doesn't exist, or
doesn't have PROPERTY set."
  (and (setq symbol (mode-local-symbol symbol mode))
       (or (not property) (get symbol property))
       (symbol-value symbol)))

;;; Mode local variables
;;
(define-obsolete-function-alias 'activate-mode-local-bindings
  #'mode-local--activate-bindings "27.1")
(defun mode-local--activate-bindings (&optional mode)
  "Activate variables defined locally in MODE and its parents.
That is, copy mode local bindings into corresponding buffer local
variables.
If MODE is not specified it defaults to current `major-mode'.
Return the alist of buffer-local variables that have been changed.
Elements are (SYMBOL . PREVIOUS-VALUE), describing one variable."
  ;; Hack -
  ;; do not do this if we are inside set-auto-mode as we may be in
  ;; an initialization race condition.
  (if (boundp 'keep-mode-if-same)
      ;; We are inside set-auto-mode, as this is an argument that is
      ;; vaguely unique.

      ;; This will make sure that when everything is over, this will get
      ;; called and we won't be under set-auto-mode anymore.
      (mode-local-on-major-mode-change)

    ;; Do the normal thing.
    (let (modes table old-locals)
      (unless mode
        (setq-local mode-local--init-mode major-mode)
	(setq mode major-mode))
      ;; Get MODE's parents & MODE in the right order.
      (while mode
	(setq modes (cons mode modes)
	      mode  (get-mode-local-parent mode)))
      ;; Activate mode bindings following parent modes order.
      (dolist (mode modes)
	(when (setq table (get mode 'mode-local-symbol-table))
	  (mapatoms
           (lambda (var)
             (when (get var 'mode-variable-flag)
               (let ((v (intern (symbol-name var))))
                 ;; Save the current buffer-local value of the
                 ;; mode-local variable.
                 (and (local-variable-p v (current-buffer))
                      (push (cons v (symbol-value v)) old-locals))
                 (set (make-local-variable v) (symbol-value var)))))
	   table)))
      old-locals)))

(define-obsolete-function-alias 'deactivate-mode-local-bindings
  #'mode-local--deactivate-bindings "27.1")
(defun mode-local--deactivate-bindings (&optional mode)
  "Deactivate variables defined locally in MODE and its parents.
That is, kill buffer local variables set from the corresponding mode
local bindings.
If MODE is not specified it defaults to current `major-mode'."
  (unless mode
    (kill-local-variable 'mode-local--init-mode)
    (setq mode major-mode))
  (let (table)
    (while mode
      (when (setq table (get mode 'mode-local-symbol-table))
        (mapatoms
         (lambda (var)
           (when (get var 'mode-variable-flag)
             (kill-local-variable (intern (symbol-name var)))))
         table))
      (setq mode (get-mode-local-parent mode)))))

(defmacro with-mode-local-symbol (mode &rest body)
  "With the local bindings of MODE symbol, evaluate BODY.
The current mode bindings are saved, BODY is evaluated, and the saved
bindings are restored, even in case of an abnormal exit.
Value is what BODY returns.
This is like `with-mode-local', except that MODE's value is used.
To use the symbol MODE (quoted), use `with-mode-local'."
  (declare (indent 1))
  (let ((old-mode  (make-symbol "mode"))
        (old-locals (make-symbol "old-locals"))
	(new-mode (make-symbol "new-mode"))
        (local (make-symbol "local")))
    `(let ((,old-mode mode-local-active-mode)
           (,old-locals nil)
	   (,new-mode ,mode)
	   )
       (unwind-protect
           (progn
             (mode-local--deactivate-bindings ,old-mode)
             (setq mode-local-active-mode ,new-mode)
             ;; Save the previous value of buffer-local variables
             ;; changed by `mode-local--activate-bindings'.
             (setq ,old-locals (mode-local--activate-bindings ,new-mode))
             ,@body)
         (mode-local--deactivate-bindings ,new-mode)
         ;; Restore the previous value of buffer-local variables.
         (dolist (,local ,old-locals)
           (set (car ,local) (cdr ,local)))
         ;; Restore the mode local variables.
         (setq mode-local-active-mode ,old-mode)
         (mode-local--activate-bindings ,old-mode)))))

(defmacro with-mode-local (mode &rest body)
  "With the local bindings of MODE, evaluate BODY.
The current mode bindings are saved, BODY is evaluated, and the saved
bindings are restored, even in case of an abnormal exit.
Value is what BODY returns.
This is like `with-mode-local-symbol', except that MODE is quoted
and is not evaluated."
  (declare (indent 1))
  `(with-mode-local-symbol ',mode ,@body))


(defsubst mode-local-value (mode sym)
  "Return the value of the MODE local variable SYM."
  (or mode (error "Missing major mode symbol"))
  (mode-local-symbol-value sym mode 'mode-variable-flag))

(defmacro setq-mode-local (mode &rest args)
  "Assign new values to variables local in MODE.
MODE must be a major mode symbol.
ARGS is a list (SYM VAL SYM VAL ...).
The symbols SYM are variables; they are literal (not evaluated).
The values VAL are expressions; they are evaluated.
Set each SYM to the value of its VAL, locally in buffers already in
MODE, or in buffers switched to that mode.
Return the value of the last VAL."
  (declare (debug (symbolp &rest symbolp form)))
  (when args
    (let (i ll bl sl tmp sym val)
      (setq i 0)
      (while args
        (setq tmp  (make-symbol (format "tmp%d" i))
              i    (1+ i)
              sym  (car args)
              val  (cadr args)
              ll   (cons (list tmp val) ll)
              bl   (cons `(cons ',sym ,tmp) bl)
              sl   (cons `(set (make-local-variable ',sym) ,tmp) sl)
              args (cddr args)))
      `(let* ,(nreverse ll)
         ;; Save mode bindings
         (mode-local-bind (list ,@bl) '(mode-variable-flag t) ',mode)
         ;; Assign to local variables in all existing buffers in MODE
         (mode-local-map-mode-buffers (lambda () ,@sl) ',mode)
         ;; Return the last value
         ,tmp)
      )))

(defmacro defvar-mode-local (mode sym val &optional docstring)
  "Define MODE local variable SYM with value VAL.
DOCSTRING is optional."
  (declare (indent defun)
           (debug (&define symbolp name def-form [ &optional stringp ] )))
  `(progn
     (setq-mode-local ,mode ,sym ,val)
     (put (mode-local-symbol ',sym ',mode)
          'variable-documentation ,docstring)
     ',sym))

(defmacro defconst-mode-local (mode sym val &optional docstring)
  "Define MODE local constant SYM with value VAL.
DOCSTRING is optional."
  (declare (indent defun) (debug defvar-mode-local))
  (let ((tmp (make-symbol "tmp")))
    `(let (,tmp)
       (setq-mode-local ,mode ,sym ,val)
       (setq ,tmp (mode-local-symbol ',sym ',mode))
       (put ,tmp 'constant-flag t)
       (put ,tmp 'variable-documentation ,docstring)
       ',sym)))

;;; Function overloading
;;
(defun make-obsolete-overload (old new when)
  "Mark OLD overload as obsoleted by NEW overload.
WHEN is a string describing the first release where it was made obsolete."
  (put old 'mode-local--overload-obsoleted-by new)
  (put old 'mode-local--overload-obsoleted-since when)
  (put old 'mode-local-overload t)
  (put new 'mode-local--overload-obsolete old))

(define-obsolete-function-alias 'overload-obsoleted-by
  #'mode-local--overload-obsoleted-by "27.1")
(defsubst mode-local--overload-obsoleted-by (overload)
  "Get the overload symbol obsoleted by OVERLOAD.
Return the obsolete symbol or nil if not found."
  (get overload 'mode-local--overload-obsolete))

(define-obsolete-function-alias 'overload-that-obsolete
  #'mode-local--overload-that-obsolete "27.1")
(defsubst mode-local--overload-that-obsolete (overload)
  "Return the overload symbol that obsoletes OVERLOAD.
Return the symbol found or nil if OVERLOAD is not obsolete."
  (get overload 'mode-local--overload-obsoleted-by))

(defsubst fetch-overload (overload)
  "Return the current OVERLOAD function, or nil if not found.
First, lookup for OVERLOAD into locally bound mode local symbols, then
in those bound in current `major-mode' and its parents."
  (or (mode-local-symbol-value overload nil 'override-flag)
      ;; If an obsolete overload symbol exists, try it.
      (and (mode-local--overload-obsoleted-by overload)
           (mode-local-symbol-value
            (mode-local--overload-obsoleted-by overload) nil 'override-flag))))

(defun mode-local--override (name args body)
  "Return the form that handles overloading of function NAME.
ARGS are the arguments to the function.
BODY is code that would be run when there is no override defined.  The
default is to call the function `NAME-default' with the appropriate
arguments.
See also the function `define-overload'."
  (let* ((default (intern (format "%s-default" name)))
         (overargs (delq '&rest (delq '&optional (copy-sequence args))))
         (override (make-symbol "override")))
    `(let ((,override (fetch-overload ',name)))
       (if ,override
           (funcall ,override ,@overargs)
         ,@(or body `((,default ,@overargs)))))
    ))

(defun mode-local--expand-overrides (name args body)
  "Expand override forms that overload function NAME.
ARGS are the arguments to the function NAME.
BODY is code where override forms are searched for expansion.
Return result of expansion, or BODY if no expansion occurred.
See also the function `define-overload'."
  (let ((forms body)
        (ditto t)
        form xbody)
    (while forms
      (setq form (car forms))
      (cond
       ((atom form))
       ((eq (car form) :override)
        (setq form (mode-local--override name args (cdr form))))
       ((eq (car form) :override-with-args)
        (setq form (mode-local--override name (cadr form) (cddr form))))
       ((setq form (mode-local--expand-overrides name args form))))
      (setq ditto (and ditto (eq (car forms) form))
            xbody (cons form xbody)
            forms (cdr forms)))
    (if ditto body (nreverse xbody))))

(defun mode-local--overload-body (name args body)
  "Return the code that implements overloading of function NAME.
ARGS are the arguments to the function NAME.
BODY specifies the overload code.
See also the function `define-overload'."
  (let ((result (mode-local--expand-overrides name args body)))
    (if (eq body result)
        (list (mode-local--override name args body))
      result)))

;;;###autoload
(put 'define-overloadable-function 'doc-string-elt 3)

(defmacro define-overloadable-function (name args docstring &rest body)
  "Define a new function, as with `defun', which can be overloaded.
NAME is the name of the function to create.
ARGS are the arguments to the function.
DOCSTRING is a documentation string to describe the function.  The
docstring will automatically have details about its overload symbol
appended to the end.
BODY is code that would be run when there is no override defined.  The
default is to call the function `NAME-default' with the appropriate
arguments.

BODY can also include an override form that specifies which part of
BODY is specifically overridden.  This permits specifying common code
run for both default and overridden implementations.
An override form is one of:

  1. (:override [OVERBODY])
  2. (:override-with-args OVERARGS [OVERBODY])

OVERBODY is the code that would be run when there is no override
defined.  The default is to call the function `NAME-default' with the
appropriate arguments deduced from ARGS.
OVERARGS is a list of arguments passed to the override and
`NAME-default' function, in place of those deduced from ARGS."
  (declare (doc-string 3)
           (debug (&define name lambda-list stringp def-body)))
  `(eval-and-compile
     (defun ,name ,args
       ,docstring
       ,@(mode-local--overload-body name args body))
     (put ',name 'mode-local-overload t)))
(put :override-with-args 'lisp-indent-function 1)

(define-obsolete-function-alias 'define-overload
  #'define-overloadable-function "27.1")

(define-obsolete-function-alias 'function-overload-p
  #'mode-local--function-overload-p "27.1")
(defsubst mode-local--function-overload-p (symbol)
  "Return non-nil if SYMBOL is a function which can be overloaded."
  (and symbol (symbolp symbol) (get symbol 'mode-local-overload)))

(defmacro define-mode-local-override
  (name mode args docstring &rest body)
  "Define a mode specific override of the function overload NAME.
Has meaning only if NAME has been created with `define-overloadable-function'.
MODE is the major mode this override is being defined for.
ARGS are the function arguments, which should match those of the same
named function created with `define-overload'.
DOCSTRING is the documentation string.
BODY is the implementation of this function."
  ;; FIXME: Make this obsolete and use cl-defmethod with &context instead.
  (declare (doc-string 4)
           (debug (&define name symbolp lambda-list stringp def-body)))
  (let ((newname (intern (format "%s-%s" name mode))))
    `(progn
       (eval-and-compile
	 (defun ,newname ,args
           ,(concat docstring "\n"
                    (internal--format-docstring-line
                     "Override `%s' in `%s' buffers."
                     name mode))
	   ;; The body for this implementation
	   ,@body)
         ;; For find-func to locate the definition of NEWNAME.
         (put ',newname 'definition-name ',name))
       (mode-local-bind '((,name . ,newname))
                        '(override-flag t)
                        ',mode))))

;;; Read/Query Support
(defun mode-local-read-function (prompt &optional initial hist default)
  "Interactively read in the name of a mode-local function.
PROMPT, INITIAL, HIST, and DEFAULT are the same as for `completing-read'."
  (declare (obsolete nil "27.1"))
  (completing-read prompt obarray #'mode-local--function-overload-p t initial hist default))

;;; Help support
;;
(define-obsolete-function-alias 'overload-docstring-extension
  #'mode-local--overload-docstring-extension "27.1")
(defun mode-local--overload-docstring-extension (overload)
  "Return the doc string that augments the description of OVERLOAD."
  (let ((doc "\nThis function can be overloaded\
 with `define-mode-local-override'.")
        (sym (mode-local--overload-obsoleted-by overload)))
    (when sym
      (setq doc (format "%s\nIt has made the overload `%s' obsolete since %s."
                        doc sym
                        (get sym 'mode-local--overload-obsoleted-since))))
    (setq sym (mode-local--overload-that-obsolete overload))
    (when sym
      (setq doc (format
                 "%s\nThis overload is obsolete since %s;\nUse `%s' instead."
                 doc (get overload 'mode-local--overload-obsoleted-since) sym)))
    doc))

(defun mode-local-augment-function-help (symbol)
  "Augment the *Help* buffer for SYMBOL.
SYMBOL is a function that can be overridden."
  (with-current-buffer "*Help*"
    (pop-to-buffer (current-buffer))
    (goto-char (point-min))
    (unless (re-search-forward "^$" nil t)
      (goto-char (point-max))
      (beginning-of-line)
      (forward-line -1))
    (let ((inhibit-read-only t))
      (insert (substitute-command-keys (mode-local--overload-docstring-extension symbol))
              "\n")
      ;; NOTE TO SELF:
      ;; LIST ALL LOADED OVERRIDES FOR SYMBOL HERE
      )))

;; We are called from describe-function in help-fns.el, where this is defined.
(defvar describe-function-orig-buffer)

(defun mode-local--describe-overload (symbol)
  "For `help-fns-describe-function-functions'; add overloads for SYMBOL."
  (when (mode-local--function-overload-p symbol)
    (let ((default (or (intern-soft (format "%s-default" (symbol-name symbol)))
		       symbol))
	  (override (with-current-buffer describe-function-orig-buffer
                      (fetch-overload symbol)))
          modes)

      (insert (substitute-command-keys (mode-local--overload-docstring-extension symbol))
              "\n\n")
      (insert (format-message "default function: `%s'\n" default))
      (if override
	  (insert (format-message "\noverride in buffer `%s': `%s'\n"
				  describe-function-orig-buffer override))
	(insert (format-message "\nno override in buffer `%s'\n"
				describe-function-orig-buffer)))

      (mapatoms
       (lambda (sym) (when (get sym 'mode-local-symbol-table) (push sym modes)))
       obarray)

      (dolist (mode modes)
	(let* ((major-mode mode)
	       (override (fetch-overload symbol)))

	  (when override
	    (insert (format-message "\noverride in mode `%s': `%s'\n"
				    major-mode override))
            )))
      )))

(add-hook 'help-fns-describe-function-functions #'mode-local--describe-overload)

(declare-function xref-item-location "xref" (xref) t)

(defun xref-mode-local--override-present (sym xrefs)
  "Return non-nil if SYM is in XREFS."
  (let (result)
    (while (and (null result)
		xrefs)
      (when (equal sym (car (xref-elisp-location-symbol (xref-item-location (pop xrefs)))))
	(setq result t)))
    result))

(defun xref-mode-local-overload (symbol)
  "For `elisp-xref-find-def-functions'; add overloads for SYMBOL."
  ;; Current buffer is the buffer where xref-find-definitions was invoked.
  (when (mode-local--function-overload-p symbol)
    (let* ((symbol-file (find-lisp-object-file-name
	                 symbol (symbol-function symbol)))
	   (default (intern-soft (format "%s-default" (symbol-name symbol))))
	   (default-file (when default (find-lisp-object-file-name
	                                default (symbol-function default))))
	   modes
	   xrefs)

      (mapatoms
       (lambda (sym) (when (get sym 'mode-local-symbol-table) (push sym modes)))
       obarray)

      ;; mode-local-overrides are inherited from parent modes; we
      ;; don't want to list the same function twice. So order ‘modes’
      ;; with parents first, and check for duplicates.

      (setq modes
	    (sort modes
		  (lambda (a b)
		    ;; a is not a child, or not a child of b
		    (not (equal b (get a 'mode-local-parent))))))

      (dolist (mode modes)
	(let* ((major-mode mode)
	       (override (fetch-overload symbol))
	       (override-file (when override
	                        (find-lisp-object-file-name
	                         override (symbol-function override)))))

	  (when (and override override-file)
	    (let ((meta-name (cons override major-mode))
		  ;; For the declaration:
		  ;;
		  ;;(define-mode-local-override xref-elisp-foo c-mode
		  ;;
		  ;; The override symbol name is
		  ;; "xref-elisp-foo-c-mode". The summary should match
		  ;; the declaration, so strip the mode from the
		  ;; symbol name.
		  (summary (format elisp--xref-format-extra
				   'define-mode-local-override
				   (substring (symbol-name override) 0 (- (1+ (length (symbol-name major-mode)))))
				   major-mode)))

	      (unless (xref-mode-local--override-present override xrefs)
		(push (elisp--xref-make-xref
		       'define-mode-local-override meta-name override-file summary)
		      xrefs))))))

      ;; %s-default is interned whether it is a separate function or
      ;; not, so we have to check that here.
      (when (and (functionp default) default-file)
	(push (elisp--xref-make-xref nil default default-file) xrefs))

      (when symbol-file
	(push (elisp--xref-make-xref 'define-overloadable-function
	                             symbol symbol-file)
	      xrefs))

      xrefs)))

(add-hook 'elisp-xref-find-def-functions #'xref-mode-local-overload)

(defconst xref-mode-local-find-overloadable-regexp
  "(define-overload\\(able-function\\)? +%s"
  "Regexp used by `xref-find-definitions' when searching for a
mode-local overloadable function definition.")

(defun xref-mode-local-find-override (meta-name)
  "Function used by `xref-find-definitions' when searching for an
override of a mode-local overloadable function.
META-NAME is a cons (OVERLOADABLE-SYMBOL . MAJOR-MODE)."
  (let* ((override (car meta-name))
	 (mode (cdr meta-name))
	 (regexp (format "(define-mode-local-override +%s +%s"
			 (substring (symbol-name override) 0 (- (1+ (length (symbol-name mode)))))
			 mode)))
    (re-search-forward regexp nil t)
    ))

(add-to-list 'find-function-regexp-alist
             '(define-overloadable-function
                . xref-mode-local-find-overloadable-regexp))
(add-to-list 'find-function-regexp-alist
             (cons 'define-mode-local-override
                   #'xref-mode-local-find-override))

;; Help for mode-local bindings.
(defun mode-local-print-binding (symbol)
  "Print the SYMBOL binding."
  (let ((value (symbol-value symbol)))
    (princ (format-message "\n     `%s' value is\n       " symbol))
    (if (and value (symbolp value))
        (princ (format-message "`%s'" value))
      (let ((pt (point)))
        (pp value)
        (save-excursion
          (goto-char pt)
          (indent-sexp))))
    (or (bolp) (princ "\n"))))

(defun mode-local-print-bindings (table)
  "Print bindings in TABLE."
  (let (us ;; List of unspecified symbols
        mc ;; List of mode local constants
        mv ;; List of mode local variables
        ov ;; List of overloaded functions
        fo ;; List of final overloaded functions
        )
    ;; Order symbols by type
    (mapatoms
     (lambda (s) (push s (cond
                          ((get s 'mode-variable-flag)
                           (if (get s 'constant-flag) mc mv))
                          ((get s 'override-flag)
                           (if (get s 'constant-flag) fo ov))
                          (t us))))
     table)
    ;; Print symbols by type
    (when us
      (princ "\n  !! Unspecified symbols\n")
      (mapc #'mode-local-print-binding us))
    (when mc
      (princ "\n  ** Mode local constants\n")
      (mapc #'mode-local-print-binding mc))
    (when mv
      (princ "\n  ** Mode local variables\n")
      (mapc #'mode-local-print-binding mv))
    (when fo
      (princ "\n  ** Final overloaded functions\n")
      (mapc #'mode-local-print-binding fo))
    (when ov
      (princ "\n  ** Overloaded functions\n")
      (mapc #'mode-local-print-binding ov))
    ))

(defun mode-local-describe-bindings-2 (buffer-or-mode)
  "Display mode local bindings active in BUFFER-OR-MODE."
  (let (table mode)
    (princ "Mode local bindings active in ")
    (cond
     ((bufferp buffer-or-mode)
      (with-current-buffer buffer-or-mode
        (setq table mode-local-symbol-table
              mode major-mode))
      (princ (format "%S\n" buffer-or-mode))
      )
     ((symbolp buffer-or-mode)
      (setq mode buffer-or-mode)
      (princ (format-message "`%s'\n" buffer-or-mode))
      )
     ((signal 'wrong-type-argument
              (list 'buffer-or-mode buffer-or-mode))))
    (when table
      (princ "\n- Buffer local\n")
      (mode-local-print-bindings table))
    (while mode
      (setq table (get mode 'mode-local-symbol-table))
      (when table
        (princ (format-message "\n- From `%s'\n" mode))
        (mode-local-print-bindings table))
      (setq mode (get-mode-local-parent mode)))))

(defun mode-local-describe-bindings-1 (buffer-or-mode &optional interactive-p)
  "Display mode local bindings active in BUFFER-OR-MODE.
Optional argument INTERACTIVE-P is non-nil if the calling command was
invoked interactively."
  (when (fboundp 'help-setup-xref)
    (help-setup-xref
     (list 'mode-local-describe-bindings-1 buffer-or-mode)
     interactive-p))
  (with-output-to-temp-buffer (help-buffer) ; "*Help*"
    (with-current-buffer standard-output
      (mode-local-describe-bindings-2 buffer-or-mode))))

(defun describe-mode-local-bindings (buffer)
  "Display mode local bindings active in BUFFER."
  (interactive "b")
  (when (setq buffer (get-buffer buffer))
    (mode-local-describe-bindings-1 buffer (called-interactively-p 'any))))

(defun describe-mode-local-bindings-in-mode (mode)
  "Display mode local bindings active in MODE hierarchy."
  (interactive
   (list (completing-read
          "Mode: " obarray
          (lambda (s) (get s 'mode-local-symbol-table))
          t (symbol-name major-mode))))
  (when (setq mode (intern-soft mode))
    (mode-local-describe-bindings-1 mode (called-interactively-p 'any))))

(add-hook 'find-file-hook #'mode-local-post-major-mode-change)
(add-hook 'change-major-mode-hook #'mode-local-on-major-mode-change)

(provide 'mode-local)

;;; mode-local.el ends here

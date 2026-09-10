#!/usr/bin/env -S guile --no-auto-compile
!#
;;; integrate-submodule.scm -- Integrate an app into a super-repository.
;;;
;;; Usage: integrate-submodule.scm <app_repo> <super_repo>
;;;
;;; Compares the origin remote URL of <app_repo> against the submodule
;;; remotes recorded in <super_repo>/.gitmodules.  On a match, the local
;;; <app_repo> is added as a remote ("ci-app") of the submodule and its HEAD
;;; is checked out there, so the submodule's working tree matches the app
;;; commit under test. Prints only the absolute matching submodule path on
;;; stdout on success. Exits 1 on failure, 2 on bad usage.

(use-modules
  (ice-9 popen)
  (ice-9 rdelim)
  (ice-9 regex)
  (ice-9 match)
  (ice-9 format)
  (srfi srfi-1))

;;; URL normalization

(define (strip-suffix str suffix)
  (if (string-suffix? suffix str)
      (substring str 0 (- (string-length str) (string-length suffix)))
      str))

(define (drop-userinfo host)
  (let ((at (string-contains host "@")))
    (if at (substring host (+ at 1)) host)))

(define (normalize-url url)
  "Canonicalize a git remote URL to 'host/path' form with a lowercase host."
  (let* ((s (string-trim-right url))
         (s (strip-suffix s "/"))
         (s (strip-suffix s ".git")))
    (cond
     ((string-match "^ssh://([^@/]*@)?([^:/]+)(:[0-9]+)?/(.*)$" s)
      => (lambda (m)
           (string-append (string-downcase (match:substring m 2))
                          "/" (match:substring m 4))))
     ((string-match "^([A-Za-z0-9._-]+)@([^:]+):(.*)$" s)
      => (lambda (m)
           (string-append (string-downcase (match:substring m 2))
                          "/" (match:substring m 3))))
     ((string-match "^https?://([^/]+)/(.*)$" s)
      => (lambda (m)
           (string-append (string-downcase (drop-userinfo (match:substring m 1)))
                          "/" (match:substring m 2))))
     ((string-match "^git://([^/]+)/(.*)$" s)
      => (lambda (m)
           (string-append (string-downcase (drop-userinfo (match:substring m 1)))
                          "/" (match:substring m 2))))
     (else
      (let ((slash (string-contains s "/")))
        (if slash
            (string-append (string-downcase (substring s 0 slash))
                           "/" (substring s (+ slash 1)))
            (string-downcase s)))))))

;;; .gitmodules parsing

(define (parse-gitmodules file)
  "Parse FILE returning a list of alists:
  (((name . \"x\") (url . \"...\") (path . \"...\")) ...)"
  (define (section-header line)
    (let ((m (string-match
              "^[[:space:]]*\\[submodule[[:space:]]+\"([^\"]+)\"\\][[:space:]]*$"
              line)))
      (and m (match:substring m 1))))
  (define (key-value line)
    (let ((m (string-match
              "^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$"
              line)))
      (and m (cons (string->symbol (match:substring m 1))
                   (string-trim-right (match:substring m 2))))))
  (call-with-input-file file
    (lambda (port)
      (let loop ((entries '()) (current #f))
        (let ((line (read-line port)))
          (cond
           ((eof-object? line)
            (reverse (if current (cons (reverse current) entries) entries)))
           ((section-header line)
            => (lambda (name)
                 (loop (if current (cons (reverse current) entries) entries)
                       (list (cons 'name name)))))
           ((and current (key-value line))
            => (lambda (kv)
                 (loop entries (cons kv current))))
           (else
            (loop entries current))))))))

;;; Git interaction

(define (git-output . args)
  "Run git with ARGS, return trimmed stdout or #f on non-zero exit."
  (let* ((port (apply open-pipe* OPEN_READ "git" args))
         (output (read-delimited "" port))
         (status (close-pipe port)))
    (and (eqv? status 0)
         (string-trim-right output))))

(define (run-git . args)
  "Run git with ARGS, forwarding stdout to stderr. Return #t on success."
  (let ((port (apply open-pipe* OPEN_READ "git" args)))
    (let loop ()
      (let ((line (read-line port)))
        (unless (eof-object? line)
          (display line (current-error-port))
          (newline (current-error-port))
          (loop))))
    (eqv? (close-pipe port) 0)))

(define (git-origin-url repo)
  "Return the origin remote URL of REPO, or #f."
  (git-output "-C" repo "remote" "get-url" "origin"))

(define *remote-name* "ci-app")

(define (remote-list sub-dir)
  "Return the list of remote names configured in SUB-DIR."
  (let ((out (git-output "-C" sub-dir "remote")))
    (if out (string-split out #\newline) '())))

(define (ensure-remote sub-dir app-repo)
  "Add or update the ci-app remote in SUB-DIR to point at APP-REPO."
  (if (member *remote-name* (remote-list sub-dir))
      (run-git "-C" sub-dir "remote" "set-url" *remote-name* app-repo)
      (run-git "-C" sub-dir "remote" "add" *remote-name* app-repo)))

(define (sync-submodule sub-dir app-repo)
  "Point SUB-DIR's ci-app remote at APP-REPO, fetch, and checkout app HEAD.
Returns #t on success, #f on failure (with a message on stderr)."
  (let ((head (git-output "-C" app-repo "rev-parse" "HEAD")))
    (cond
     ((not head)
      (format (current-error-port)
              "error: cannot resolve HEAD of ~a\n" app-repo)
      #f)
     ((not (ensure-remote sub-dir app-repo))
      (format (current-error-port)
              "error: failed to configure remote '~a' in ~a\n"
              *remote-name* sub-dir)
      #f)
     ;; A Gerrit patchset may be a detached HEAD absent from every branch.
     ((not (run-git "-C" sub-dir "fetch" *remote-name* head))
      (format (current-error-port)
              "error: failed to fetch from '~a' in ~a\n"
              *remote-name* sub-dir)
      #f)
     ((not (run-git "-C" sub-dir "checkout" "--detach" head))
      (format (current-error-port)
              "error: failed to checkout ~a in ~a\n" head sub-dir)
      #f)
     (else
      (format (current-error-port)
              "checked out ~a in ~a\n" head sub-dir)
      #t))))

;;; Main

(define (find-submodule-path gitmodules-file app-url)
  (let ((target (normalize-url app-url)))
    (any (lambda (entry)
           (let ((url (assq-ref entry 'url))
                 (path (assq-ref entry 'path)))
             (and url path
                  (string=? (normalize-url url) target)
                  path)))
         (parse-gitmodules gitmodules-file))))

(define (main args)
  (match args
    ((_ app-repo* super-repo*)
     (let ((app-repo (canonicalize-path app-repo*))
           (super-repo (canonicalize-path super-repo*)))
       (let ((gitmodules (string-append super-repo "/.gitmodules")))
       (cond
        ((not (file-exists? gitmodules))
         (format (current-error-port)
                 "error: no .gitmodules found in: ~a\n" super-repo)
         (exit 1))
        (else
         (let ((app-url (git-origin-url app-repo)))
           (cond
            ((not app-url)
             (format (current-error-port)
                     "error: no 'origin' remote in: ~a\n" app-repo)
             (exit 1))
            ((find-submodule-path gitmodules app-url)
             => (lambda (path)
                   (let ((sub-dir (canonicalize-path
                                   (string-append super-repo "/" path))))
                     (unless (string-prefix? (string-append super-repo "/") sub-dir)
                       (format (current-error-port)
                               "error: submodule path escapes Jupiter: ~a\n" path)
                       (exit 1))
                     (or (sync-submodule sub-dir app-repo)
                         (exit 1))
                     (format #t "~a\n" sub-dir))))
             (else
              (format (current-error-port)
                      "error: no submodule in ~a matches remote '~a'\n"
                      super-repo app-url)
              (exit 1)))))))))
    (_
     (format (current-error-port)
             "Usage: ~a <app_repo> <super_repo>\n"
             (basename (car args)))
     (exit 2))))

(main (command-line))

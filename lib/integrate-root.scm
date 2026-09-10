#!/usr/bin/env -S guile --no-auto-compile
!#
;;; integrate-root.scm -- Integrate a root checkout into a Jupiter snapshot.
;;;
;;; Usage: integrate-root.scm <app_repo> <super_repo>
;;;
;;; Fetch the exact HEAD of <app_repo> through a local ci-app remote and
;;; check it out detached in <super_repo>, preserving submodule working trees.
;;; Prints only the absolute snapshot root path on stdout on success.
;;; Exits 1 on failure, 2 on bad usage.

(use-modules
  (ice-9 popen)
  (ice-9 rdelim)
  (ice-9 match)
  (ice-9 format))

(define (git-output . args)
  "Run git with ARGS, return trimmed stdout or #f on non-zero exit."
  (let* ((port (apply open-pipe* OPEN_READ "git" args))
         (output (read-delimited "" port))
         (status (close-pipe port)))
    (and (eqv? status 0)
         (if (eof-object? output) "" (string-trim-right output)))))

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

(define (sync-root super-repo app-repo)
  (let ((head (git-output "-C" app-repo "rev-parse" "HEAD"))
        (remotes (git-output "-C" super-repo "remote")))
    (cond
     ((not head)
      (format (current-error-port)
              "error: cannot resolve HEAD of ~a\n" app-repo)
      #f)
     ((or (not remotes)
          (not (run-git "-C" super-repo "remote"
                        (if (member "ci-app" (string-split remotes #\newline))
                            "set-url" "add")
                        "ci-app" app-repo)))
      (format (current-error-port)
              "error: failed to configure remote 'ci-app' in ~a\n" super-repo)
      #f)
     ;; A Gerrit patchset may be a detached HEAD absent from every branch.
     ((not (run-git "-C" super-repo "fetch" "--no-recurse-submodules" "ci-app" head))
      (format (current-error-port)
              "error: failed to fetch from 'ci-app' in ~a\n" super-repo)
      #f)
     ((not (run-git "-C" super-repo "checkout" "--detach"
                   "--no-recurse-submodules" head))
      (format (current-error-port)
              "error: failed to checkout ~a in ~a\n" head super-repo)
      #f)
     (else
      (format (current-error-port)
              "checked out ~a in ~a\n" head super-repo)
      #t))))

(define (main args)
  (match args
    ((_ app-repo* super-repo*)
     (let ((app-repo (canonicalize-path app-repo*))
           (super-repo (canonicalize-path super-repo*)))
       (or (sync-root super-repo app-repo)
           (exit 1))
       (format #t "~a\n" super-repo)))
    (_
     (format (current-error-port)
             "Usage: ~a <app_repo> <super_repo>\n"
             (basename (car args)))
     (exit 2))))

(main (command-line))

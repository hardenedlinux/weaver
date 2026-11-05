;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Explicit operator-owned Cedar assets; no Scheme or alternate DSL evaluation.
(import (only-in :clan/poo/object .ref .o)
        (only-in :clan/poo/mop validate)
        (only-in :std/crypto/digest sha256)
        (only-in :std/encoding/hex hex-encode)
        (only-in :std/string/path path-absolute?)
        "./types.ss")
(export policy-document read-policy-assets)

(def (policy-document identity-value source-value path-value)
  (validate PolicyDocument
    (.o identity: identity-value source: source-value path: path-value
        digest: (hex-encode (sha256 (string->utf8 source-value))))))

(def (read-policy-assets profile root)
  (def assets (.ref profile 'source-assets))
  (unless (<= (length assets) 64) (error "Governance asset inventory bound"))
  (unless (or (null? assets)
              (and (path-absolute? root) (eq? (file-info-type (file-info root #f)) 'directory)))
    (error "Governance assets require an explicit directory root"))
  (map
    (lambda (asset)
      (unless (eq? (.ref asset 'language) 'cedar)
        (error "unsupported Governance asset language"))
      (def parts (string-split (.ref asset 'path) #\/))
      (unless (and (pair? parts)
                   (andmap (lambda (part) (not (member part '("" "." "..")))) parts)
                   (andmap (lambda (part)
                             (andmap (lambda (character)
                                       (or (char<=? #\a character #\z)
                                           (char<=? #\A character #\Z)
                                           (char<=? #\0 character #\9)
                                           (memv character '(#\. #\_ #\-))))
                                     (string->list part))) parts)
                   (<= (string-length (.ref asset 'path)) 4096)
                   (not (path-absolute? (.ref asset 'path))))
        (error "Governance asset path must stay inside its root"))
      (def path
        (let loop ((base root) (rest parts))
          (let* ((next (path-expand (car rest) (string-append base "/")))
                 (kind (file-info-type (file-info next #f))))
            (if (null? (cdr rest))
              (if (eq? kind 'regular) next (error "Governance asset must be a regular file"))
              (if (eq? kind 'directory) (loop next (cdr rest))
                (error "Governance asset directory must not be a symlink"))))))
      (def source-value
        (call-with-input-file path
          (lambda (port)
            (let* ((buffer (make-u8vector 65537))
                   (count (read-subu8vector buffer 0 65537 port)))
              (unless (and (exact-integer? count) (<= 1 count 65536))
                (error "Governance asset byte bound"))
              (utf8->string (subu8vector buffer 0 count))))))
      (policy-document (.ref asset 'identity) source-value (.ref asset 'path)))
    assets))

;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in "./roots.ss" weaver-rooted-call)
        (only-in :tao3k/yuanxu/prelude yuanxu-build-autoloads)
        (for-syntax (only-in "./build.ss" Build)))
(yuanxu-build-autoloads Build operations)
(extern capture-cancelled)
(def (install-cancel! callback)
  (install-capture-cancel!
    (and callback (lambda () (not (zero? (capture-cancelled callback)))))))
(begin-foreign
  (namespace ("hardenedlinux/weaver/scheme/c-abi/gateway#" capture-cancelled))
  (define capture-cancelled
    (c-lambda ((pointer void)) int "___return((*(int (**)(void))___arg1)());"))
  (c-define (install-cancel callback) ((pointer void)) void "weaver_install_source_cancel_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/gateway#install-cancel! callback)))

(begin-foreign
  (c-define (derive-root root) (int64) int64 "weaver_governor_ready_steps_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#derive-request)))

(begin-foreign
  (c-define (fact-impact-root root) (int64) int64 "weaver_hard_fact_impact_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#fact-impact-request)))

(begin-foreign
  (c-define (compose-root root) (int64) int64 "weaver_compose_source_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#compose-request)))

(begin-foreign
  (c-define (session-turn-root root) (int64) int64 "weaver_session_turn_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#session-turn-request)))

(begin-foreign
  (c-define (capture-root root) (int64) int64 "weaver_capture_source_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#capture-request)))

(begin-foreign
  (c-define (ready-root root) (int64) int64 "weaver_governance_ready_v1" "extern"
    (hardenedlinux/weaver/scheme/c-abi/roots#weaver-rooted-call root
      hardenedlinux/weaver/scheme/c-abi/gateway#ready)))

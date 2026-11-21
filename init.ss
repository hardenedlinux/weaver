;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Yuanxu owns discovery, selection, admission and generation currentness.
(import :tao3k/yuanxu/module-system/selection/init-syntax)
(yuanxu!
  :load-modules (from: :tao3k/agentic-ai-lab/init ModulesSource) mode: explicit mount: Lab
  (governance)
  :load-modules "./scheme" mode: explicit mount: Weaver
  (c-abi)
  (governance)
  (policy)
  (gateway))

;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Yuanxu owns discovery, selection, admission and generation currentness.
(import :yuanxu/module-system/selection/init-syntax)
(yuanxu!
  :load-modules "modules" package: "github.com/tao3k/agentic-ai-lab" mode: explicit rename: Lab
  (governance)
  :load-modules "./scheme" mode: explicit rename: Weaver
  (governance)
  (policy)
  (gateway))

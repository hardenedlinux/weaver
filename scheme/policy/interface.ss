;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in "./types.ss" PolicyScopeContract)
        (only-in "./objects.ss" Policy.))
(export Policy)
(.def Policy
  identity: 'policy
  tags: '(policy)
  core: (.o scope-contract: PolicyScopeContract exports: Policy.)
  features: (.o))

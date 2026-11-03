;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; Semantic scope: no transport, ledger, scheduling or execution capability.
(import (only-in :clan/poo/object .o)
        (only-in :agentic-ai-lab/modules/governance/objects agentic-ai-lab-governance-threat-blocking?)
        "./func.ss")
(export Governance.)
(def Governance.
  (.o assess: (lambda (profile context)
                (assess-governance! profile context agentic-ai-lab-governance-threat-blocking?))))

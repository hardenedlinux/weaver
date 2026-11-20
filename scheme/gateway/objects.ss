;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Semantic objects use ordinary package-owned imports, not linker injection.
(import (only-in :clan/poo/object .o) "./func.ss"
        (only-in "./derivation.ss" derive-gateway-source make-gateway-derivation)
        (only-in "./capture.ss" capture-gateway-source))
(export Gateway.)
(def Gateway. (.o emit: emit-gateway capture: capture-gateway-source
                 derive: derive-gateway-source open-derivation: make-gateway-derivation))

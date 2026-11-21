;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/type Exactly Record))
(export CAbiScopeContract)
(def CAbiScopeContract
  (.cc (Record identity: [(Exactly 'weaver/c-abi)]) identity: 'weaver/c-abi))

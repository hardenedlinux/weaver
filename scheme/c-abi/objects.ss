;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in :clan/poo/object .o))
(export CAbiMetadata)
(def CAbiMetadata (.o identity: 'weaver/c-abi))

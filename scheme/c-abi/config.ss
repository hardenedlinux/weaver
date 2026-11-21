;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in :clan/poo/type validate) "./types.ss" "./objects.ss")
(export CAbiScope)
(def CAbiScope (validate CAbiScopeContract CAbiMetadata))

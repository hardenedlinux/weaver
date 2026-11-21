;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in :clan/poo/object .def .o)
        (only-in "./config.ss" CAbiScope)
        (only-in "./types.ss" CAbiScopeContract))
(export CAbi)
(.def CAbi
  identity: 'c-abi
  core: (.o scope-contract: CAbiScopeContract exports: CAbiScope))

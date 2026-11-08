#!/usr/bin/env gxi
;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (rename-in (only-in "./dev/prepare-scheme.ss" main) (main prepare-package!)))
(def (main . args) (apply prepare-package! args))

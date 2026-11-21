;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in "./types.ss" GatewayScopeContract)
        (only-in "./config.ss" GatewayScope))
(export Gateway)
(.def Gateway
  identity: 'gateway
  tags: '(gateway)
  core:
  (.o scope-contract: GatewayScopeContract
      exports: GatewayScope)
  features: (.o))

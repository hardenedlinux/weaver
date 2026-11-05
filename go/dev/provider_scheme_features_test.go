// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

// The explicit qualification graph tests production ABI/lifecycle code without
// pretending that the fixture Governor/Profile is a production application.
const providerRuntimeFeatures = "arrow,governance-qualification"

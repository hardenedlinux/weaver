// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

permit(
    principal == Weaver::Principal::"alice",
    action == Weaver::Action::"invoke",
    resource == Weaver::Target::"primary"
) when { context.family == "demo-family" && context.profile == "demo-profile" };

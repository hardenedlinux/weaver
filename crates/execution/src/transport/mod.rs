// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Private native transport owners; no unguarded send API leaves execution.
pub(crate) mod https;
pub(crate) mod stream_sink;
pub(crate) mod stream_socket;

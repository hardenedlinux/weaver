// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::persistence::Session;

#[test]
fn descriptor_copy_is_not_a_retained_execution_owner() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("custody.db");
    let session = Session::open(&path).expect("original");
    // A Command fork can transiently inherit the open file description before
    // CLOEXEC. Reproduce that kernel lifetime without a timing-dependent fork.
    let descriptor = session
        .owner
        ._custody
        .0
        .try_clone()
        .expect("descriptor copy");
    session.close().expect("all logical roles retired");
    Session::open(&path)
        .expect("retired logical lease released despite descriptor copy")
        .close()
        .expect("successor");
    drop(descriptor);
}

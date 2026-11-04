// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

#[test]
fn compiled_storage_caps_slots_and_exact_hits_do_not_allocate_new_entries() {
    super::COMPILED.with(|cache| cache.borrow_mut().clear());
    for number in 0..20 {
        let source =
            format!("permit(principal,action,resource) when {{ context.revision == {number} }};");
        super::with_policy(&source, |_| ()).expect("compile");
    }
    super::COMPILED.with(|cache| {
        let cache = cache.borrow();
        assert_eq!(cache.len(), 8);
        assert!(cache[0].0.contains("12"));
    });
    super::with_policy(
        "permit(principal,action,resource) when { context.revision == 19 };",
        |_| (),
    )
    .expect("exact hit");
    super::COMPILED.with(|cache| assert_eq!(cache.borrow().len(), 8));
}

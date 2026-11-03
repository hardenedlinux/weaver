// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use weaver_ledger::persistence::Session;

#[test]
fn semantic_floor_uses_two_composite_range_seeks() {
    let directory = tempfile::tempdir().expect("query-plan store");
    let connection = Session::open(directory.path().join("plan.db")).expect("query planner");
    weaver_ledger::persistence::script(&connection, crate::schema::SCHEMA).expect("schema");
    let operations = weaver_ledger::persistence::read_all(
        &connection,
        &format!("EXPLAIN QUERY PLAN {}", super::PROFILE_FLOOR_QUERY),
        ["p", "{}"],
        |r| r.get::<String>(3),
    )
    .expect("plan rows");
    assert_eq!(
        operations
            .iter()
            .filter(|text| text.contains("SEARCH tasks") && text.contains("task_profile_semantics"))
            .count(),
        2,
        "{operations:?}"
    );
    assert!(
        !operations.iter().any(|text| text.contains("SCAN tasks")),
        "{operations:?}"
    );
    assert!(
        operations
            .iter()
            .filter(|text| text.contains("SEARCH tasks") && text.contains("task_profile_semantics"))
            .all(|text| text.matches('?').count() >= 2),
        "both semantic index columns must constrain each range: {operations:?}"
    );
}

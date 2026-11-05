// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

#[test]
fn range_tail_lookup_uses_message_primary_key_without_sorting_history() {
    let directory = tempfile::tempdir().expect("database directory");
    let ledger = crate::Ledger::open(directory.path().join("query-plan.db")).expect("ledger");
    let sql = format!("EXPLAIN QUERY PLAN {}", super::TAIL_QUERY);
    let steps = crate::persistence::read_all(
        &ledger.connection,
        &sql,
        ["family", "node", "message"],
        |r| r.get::<String>(3),
    )
    .expect("plan steps");
    let mut indexed = false;
    for step in steps {
        let detail = step;
        assert!(
            !detail.contains("SCAN") && !detail.contains("TEMP B-TREE"),
            "unbounded history work: {detail}"
        );
        indexed |= detail.contains("SEARCH stream_ranges USING INDEX");
    }
    assert!(indexed, "tail lookup lost its composite primary-key search");
}

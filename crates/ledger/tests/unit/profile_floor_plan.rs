use rusqlite::{Connection, params};

#[test]
fn semantic_floor_uses_two_composite_range_seeks() {
    let connection = Connection::open_in_memory().expect("query planner");
    connection
        .execute_batch(crate::schema::SCHEMA)
        .expect("schema");
    let mut query = connection
        .prepare(&format!(
            "EXPLAIN QUERY PLAN {}",
            super::PROFILE_FLOOR_QUERY
        ))
        .expect("plan");
    let operations = query
        .query_map(params!["p", "{}"], |row| row.get::<_, String>(3))
        .expect("operations")
        .collect::<rusqlite::Result<Vec<_>>>()
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

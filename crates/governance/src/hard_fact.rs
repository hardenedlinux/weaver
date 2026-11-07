// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Closed impact rules over a deployment-admitted original task.
use ascent::ascent;
use weaver_contracts::{Error, FactWork, Result};

ascent! {
    struct FactImpact;
    relation depends(String, String);
    relation changed(String);
    relation affected(String);
    affected(node) <-- changed(node);
    affected(dependent) <-- depends(dependent, node), affected(node);
}

/// Native evaluation is bounded by the admitted finite input graph. No source
/// mutation, authority observation or permission grant occurs in this function.
pub fn derive_fact_impact(work: &FactWork) -> Result<Vec<String>> {
    if work.dependencies.len() > 64 {
        return Err(Error::Invalid("fact impact graph bound"));
    }
    let mut program = FactImpact {
        depends: work.dependencies.clone(),
        changed: vec![(work.root.clone(),)],
        ..Default::default()
    };
    program.run();
    let mut affected: Vec<_> = program.affected.into_iter().map(|(node,)| node).collect();
    affected.sort_unstable();
    Ok(affected)
}

#[cfg(test)]
#[test]
fn hard_fact_impact_is_transitive_and_handles_cycles() {
    let work = FactWork {
        barrier: weaver_contracts::FactBarrier {
            operation_id: "test".into(),
            source_epoch: 0,
            revision: 1,
            snapshot: String::new(),
            floor: 1,
            pending_prefix: String::new(),
        },
        expected_floor: 1,
        pending_prefix: String::new(),
        root: "root".into(),
        dependencies: vec![
            ("direct".into(), "root".into()),
            ("transitive".into(), "direct".into()),
            ("root".into(), "transitive".into()),
            ("unrelated".into(), "other".into()),
        ],
        available: false,
    };
    assert_eq!(
        derive_fact_impact(&work).expect("fixed point"),
        ["direct", "root", "transitive"]
    );
}

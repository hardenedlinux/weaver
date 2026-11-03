//! Finite optimized same-image ABBA experiment, admitted by Go.
use super::mvcc;
use weaver_ledger::persistence::Journal;
#[derive(serde::Serialize)]
struct Sample<'a> {
    profile: &'a str,
    optimized: bool,
    block: usize,
    slot: usize,
    contended: bool,
    observation: mvcc::ContentionObservation,
}
pub fn run() {
    for (profile, journal, shared, publication) in [
        ("wal-writer", Journal::Wal, 0, false),
        ("mvcc-disjoint", Journal::Mvcc, 0, false),
        ("mvcc-shared-budget", Journal::Mvcc, 1, false),
        ("mvcc-shared-history", Journal::Mvcc, 2, false),
        ("mvcc-publication", Journal::Mvcc, 0, true),
    ] {
        for block in 0..6 {
            for (slot, contended) in [false, true, true, false].into_iter().enumerate() {
                let observation = mvcc::fresh_domains(journal, shared)
                    .prepare()
                    .measure(contended, publication);
                println!(
                    "weaver-contention {}",
                    serde_json::to_string(&Sample {
                        profile,
                        optimized: !cfg!(debug_assertions),
                        block,
                        slot,
                        contended,
                        observation
                    })
                    .expect("finite typed observation")
                );
            }
        }
    }
}

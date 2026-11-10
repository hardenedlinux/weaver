// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Existing SDK qualification ABI, called only on the live Scheme owner.
unsafe extern "C" {
    fn gerbil_scheme_rust_objects_usage(gc: *mut f64, os: *mut u64) -> i32;
}

pub(super) struct Snapshot {
    gc: [f64; 4],
    os: [u64; 4],
}

#[derive(serde::Serialize)]
pub(super) struct Delta {
    gc_count: f64,
    gc_cpu_seconds: f64,
    gc_wall_seconds: f64,
    scheme_heap_capacity_bytes: f64,
    process_cpu_ns: u64,
    process_rss_high_water_bytes: u64,
    process_voluntary_switches: u64,
    process_involuntary_switches: u64,
}

pub(super) fn read() -> Snapshot {
    let mut snapshot = Snapshot {
        gc: [0.0; 4],
        os: [0; 4],
    };
    // SAFETY: the benchmark invokes this on the initialized VM's affine owner,
    // before cleanup. The pinned public SDK header specifies four doubles and
    // four u64 outputs. Both arrays are complete, writable and disjoint; the
    // SDK retains no pointer. This is the SDK's own objects-benchmark ABI.
    let status = unsafe {
        gerbil_scheme_rust_objects_usage(snapshot.gc.as_mut_ptr(), snapshot.os.as_mut_ptr())
    };
    assert_eq!(status, 0, "SDK owner usage snapshot");
    assert!(
        snapshot
            .gc
            .iter()
            .all(|value| value.is_finite() && *value >= 0.0)
    );
    snapshot
}

impl Snapshot {
    pub(super) fn delta(self, before: Self) -> Delta {
        assert!((0..3).all(|i| self.gc[i] >= before.gc[i]));
        Delta {
            gc_count: self.gc[0] - before.gc[0],
            gc_cpu_seconds: self.gc[1] - before.gc[1],
            gc_wall_seconds: self.gc[2] - before.gc[2],
            scheme_heap_capacity_bytes: self.gc[3],
            process_cpu_ns: self.os[0].checked_sub(before.os[0]).expect("monotonic CPU"),
            process_rss_high_water_bytes: self.os[1],
            process_voluntary_switches: self.os[2]
                .checked_sub(before.os[2])
                .expect("monotonic switches"),
            process_involuntary_switches: self.os[3]
                .checked_sub(before.os[3])
                .expect("monotonic switches"),
        }
    }
}

// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use weaver_contracts::{Proposal, decode};

#[test]
fn duplicate_keys_unknown_fields_and_streams_are_rejected() {
    assert!(decode::<serde_json::Value>(br#"{"a":{"x":1,"x":2}}"#).is_err());
    assert!(decode::<Proposal>(br#"{"family":"f","scope":"forged"}"#).is_err());
    let value = serde_json::json!({"family":"f","node":"n","profile":"p","target":"t","endpoint":"https://example.invalid/","model":"m","body":"{\"model\":\"m\",\"stream\":true}","ceiling":1,"revision":0,"fence":0});
    let p: Proposal = decode(&serde_json::to_vec(&value).expect("serialize")).expect("decode");
    assert!(p.validate().is_err());
}

// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::SseFraming;
use tokio_sse_codec::Frame;

#[test]
fn sse_events_are_invariant_under_chunk_boundaries() -> Result<(), crate::Error> {
    let wire = b": heartbeat\r\nevent: delta\r\ndata: first\r\ndata:second\r\n\r\ndata: last\r\r\n";
    let expected = [b"first\nsecond".as_slice(), b"last".as_slice()];
    for first in 0..=wire.len() {
        for second in first..=wire.len() {
            let mut frame = SseFraming::new(wire.len());
            let mut actual = Vec::new();
            for slice in [&wire[..first], &wire[first..second], &wire[second..]] {
                frame.push(slice);
                while let Some(frame) = frame.next()? {
                    if let Frame::Event(event) = frame {
                        actual.push(event.data.to_vec());
                    }
                }
            }
            assert_eq!(actual, expected, "splits {first} and {second}");
        }
    }
    Ok(())
}

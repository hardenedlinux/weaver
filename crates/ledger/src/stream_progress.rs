//! Join mutable message progress to its indexed durable range tail before use.
use crate::{
    store::{db, integer},
    stream_state,
};
use weaver_contracts::{Error, Result};

const TAIL_QUERY: &str = "SELECT sequence,offset,length,written,state FROM stream_ranges WHERE family=?1 AND node=?2 AND message=?3 ORDER BY sequence DESC LIMIT 1";

struct Tail {
    sequence: u64,
    offset: u64,
    length: u64,
    written: Option<i64>,
    state: String,
}

pub(crate) fn message(
    connection: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
    message: &str,
    row: &stream_state::MessageRecord,
) -> Result<()> {
    let tail = crate::persistence::maybe(
        connection,
        TAIL_QUERY,
        crate::persistence::params![(family).to_owned(), (node).to_owned(), (message).to_owned()],
        |r| {
            Ok(Tail {
                sequence: integer(r, 0)?,
                offset: integer(r, 1)?,
                length: integer(r, 2)?,
                written: r.get(3)?,
                state: r.get(4)?,
            })
        },
    )
    .map_err(db)?;
    let Some(tail) = tail else {
        return if row.next_sequence == 0 && row.cursor == 0 && row.state == "queued" {
            Ok(())
        } else {
            Err(Error::Conflict("message range progress changed"))
        };
    };
    let end = tail
        .offset
        .checked_add(tail.length)
        .filter(|end| tail.length > 0 && *end <= row.proposal.payload_length)
        .ok_or(Error::Conflict("message range progress changed"))?;
    if tail.sequence.checked_add(1) != Some(row.next_sequence) {
        return Err(Error::Conflict("message range progress changed"));
    }
    let exact = match tail.state.as_str() {
        "complete" => {
            tail.written == i64::try_from(tail.length).ok()
                && row.cursor == end
                && row.state
                    == if end == row.proposal.payload_length {
                        "complete"
                    } else {
                        "active"
                    }
        }
        "not_sent" => {
            tail.written == Some(0)
                && row.cursor == tail.offset
                && row.state == if tail.offset == 0 { "queued" } else { "active" }
        }
        "partial" => {
            tail.written
                .is_some_and(|n| n >= 0 && (n as u64) < tail.length)
                && row.cursor == tail.offset
                && row.state == "unknown"
        }
        "unknown" => tail.written.is_none() && row.cursor == tail.offset && row.state == "unknown",
        _ => false,
    };
    if !exact {
        return Err(Error::Conflict("message range progress changed"));
    }
    Ok(())
}

// Custody/connection checks cover the bounded manifest, including siblings that
// a stale projection incorrectly labels complete. Each tail lookup uses the PK.
pub(crate) fn stream(
    connection: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
) -> Result<()> {
    let rows = crate::persistence::read_all(
        connection,
        "SELECT message FROM stream_messages WHERE family=?1 AND node=?2",
        [family, node],
        |r| r.get::<String>(0),
    )
    .map_err(db)?;
    for message in rows {
        stream_state::record(connection, family, node, &message)?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "../tests/unit/range_progress_plan.rs"]
mod tests;

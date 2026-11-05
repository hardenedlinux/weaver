// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Opportunistic storage coalescing with one guarded queue insertion per frame.
use super::runtime::{ProviderOutput, StreamDecoder};
use std::io::Read;
use weaver_contracts::{Error, ProviderEvent, ProviderEventKind, Result, body_digest};
use weaver_ledger::{
    Ledger, MAX_PROVIDER_PREPARATION_RANGES, MAX_PROVIDER_PREPARATION_ROWS, ProviderDispatch,
    ProviderRelease,
};

pub(super) fn relay<O: ProviderOutput, R: Read>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    output: &mut O,
    reader: &mut StreamDecoder<R>,
    format: &str,
    rows: usize,
) -> Result<()> {
    let mut pending = Vec::with_capacity(rows);
    let width = preparation_width(output, rows);
    loop {
        if output.stopped() {
            return Err(Error::Conflict("provider response cancelled"));
        }
        let mut terminal = push_event(&mut pending, reader.next()?);
        if !terminal && pending.len() != rows {
            continue;
        }
        let mut ready = Vec::with_capacity(width);
        ready.push(std::mem::replace(&mut pending, Vec::with_capacity(rows)));
        let buffered =
            collect_buffered(reader, &mut pending, &mut ready, rows, width, &mut terminal);
        release_ranges(ledger, permit, output, format, &mut ready)?;
        buffered?;
        if terminal {
            return Ok(());
        }
    }
}

fn preparation_width<O: ProviderOutput>(_output: &O, rows: usize) -> usize {
    #[cfg(feature = "test-loopback")]
    if _output.prepare_ranges_separately() {
        return 1;
    }
    MAX_PROVIDER_PREPARATION_RANGES.min(MAX_PROVIDER_PREPARATION_ROWS / rows)
}

fn push_event(range: &mut Vec<ProviderEvent>, event: ProviderEvent) -> bool {
    let terminal = event.kind == ProviderEventKind::Done;
    range.push(event);
    terminal
}

fn collect_buffered<R: Read>(
    reader: &mut StreamDecoder<R>,
    pending: &mut Vec<ProviderEvent>,
    ready: &mut Vec<Vec<ProviderEvent>>,
    rows: usize,
    width: usize,
    terminal: &mut bool,
) -> Result<()> {
    while !*terminal && ready.len() < width {
        let Some(event) = reader.next_buffered()? else {
            break;
        };
        *terminal = push_event(pending, event);
        if *terminal || pending.len() == rows {
            ready.push(std::mem::replace(pending, Vec::with_capacity(rows)));
        }
    }
    Ok(())
}

fn release_ranges<O: ProviderOutput>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    output: &mut O,
    format: &str,
    ready: &mut [Vec<ProviderEvent>],
) -> Result<()> {
    let mut first_slot = Some(output.reserve_for_delivery(ledger, permit, format)?);
    let digests = ready
        .iter()
        .map(|rows| Ok(body_digest(&serde_json::to_string(rows)?)))
        .collect::<Result<Vec<_>>>()?;
    let specs: Vec<_> = ready
        .iter()
        .zip(&digests)
        .map(|(rows, digest)| (digest.as_str(), rows.len() as u64))
        .collect();
    match ledger.prepare_provider_releases(permit, &specs, format) {
        Ok(releases) if snapshot_enabled(output) => {
            let slot = first_slot
                .take()
                .ok_or(Error::Conflict("snapshot credit missing"))?;
            queue_snapshot(ledger, permit, output, format, ready, releases, slot)?;
        }
        Ok(releases) => {
            for (rows, release) in ready.iter_mut().zip(releases) {
                let slot = take_slot(ledger, permit, format, output, &mut first_slot)?;
                queue_range(ledger, permit, output, format, rows, release, slot)?;
            }
        }
        // A definitive Cedar rejection staged no rows. Preserve the old
        // authorized prefix by making new single-range decisions in order.
        Err(Error::Denied) if ready.len() > 1 => {
            for (rows, (digest, length)) in ready.iter_mut().zip(specs) {
                let slot = take_slot(ledger, permit, format, output, &mut first_slot)?;
                let release = ledger.prepare_provider_release(permit, digest, format, length)?;
                queue_range(ledger, permit, output, format, rows, release, slot)?;
            }
        }
        Err(error) => return Err(error),
    }
    Ok(())
}

fn snapshot_enabled<O: ProviderOutput>(_output: &O) -> bool {
    #[cfg(feature = "test-loopback")]
    if _output.release_ranges_separately() {
        return false;
    }
    true
}

fn queue_snapshot<O: ProviderOutput>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    output: &mut O,
    format: &str,
    ready: &mut [Vec<ProviderEvent>],
    releases: Vec<ProviderRelease>,
    slot: O::Slot,
) -> Result<()> {
    let first = releases
        .first()
        .ok_or(Error::Conflict("empty response snapshot"))?
        .first_sequence();
    let first_frame = prepare_range::<O>(permit, &mut ready[0], format, first)?;
    let (_, remaining) = ledger.release_provider_group_for_delivery(
        permit,
        releases,
        format,
        |actual, receipt| {
            if actual != first || output.stopped() {
                return Err(Error::Conflict("snapshot cancelled or rebound"));
            }
            output.emit(slot, first_frame, receipt)
        },
    )?;
    output.finish_delivery(ledger, permit, format)?;
    for (events, receipt) in ready.iter_mut().skip(1).zip(remaining) {
        let slot = output.reserve_for_delivery(ledger, permit, format)?;
        if output.stopped() {
            return Err(Error::Conflict("provider snapshot cancelled"));
        }
        let frame = prepare_range::<O>(permit, events, format, receipt.interval().first)?;
        output.emit(slot, frame, receipt)?;
        output.finish_delivery(ledger, permit, format)?;
    }
    Ok(())
}

fn prepare_range<O: ProviderOutput>(
    permit: &ProviderDispatch,
    events: &mut [ProviderEvent],
    format: &str,
    first: u64,
) -> Result<O::PreparedFrame> {
    for (offset, event) in events.iter_mut().enumerate() {
        event.sequence = first + offset as u64;
    }
    O::prepare(permit.route(), &permit.plan().model, events, format)
}

fn take_slot<O: ProviderOutput>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    format: &str,
    output: &mut O,
    first: &mut Option<O::Slot>,
) -> Result<O::Slot> {
    match first.take() {
        Some(slot) => Ok(slot),
        None => output.reserve_for_delivery(ledger, permit, format),
    }
}

fn queue_range<O: ProviderOutput>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    output: &mut O,
    format: &str,
    events: &mut [ProviderEvent],
    release: ProviderRelease,
    slot: O::Slot,
) -> Result<()> {
    if output.stopped() {
        return Err(Error::Conflict("provider release cancelled"));
    }
    let first = release.first_sequence();
    for (offset, event) in events.iter_mut().enumerate() {
        event.sequence = first + offset as u64;
    }
    let frame = O::prepare(permit.route(), &permit.plan().model, events, format)?;
    ledger.release_provider_for_delivery(permit, release, format, |actual, receipt| {
        if actual != first || output.stopped() {
            return Err(Error::Conflict("provider release cancelled or rebound"));
        }
        output.emit(slot, frame, receipt)
    })?;
    output.finish_delivery(ledger, permit, format)
}

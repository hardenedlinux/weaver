// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module ProviderDeliveryJoin {
  type State = {
    version: int, pending: Set[int], used: Set[int], external: Set[int], orphan: Set[int],
    failed: bool, denied: bool, clockValid: bool, owner: int, frameOwner: int, frameVersion: int,
    staged: bool, committed: bool, acknowledged: bool, consumed: bool, cursor: int, start: int,
    calls: int, held: int
  }
  var s: State
  action init = s' = {version: 0, pending: Set(), used: Set(), external: Set(), orphan: Set(),
    failed: false, denied: false, clockValid: true, owner: 1, frameOwner: 1, frameVersion: 0,
    staged: false, committed: false, acknowledged: false, consumed: false, cursor: 0, start: 0, calls: 0, held: 3}
  action close(id: int): bool = all {
    not(s.used.contains(id)),
    s' = {...s, pending: s.pending.union(Set(id)), used: s.used.union(Set(id))}
  }
  action witness(id: int): bool = all {
    s.pending.contains(id), s' = {...s, external: s.external.union(Set(id))}
  }
  action commit(id: int): bool = all {
    s.pending.contains(id), not(s.external.contains(id)),
    s' = {...s, version: s.version + 1, pending: s.pending.exclude(Set(id))}
  }
  action witnessCommit(id: int): bool = all {
    s.pending.contains(id), s.external.contains(id),
    s' = {...s, version: s.version + 1, pending: s.pending.exclude(Set(id)),
      external: s.external.exclude(Set(id)), orphan: Set()}
  }
  action rollback(id: int): bool = all {
    s.pending.contains(id),
    s' = {...s, pending: s.pending.exclude(Set(id)),
      orphan: if(s.external.contains(id)) s.orphan.union(Set(id)) else s.orphan}
  }
  action nativeUnknown(id: int): bool = all {
    s.pending.contains(id),
    s' = {...s, pending: s.pending.exclude(Set(id)), failed: true}
  }
  action stage = all {
    not(s.staged), not(s.consumed),
    s' = {...s, staged: true, committed: false, acknowledged: false, frameVersion: s.version, frameOwner: s.owner}
  }
  action releaseCommit = all {
    s.staged, not(s.committed), not(s.failed), not(s.denied), s.clockValid,
    s.pending.size() == 0, s.orphan.size() == 0,
    s' = {...s, committed: true, frameVersion: s.version}
  }
  action acknowledge = all {
    s.staged, s.committed, not(s.acknowledged), not(s.consumed),
    s' = {...s, acknowledged: true}
  }
  action qualify = all {
    s.staged, s.acknowledged, not(s.consumed), not(s.failed), not(s.denied), s.clockValid,
    s.pending.size() == 0, s.orphan.size() == 0, s.frameOwner == s.owner,
    s' = {...s, frameVersion: s.version}
  }
  action accept = all {
    s.staged, s.acknowledged, not(s.consumed), not(s.failed), not(s.denied), s.clockValid, s.frameOwner == s.owner,
    s.pending.size() == 0, s.orphan.size() == 0, s.frameVersion == s.version,
    s.start == s.cursor,
    s' = {...s, consumed: true, cursor: s.cursor + 1, calls: s.calls + 1}
  }
  // An old window never acquires the next database owner's custody.
  action restart = s' = {...s, owner: s.owner + 1, failed: false,
    pending: Set(), orphan: Set(), version: s.version + 1}
  action revoke = s' = {...s, version: s.version + 1, denied: true}
  action expire = s' = {...s, clockValid: false}
  action step = {
    nondet id = Set(1,2,3).oneOf()
    any {close(id), witness(id), commit(id), witnessCommit(id), rollback(id), nativeUnknown(id),
      stage, releaseCommit, acknowledge, qualify, accept, restart, revoke, expire}
  }
  val safe = s.calls <= 1 and s.held == 3 and (s.consumed implies s.cursor == 1)
  action ready = init.then(stage).then(releaseCommit).then(acknowledge)
  run knownEmptyRollbackKeepsCurrentCertificateTest = ready.then(close(1)).then(rollback(1)).then(accept).expect(safe)
  run revokedViewCannotBeRequalifiedTest = ready.then(revoke).then(qualify.fail())
  run expiryNeedsNoDatabaseMutationTest = ready.then(expire).then(accept.fail())
  run acknowledgmentCannotResetConsumedCursorTest = ready.then(accept).then(acknowledge.fail())
  run rollbackCannotManufactureCommitAcknowledgmentTest = init.then(stage).then(acknowledge.fail())
  run queueBeforeCommitCannotAcceptTest = init.then(close(1)).then(stage).then(accept.fail())
  run committedWithoutAcknowledgmentCannotAcceptTest = init.then(close(1)).then(stage)
    .then(commit(1)).then(releaseCommit).then(accept.fail())
  run lostReplyCannotActivateInertFrameTest = init.then(close(1)).then(stage).then(commit(1))
    .then(releaseCommit).expect(s.held == 3).then(accept.fail())
  run currentProofAcceptsOnceTest = ready.then(accept).expect(safe).then(accept.fail())
  run pendingMutationBlocksFinalReceiverTest = ready.then(close(1)).then(accept.fail())
  run committedMutationRequiresExactRequalificationTest = ready.then(close(1)).then(commit(1))
    .then(accept.fail())
  run staleFrameRequalifiesWithoutAnotherRangeConsumptionTest = ready.then(close(1)).then(commit(1))
    .then(qualify).then(accept).expect(safe and s.calls == 1 and s.held == 3)
  run nativeUnknownSealsAllOldProofsTest = ready.then(close(1)).then(nativeUnknown(1))
    .then(qualify.fail())
  run rollbackCannotEraseIndependentWitnessTest = ready.then(close(1)).then(witness(1)).then(rollback(1))
    .then(accept.fail())
  run recoveredWitnessMustCommitItsProjectionTest = ready.then(close(1)).then(witness(1)).then(rollback(1))
    .then(close(2)).then(witness(2)).then(accept.fail())
  run committedWitnessRecoveryRestoresQualificationTest = ready.then(close(1)).then(witness(1)).then(rollback(1))
    .then(close(2)).then(witness(2)).then(witnessCommit(2)).then(qualify).then(accept).expect(safe)
  run oldOwnerCannotRequalifyAfterRestartTest = ready.then(restart).then(qualify.fail())
  run concurrentWriterReceiptCannotClearAnotherPendingTest = ready.then(close(1)).then(close(2))
    .then(commit(1)).then(accept.fail())
}

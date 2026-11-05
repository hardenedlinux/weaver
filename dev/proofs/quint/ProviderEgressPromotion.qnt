// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// One conservative conflict component. Distinct operations close it concurrently.
// The witness is an independent durable store. Only the receiver offers bytes.
module ProviderEgressPromotion {
  pure val kinds = Set(1, 2, 3, 4, 5, 6, 7, 8)
  pure val operations = Set(1, 2, 3, 4, 5, 6, 7, 8)
  pure val rows = Set(0, 1, 2)
  type Image = (int, int, int)
  var serial: int
  var db: int
  var witness: int
  var projected: int
  var used: Set[int]
  var pending: Set[int]
  var committed: Set[int]
  var appended: Set[int]
  var seenKinds: Set[int]
  var snapshot: Image
  var image: Image
  var opened: bool
  var owner: int
  var retired: bool
  var frameOwner: int
  var frameCut: Image
  var queued: Set[int]
  var cursor: int
  var calls: int -> int
  var bad: bool
  var held: int

  action init = all {
    serial' = 0, db' = 0, witness' = 0, projected' = 0,
    used' = Set(), pending' = Set(), committed' = Set(), appended' = Set(), seenKinds' = Set(),
    snapshot' = (0, 0, 0), image' = (0, 0, 0), opened' = false,
    owner' = 1, retired' = false, frameOwner' = 0, frameCut' = (0, 0, 0),
    queued' = Set(), cursor' = 0, calls' = rows.mapBy(_ => 0), bad' = false, held' = 3
  }
  val stamp = (serial, db, witness)
  val joined = (pending.size() == 0) and projected == witness and image == stamp
  val live = opened and joined and not(retired) and owner == 1

  action close(op: int, kind: int): bool = all {
    operations.contains(op), kinds.contains(kind), pending.size() < 3, not(used.contains(op)),
    used' = used.union(Set(op)), serial' = serial + 1, pending' = pending.union(Set(op)), opened' = false,
    seenKinds' = seenKinds.union(Set(kind)),
    all { db' = db, witness' = witness, projected' = projected, committed' = committed, appended' = appended, snapshot' = snapshot, image' = image, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action appendWitness(op: int): bool = all {
    pending.contains(op), not(appended.contains(op)), not(committed.contains(op)),
    appended' = appended.union(Set(op)), witness' = witness + 1,
    all { used' = used, serial' = serial, db' = db, projected' = projected, pending' = pending, committed' = committed, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action commit(op: int): bool = all {
    pending.contains(op), not(committed.contains(op)),
    db' = db + 1, projected' = witness, committed' = committed.union(Set(op)),
    all { used' = used, serial' = serial, witness' = witness, pending' = pending, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  // Operation numbers are unique close tickets, not reusable client labels.
  // Receipt loss leaves the operation pending. A late exact receipt resolves only itself.
  action resolve(op: int): bool = all {
    pending.contains(op), committed.contains(op),
    pending' = pending.exclude(Set(op)),
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action abortNoEffect(op: int): bool = all {
    pending.contains(op), not(committed.contains(op)), not(appended.contains(op)),
    pending' = pending.exclude(Set(op)),
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action readImage = all {
    (pending.size() == 0), witness == projected, snapshot' = stamp,
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, pending' = pending, committed' = committed, appended' = appended, seenKinds' = seenKinds, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action activate = all {
    (pending.size() == 0), witness == projected, snapshot == stamp,
    image' = snapshot, opened' = true,
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, pending' = pending, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action stageFrame = all {
    live, (queued.size() == 0), rows.contains(cursor),
    queued' = Set(cursor), frameOwner' = owner, frameCut' = image,
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, pending' = pending, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action recordOffer(row: int): bool = all {
    calls' = calls.set(row, calls.get(row) + 1), cursor' = row + 1, queued' = Set(),
    bad' = (bad or not(live) or frameOwner != owner or frameCut != stamp or row != cursor),
    all { used' = used, serial' = serial, db' = db, witness' = witness, projected' = projected, pending' = pending, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, opened' = opened, owner' = owner, retired' = retired, frameOwner' = frameOwner, frameCut' = frameCut, held' = held }
  }
  action deliver(row: int): bool = all {
    live, queued.contains(row), frameOwner == owner, frameCut == stamp, row == cursor,
    recordOffer(row)
  }
  action restart = all {
    used' = used, owner' = owner + 1, retired' = true, opened' = false, serial' = serial + 1,
    all { db' = db, witness' = witness, projected' = projected, pending' = pending, committed' = committed, appended' = appended, seenKinds' = seenKinds, snapshot' = snapshot, image' = image, frameOwner' = frameOwner, frameCut' = frameCut, queued' = queued, cursor' = cursor, calls' = calls, bad' = bad, held' = held }
  }
  action step = {
    nondet op = operations.oneOf()
    nondet kind = kinds.oneOf()
    nondet row = rows.oneOf()
    any { close(op, kind), appendWitness(op), commit(op), resolve(op), abortNoEffect(op),
          readImage, activate, stageFrame, deliver(row), restart }
  }
  val safe = not(bad) and rows.forall(row => calls.get(row) <= 1) and held == 3
    and (opened implies joined)
  action ready = init.then(readImage).then(activate).then(stageFrame)
  action twoPending = ready.then(close(1, 1)).then(close(2, 2))
  action lostWitness = ready.then(close(1, 2)).then(appendWitness(1))

  run firstCommitCannotReadAnotherPendingWriterTest = twoPending.then(commit(1)).then(resolve(1))
    .expect(safe and pending == Set(2)).then(readImage.fail())
  run firstCommitCannotActivateAnotherPendingWriterTest = twoPending.then(commit(1)).then(resolve(1))
    .then(activate.fail())
  run firstCommitCannotDeliverAnotherPendingWriterTest = twoPending.then(commit(1)).then(resolve(1))
    .then(deliver(0).fail())
  run lastReceiptStillRequiresFullImageTest = twoPending.then(commit(1)).then(commit(2))
    .then(resolve(2)).then(resolve(1)).then(activate.fail())
  run lastReceiptAndFullImageRestoreProgressTest = twoPending.then(commit(1)).then(commit(2))
    .then(resolve(2)).then(resolve(1)).then(readImage).then(activate).expect(safe)
  run independentWitnessBeforeDatabaseBlocksDeliveryTest = lostWitness.then(deliver(0).fail())
  run witnessAppendCannotBecomeNoEffectTest = lostWitness.then(abortNoEffect(1).fail())
  run lostDatabaseReceiptKeepsImageClosedTest = lostWitness.then(commit(1)).then(readImage.fail())
  run lostDatabaseReceiptKeepsTransportClosedTest = lostWitness.then(commit(1)).then(deliver(0).fail())
  run exactReceiptRestoresProgressWithoutRestoringOldFrameTest = lostWitness.then(commit(1))
    .then(resolve(1)).then(readImage).then(activate).expect(safe and held == 3).then(deliver(0).fail())
  run noEffectDoesNotRevalidateOldSnapshotTest = ready.then(close(1, 1)).then(abortNoEffect(1))
    .then(activate.fail())
  run newSnapshotDoesNotRevalidateOldFrameTest = ready.then(close(1, 1)).then(abortNoEffect(1))
    .then(readImage).then(activate).then(deliver(0).fail())
  run staleFrameCannotCrossPublicationTest = ready.then(close(1, 1)).then(commit(1)).then(resolve(1))
    .then(readImage).then(activate).then(deliver(0).fail())
  run oldOwnerBufferCannotCrossRestartTest = ready.then(restart).then(readImage).then(activate)
    .expect(safe and held == 3).then(deliver(0).fail())
  run currentFrameIsAcceptedOnceTest = ready.then(deliver(0)).expect(safe and calls.get(0) == 1)
    .then(deliver(0).fail())
  run abortedTicketCannotBeReusedByLateWorkerTest = ready.then(close(1, 1)).then(abortNoEffect(1))
    .then(close(1, 2).fail())
  run checkThenUnlockBeforeTonicCounterexampleTest = ready.then(readImage).then(close(1, 1))
    .then(recordOffer(0)).expect(not(safe) and calls.get(0) == 1)
  run oldReceiptCannotResolveNewOperationTest = twoPending.then(commit(1)).then(resolve(1))
    .expect(pending == Set(2) and safe).then(resolve(1).fail())

  // Unsafe variants reach concrete bad offers, not just an expected rejection.
  action bypassReceiverGuard = recordOffer(0)
  run enqueueAuthorizationIsInsufficientCounterexampleTest = ready.then(close(1, 1))
    .then(bypassReceiverGuard).expect(not(safe) and calls.get(0) == 1)
  run oldWorkerDeliveryCounterexampleTest = ready.then(restart).then(bypassReceiverGuard)
    .expect(not(safe) and calls.get(0) == 1 and held == 3)
  run databaseRollbackCannotEraseWitnessCounterexampleTest = lostWitness
    .then(bypassReceiverGuard).expect(not(safe) and witness > projected and db == 0)
  run earliestCommitCannotAuthorizeTransportCounterexampleTest = twoPending.then(commit(1))
    .then(resolve(1)).then(bypassReceiverGuard).expect(not(safe) and pending == Set(2))

  // Exercise each semantic writer class with the same ordering, not a policy-only model.
  run allWriterClassesUseTheSameCutTest = ready.then(close(1, 1)).then(close(2, 2)).then(close(3, 3))
    .then(abortNoEffect(1)).then(abortNoEffect(2)).then(abortNoEffect(3))
    .then(close(4, 4)).then(close(5, 5)).then(close(6, 6))
    .then(abortNoEffect(4)).then(abortNoEffect(5)).then(abortNoEffect(6))
    .then(close(7, 7)).then(close(8, 8)).then(abortNoEffect(7)).then(abortNoEffect(8))
    .then(readImage).then(activate).expect(safe and seenKinds == kinds)
}

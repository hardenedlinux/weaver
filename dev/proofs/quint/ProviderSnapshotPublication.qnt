// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// A four-range native outcome publishes one bounded immutable qualification.
// Every actual offer still owns a separate acknowledgment and one-use cursor.
module ProviderSnapshotPublication {
  pure val rows=Set(0,1,2,3)
  type State={cut:int,snapshotCut:int,owner:int,snapshotOwner:int,
    pending:Set[int],used:Set[int],burned:Set[int],ack:Set[int],offers:int->int,
    committed:bool,published:bool,failed:bool,allowed:bool,claimCurrent:bool,
    expired:bool,reading:bool,requested:bool,renewals:int,cursor:int,held:int,calls:int,bad:bool}
  var s:State
  action init=s'={cut:0,snapshotCut:0,owner:1,snapshotOwner:1,
    pending:Set(),used:Set(),burned:Set(),ack:Set(),offers:rows.mapBy(_=>0),
    committed:false,published:false,failed:false,allowed:true,claimCurrent:true,
    expired:false,reading:false,requested:false,renewals:0,cursor:0,held:4,calls:1,bad:false}
  action close(id:int):bool=all {not(s.used.contains(id)),
    s'={...s,pending:s.pending.union(Set(id)),used:s.used.union(Set(id))}}
  action commitSource(id:int):bool=all {s.pending.contains(id),
    s'={...s,cut:s.cut+1,pending:s.pending.exclude(Set(id))}}
  action commitGroup=all {not(s.committed),not(s.failed),s.allowed,s.claimCurrent,
    s'={...s,burned:rows,committed:true,snapshotCut:s.cut,snapshotOwner:s.owner}}
  action publish=all {s.committed,s.burned==rows,not(s.failed),
    s'={...s,published:true}}
  action acknowledge(id:int):bool=all {rows.contains(id),s.published,s.burned==rows,
    s'={...s,ack:s.ack.union(Set(id))}}
  action refresh=all {s.committed,s.burned==rows,s.pending.size()==0,
    not(s.failed),s.allowed,s.claimCurrent,not(s.expired),s.snapshotOwner==s.owner,
    s'={...s,snapshotCut:s.cut,published:true,renewals:s.renewals+1}}
  action offer=all {rows.contains(s.cursor),s.published,s.ack.contains(s.cursor),
    s.burned==rows,s.pending.size()==0,not(s.failed),not(s.expired),s.allowed,s.claimCurrent,
    s.snapshotCut==s.cut,s.snapshotOwner==s.owner,
    s'={...s,offers:s.offers.set(s.cursor,s.offers.get(s.cursor)+1),cursor:s.cursor+1}}
  action revoke=s'={...s,cut:s.cut+1,allowed:false}
  action migrate=s'={...s,cut:s.cut+1,claimCurrent:false}
  action expire=s'={...s,expired:true}
  action unknown=s'={...s,failed:true,published:false}
  action restart=s'={...s,owner:s.owner+1,failed:false}
  // Mutants isolate the two rejected shortcuts: publish a partial native
  // result, or separate an Arc snapshot load from the final gated use.
  action partialPublication=s'={...s,burned:Set(0),published:true,ack:Set(0)}
  action uncheckedOffer=all {rows.contains(s.cursor),s.ack.contains(s.cursor),
    s'={...s,cursor:s.cursor+1,bad:s.bad or s.snapshotCut!=s.cut or s.snapshotOwner!=s.owner or s.pending.size()>0 or s.expired or s.failed}}
  action beginPeerRead=all {not(s.reading),s'={...s,reading:true}}
  action finishPeerRead=all {s.reading,s'={...s,reading:false}}
  action requestRefresh=all {s.published,s.snapshotCut!=s.cut,s'={...s,requested:true}}
  action settleSatisfiedDemand=all {s.requested,s.snapshotCut==s.cut,s'={...s,requested:false}}
  action step={nondet id=rows.oneOf()
    any {close(id),commitSource(id),commitGroup,publish,acknowledge(id),refresh,
      offer,revoke,migrate,expire,unknown,restart,beginPeerRead,finishPeerRead,requestRefresh,settleSatisfiedDemand}}
  val safe=not(s.bad) and s.held==4 and s.calls==1 and
    rows.forall(r=>s.offers.get(r)<=1) and (s.published implies s.burned==rows)
  action ready=init.then(commitGroup).then(publish).then(acknowledge(0))
  run commitCannotOfferBeforeAcknowledgmentTest=init.then(commitGroup).then(publish).then(offer.fail())
  run oneNativeCommitCoversFourExactRangesTest=ready.then(offer).then(acknowledge(1)).then(offer)
    .then(acknowledge(2)).then(offer).then(acknowledge(3)).then(offer).expect(safe and s.cursor==4)
  run pendingSourceStillBlocksFinalUseTest=ready.then(close(0)).then(offer.fail())
  run lostCommitReplyCannotActivateTest=init.then(commitGroup).then(unknown).then(publish.fail())
  run nativeCommitDoesNotReleaseBudgetOrSendTest=init.then(commitGroup).expect(s.cursor==0 and s.held==4 and s.calls==1)
  run staleGroupRequiresFullRefreshTest=ready.then(close(0)).then(commitSource(0)).then(offer.fail())
  run oneRefreshCoversUnchangedGroupTest=ready.then(close(0)).then(commitSource(0)).then(refresh)
    .then(offer).then(acknowledge(1)).then(offer).expect(safe)
  run revocationCannotRefreshTest=ready.then(revoke).then(refresh.fail())
  run migrationCannotRefreshTest=ready.then(migrate).then(refresh.fail())
  run expiryNeedsNoStorageMutationTest=ready.then(expire).then(offer.fail())
  run restartCannotRefreshOldSnapshotTest=ready.then(restart).then(refresh.fail())
  run restartCannotOfferOldSnapshotTest=ready.then(restart).then(offer.fail())
  run ungatedPendingClosureIsCounterexampleTest=ready.then(close(0)).then(uncheckedOffer).expect(not(safe))
  run readonlyPeerDoesNotBlockCurrentOfferTest=ready.then(beginPeerRead).then(offer).expect(safe and s.reading)
  run alreadyPendingIntentDefersRenewalTest=ready.then(close(0)).then(commitSource(0)).then(requestRefresh).then(close(1)).then(refresh.fail())
  run committedPendingIntentResumesRenewalTest=ready.then(close(0)).then(commitSource(0)).then(requestRefresh).then(close(1)).then(commitSource(1)).then(refresh).expect(safe and s.snapshotCut==s.cut and s.renewals==1)
  run staleRefreshDemandCannotAddAnotherNativeReadTest=ready.then(close(0)).then(commitSource(0)).then(requestRefresh).then(refresh).then(settleSatisfiedDemand).expect(safe and s.renewals==1)
  run partialCommitIsCounterexampleTest=init.then(partialPublication).expect(not(safe))
  run ungatedArcLoadIsCounterexampleTest=ready.then(close(0)).then(commitSource(0)).then(uncheckedOffer).expect(not(safe))
}

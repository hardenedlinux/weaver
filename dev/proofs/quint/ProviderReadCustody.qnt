// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module ProviderReadCustody {
  pure val tickets=Set(0,1,2,3,4,5)
  type State={waiting:Set[int],active:Set[int],used:Set[int],origin:int->int,exclusive:int->bool,
    snapshot:int->int,version:int,held:int,failed:bool,owner:int,certificateOwner:int,
    committed:bool,consumed:bool,bad:bool,certificateVersion:int,certificateOrigin:int,certificateLocal:int,originRevision:int->int,localIntent:Set[int]}
  var s:State
  action init=s'={waiting:Set(),active:Set(),used:Set(),origin:tickets.mapBy(_=>0),
    exclusive:tickets.mapBy(_=>false),snapshot:tickets.mapBy(_=>0),version:0,held:12,
    failed:false,owner:1,certificateOwner:1,committed:false,consumed:false,bad:false,certificateVersion:0,certificateOrigin:0,certificateLocal:0,originRevision:Set(0,1,2).mapBy(_=>0),localIntent:Set()}
  def conflict(a:int,b:int):bool=s.exclusive.get(a) or s.exclusive.get(b) or s.origin.get(a)==s.origin.get(b)
  def eligible(id:int):bool=s.waiting.forall(older=>older>=id or not(conflict(older,id))) and s.active.forall(other=>not(conflict(other,id)))
  def pendingWriter:bool=s.waiting.union(s.active).exists(id=>s.exclusive.get(id))
def requested(id:int,origin:int,exclusive:bool):State={...s,waiting:s.waiting.union(Set(id)),used:s.used.union(Set(id)),origin:s.origin.set(id,origin),exclusive:s.exclusive.set(id,exclusive)}
  def fresh(id:int):bool=id==s.used.size() and not(s.used.contains(id)) and not(s.failed)
  action request(id:int,origin:int,exclusive:bool):bool=all{fresh(id),s'=requested(id,origin,exclusive)}
  action requestLifecycle(id:int,origin:int):bool=all{fresh(id),s'={...requested(id,origin,false),localIntent:s.localIntent.union(Set(id))}}
  action grant(id:int):bool=all{s.waiting.contains(id),eligible(id),not(s.failed),
    s'={...s,waiting:s.waiting.exclude(Set(id)),active:s.active.union(Set(id)),snapshot:s.snapshot.set(id,s.version)}}
  action finish(id:int):bool=all{s.active.contains(id),
    s'={...s,active:s.active.exclude(Set(id)),version:s.version+(if(s.exclusive.get(id))1 else 0),held:s.held+(if(s.exclusive.get(id))4 else 0),originRevision:if(s.localIntent.contains(id))s.originRevision.set(s.origin.get(id),s.originRevision.get(s.origin.get(id))+1) else s.originRevision}}
  action cancel(id:int):bool=all{s.waiting.contains(id),s'={...s,waiting:s.waiting.exclude(Set(id))}}
  action commitRange(id:int):bool=all{s.active.contains(id),s.certificateOwner==s.owner,s.origin.get(id)==s.certificateOrigin,not(s.exclusive.get(id)),not(s.localIntent.contains(id)),not(s.failed),
    s'={...s,committed:true,certificateVersion:s.version,certificateLocal:s.originRevision.get(s.origin.get(id)),active:s.active.exclude(Set(id))}}
def pendingForFrame:bool=s.waiting.union(s.active).exists(id=>s.exclusive.get(id) or (s.localIntent.contains(id) and s.origin.get(id)==s.certificateOrigin))
  def currentCut:bool=s.certificateVersion==s.version and s.certificateLocal==s.originRevision.get(s.certificateOrigin)
  action offer=all{s.committed,not(s.failed),not(pendingForFrame),currentCut,not(s.consumed),s.certificateOwner==s.owner,
    s'={...s,consumed:true}}
  action unsafeOffer=all{s.committed,not(s.consumed),s'= {...s,consumed:true,bad:not(currentCut) or pendingForFrame}}
  action unknown=s'={...s,failed:true,committed:false}
  action restart=s'={...s,owner:s.owner+1,failed:false,waiting:Set(),active:Set()}
  action unsafeSharedWrite(id:int):bool=all{s.active.contains(id),
    s'={...s,version:s.version+1,active:s.active.exclude(Set(id))}}
  action step={nondet id=tickets.oneOf()
    nondet origin=Set(0,1,2).oneOf()
    nondet exclusive=Set(true,false).oneOf()
    any{request(id,origin,exclusive),requestLifecycle(id,origin),grant(id),finish(id),cancel(id),commitRange(id),offer,unknown,restart}}
  val safe=not(s.bad) and s.held>=12 and s.active.forall(a=>s.snapshot.get(a)==s.version and s.active.forall(b=>a==b or not(conflict(a,b))))
  action pair=init.then(request(0,0,false)).then(grant(0)).then(request(1,1,false)).then(grant(1))
  run compatibleReaderReorderingTest=init.then(request(0,0,false)).then(request(1,1,false)).then(grant(1)).then(grant(0)).expect(safe)
  run distinctOriginsShareReadsTest=pair.expect(safe and s.active==Set(0,1))
  run sameOriginSerializesTest=init.then(request(0,0,false)).then(grant(0)).then(request(1,0,false)).then(grant(1).fail())
  run admissionWaitsForReadersTest=pair.then(request(2,2,true)).then(grant(2).fail())
  run writerPreventsYoungerBypassTest=init.then(request(0,0,false)).then(grant(0)).then(request(1,1,true)).then(request(2,2,false)).then(grant(2).fail())
  run writerResumesAfterReaderDrainTest=pair.then(request(2,2,true)).then(finish(0)).then(finish(1)).then(grant(2)).then(finish(2)).expect(safe and s.held==16)
  run writerBlocksFinalTransferTest=init.then(request(0,0,false)).then(grant(0)).then(commitRange(0)).then(request(1,1,true)).then(offer.fail())
  run leaseAloneCannotSendTest=init.then(request(0,0,false)).then(grant(0)).then(offer.fail())
  run knownCommitAllowsOneTransferTest=init.then(request(0,0,false)).then(grant(0)).then(commitRange(0)).then(offer).then(offer.fail())
  run unknownCommitBlocksTest=init.then(request(0,0,false)).then(grant(0)).then(unknown).then(offer.fail())
  run restartRejectsOldOwnerTest=init.then(request(0,0,false)).then(grant(0)).then(commitRange(0)).then(restart).then(offer.fail())
  run cancellationRetainsReservationTest=init.then(request(0,0,false)).then(cancel(0)).expect(safe and s.held==12)
  run unsafeSharedMutationCounterexampleTest=pair.then(unsafeSharedWrite(0)).expect(not(safe))
  action qualified=init.then(request(0,0,false)).then(grant(0)).then(commitRange(0))
  run committedBeforeSharedChangeTest=qualified.then(request(1,1,true)).then(grant(1)).then(finish(1)).then(offer.fail())
  run unsafeStaleSharedCutCounterexampleTest=qualified.then(request(1,1,true)).then(grant(1)).then(finish(1)).then(unsafeOffer).expect(not(safe))
  run ownLifecycleClosesPendingFrameTest=qualified.then(requestLifecycle(1,0)).then(offer.fail())
  run ownLifecycleRetiresFrameTest=qualified.then(requestLifecycle(1,0)).then(grant(1)).then(finish(1)).then(offer.fail())
  run peerLifecyclePreservesFrameTest=qualified.then(requestLifecycle(1,1)).then(grant(1)).then(finish(1)).then(offer).expect(safe)
  run ownProgressPreservesFrameTest=qualified.then(request(1,0,false)).then(grant(1)).then(offer).expect(safe)  run staleWorkerCannotPrepareTest=init.then(restart).then(request(0,0,false)).then(grant(0)).then(commitRange(0).fail())
  run foreignOriginCannotQualifyOriginalFrameTest=init.then(request(0,1,false)).then(grant(0)).then(commitRange(0).fail())
}

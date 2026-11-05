// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Five finite rows exercise a three-frame pipeline and one receiver cursor.
// Range count generality is supplied separately by the Lean prefix theorem.
module ProviderDeliveryPipeline {
  pure val rows = Set(0,1,2,3,4)
  type Frame = {cut:int, owner:int, committed:bool, acknowledged:bool}
  type State = {cut:int, owner:int, produced:int, cursor:int, held:int, allowed:bool,
    pending:Set[int], used:Set[int], frames:int->Frame, offers:int->int}
  var s:State
  action init = s' = {cut:0,owner:1,produced:0,cursor:0,held:4,allowed:true,
    pending:Set(),used:Set(),frames:rows.mapBy(_=>{cut:0,owner:0,committed:false,acknowledged:false}),
    offers:rows.mapBy(_=>0)}
  action stage = all {
    s.produced<5,s.produced-s.cursor<3,
    s'={...s,produced:s.produced+1,frames:s.frames.set(s.produced,
      {cut:s.cut,owner:s.owner,committed:false,acknowledged:false})}
  }
  action release(id:int):bool = all {
    id>=s.cursor,id<s.produced,not(s.frames.get(id).committed),s.allowed,s.pending.size()==0,
    s'={...s,cut:s.cut+1,frames:s.frames.set(id,{...s.frames.get(id),cut:s.cut+1,committed:true})}
  }
  action ack(id:int):bool = all {
    id>=s.cursor,id<s.produced,s.frames.get(id).committed,not(s.frames.get(id).acknowledged),
    s'={...s,frames:s.frames.set(id,{...s.frames.get(id),acknowledged:true})}
  }
  action qualify = all {
    s.cursor<s.produced,s.allowed,s.pending.size()==0,
    s.frames.get(s.cursor).owner==s.owner,s.frames.get(s.cursor).committed,
    s'={...s,frames:s.frames.set(s.cursor,{...s.frames.get(s.cursor),cut:s.cut})}
  }
  action accept = all {
    s.cursor<s.produced,s.allowed,s.pending.size()==0,
    s.frames.get(s.cursor).owner==s.owner,s.frames.get(s.cursor).cut==s.cut,
    s.frames.get(s.cursor).committed,s.frames.get(s.cursor).acknowledged,
    s'={...s,cursor:s.cursor+1,offers:s.offers.set(s.cursor,s.offers.get(s.cursor)+1)}
  }
  action close(id:int):bool = all {
    not(s.used.contains(id)),s'={...s,used:s.used.union(Set(id)),pending:s.pending.union(Set(id))}
  }
  action decide(id:int):bool = all {
    s.pending.contains(id),s'={...s,cut:s.cut+1,pending:s.pending.exclude(Set(id))}
  }
  action revoke = s'={...s,cut:s.cut+1,allowed:false}
  action restart = s'={...s,owner:s.owner+1,cut:s.cut+1}
  action step = {
    nondet id=rows.oneOf()
    any {stage,release(id),ack(id),qualify,accept,close(id),decide(id),revoke,restart}
  }
  val safe = rows.forall(id=>s.offers.get(id)<=1) and s.held==4 and
    rows.fold(0,(sum,id)=>sum+s.offers.get(id))==s.cursor and s.produced-s.cursor<=3
  action first = init.then(stage).then(release(0)).then(ack(0))
  action full = first.then(stage).then(release(1)).then(ack(1))
    .then(stage).then(release(2)).then(ack(2))
  run threeInertFramesNeedNoStopAndWaitTest = full.expect(safe and s.produced-s.cursor==3).then(stage.fail())
  run committedPipelineRequalifiesItsHeadTest = full.then(qualify).then(accept).expect(safe)
  run nextCommittedFrameInvalidatesOlderCertificateTest = first.then(stage).then(release(1))
    .then(accept.fail())
  run receiverPrefixOutlivesRequalificationTest = first.then(accept).then(stage).then(release(1))
    .then(ack(1)).then(qualify).then(accept).expect(safe and s.cursor==2)
  run pendingSourceStopsAllQueuedFramesTest = first.then(close(1)).then(accept.fail())
  run sourceResolutionRequiresCurrentRequalificationTest = first.then(close(1)).then(decide(1))
    .then(qualify).then(accept).expect(safe)
  run revokeRetiresQueuedFramesWithoutRefundTest = first.then(revoke).expect(s.held==4).then(qualify.fail())
  run oldOwnerCannotDrainQueuedTailTest = first.then(restart).then(accept.fail())
  run stagedFrameCannotBeAcknowledgedTest = init.then(stage).then(ack(0).fail())
}

// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Compose the existing native receipt model with an abstract transport slot.
// One slot is a bounded frame, not one TCP packet or a claimed byte/latency bound.
module HttpDeliveryCredit {
  import ProviderDeliveryPipeline as D from "./ProviderDeliveryPipeline"
  type Transport = {queued:List[int],received:int,credit:int,cancelled:bool,queries:int}
  var q:Transport
  action init = all {D::init,q'={queued:[],received:0,credit:0,cancelled:false,queries:0}}
  action stage = all {not(q.cancelled),D::stage,q'=q}
  action release(id:int):bool = all {D::release(id),q'=q}
  action ack(id:int):bool = all {D::ack(id),q'=q}
  action qualify = all {D::qualify,q'=q}
  action revoke = all {D::revoke,q'=q}
  action restart = all {D::restart,q'=q}
  action handoff(bounded:bool):bool = all {
    not(q.cancelled),not(bounded) or q.queued.length()<1,
    D::accept,q'=q.with("queued",q.queued.append(D::s.cursor))
  }
  action grant = all {q.credit==0,D::s'=D::s,q'=q.with("credit",1)}
  // Previously accepted bytes are historical; withdrawal stops new handoffs,
  // not already transferred frames in the bounded network stage.
  action drain = all {
    q.credit>0,q.queued.length()>0,q.queued.nth(0)==q.received,
    D::s'=D::s,q'={...q,queued:q.queued.slice(1,q.queued.length()),received:q.received+1,credit:0}
  }
  action cancel = all {D::s'=D::s,q'=q.with("cancelled",true)}
  action query = all {D::s'=D::s,q'=q.with("queries",q.queries+1)}
  action coupledQuery = all {q.queued.length()==0,query}
  action explore(bounded:bool):bool = {
    nondet id=Set(0,1,2,3,4).oneOf()
    any {stage,release(id),ack(id),qualify,handoff(bounded),grant,drain,cancel,revoke,restart,query}
  }
  action step=explore(true)
  action nativeQueueOnlyStep=explore(false)
  val safe = D::safe and q.queued.length()<=1 and q.received<=D::s.cursor and
    q.queued.indices().forall(i=>q.queued.nth(i)==q.received+i)
  action first = init.then(stage).then(release(0)).then(ack(0)).then(handoff(true))
  action second = first.then(stage).then(release(1)).then(ack(1))
  run zeroWindowKeepsNextFrameInNativeCustodyTest=second.expect(safe).then(handoff(true).fail())
  run demandAdvancesOneHistoricalFrameTest=second.then(grant).then(drain).then(handoff(true)).expect(safe and q.received==1)
  run siblingQueryDoesNotBorrowStreamCreditTest=first.then(query).expect(safe and q.credit==0 and q.queries==1)
  run coupledQueryHasAnUnnecessaryProgressBarrierTest=first.expect(safe).then(coupledQuery.fail())
  run resetStopsNewHandoffsWithoutRefundTest=second.then(cancel).expect(safe and D::s.held==4).then(handoff(true).fail())
  run withdrawalStopsNewHandoffsTest=second.then(revoke).expect(safe).then(handoff(true).fail())
  run historicalTransportDoesNotNeedAnotherSendGrantTest=first.then(revoke).then(grant).then(drain).expect(safe and q.received==1)
  run nativeQueueAloneMissesReadAheadTest=second.then(handoff(false)).expect(D::safe and not(safe))
}

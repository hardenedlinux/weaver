// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmSourceJoin {
  import LlmAdmissionFloor as F from "./LlmAdmissionFloor"
  import LlmAccountCommit as A from "./LlmAccountCommit"
  type Ticket={proposal:F::Proposal,operation:int,intent:int,floor:F::Receipt,account:A::Image,journal:List[A::Record],worker:int,sourceGeneration:int,qualified:bool,sourceRevision:int}
  type Join={revision:int,allows:bool,ticket:Ticket,haveTicket:bool,lastChecked:bool,attempted:Ticket}
  var j:Join
  pure val empty={proposal:F::pAppend,operation:0,intent:0,floor:{revision:1,record:F::seed},account:A::after0,journal:List(),worker:0,sourceGeneration:0,qualified:true,sourceRevision:0}
  pure val initial={revision:0,allows:true,ticket:empty,haveTicket:false,lastChecked:true,attempted:empty}
  def current(p)={proposal:p,operation:p.id,intent:p.intent,floor:F::current,account:A::a.anchor,journal:A::a.journal,worker:A::a.epoch,sourceGeneration:A::a.sourceGeneration,qualified:A::a.qualified,sourceRevision:j.revision}
  def joined(p)=j.haveTicket and j.ticket==current(p)
  val safety=j.lastChecked and F::safety
  action idle=all {F::idle,F::f'=F::f}
  action init=all {F::sealedRecovered,j'=initial}
  action appendInit=all {F::qualifiedInit,j'=initial}
  action validate(p,authentic)=all {authentic,F::qualified,j.allows,idle,j'=j.with("ticket",current(p)).with("haveTicket",true)}
  action sourceChange(allow)=all {idle,j'=j.with("revision",j.revision+1).with("allows",allow)}
  action publishCut(p)=all {joined(p),j.allows,F::commitCut(p,true,true,true),j'=j.with("haveTicket",false)}
  action publishAppend(p)=all {joined(p),j.allows,F::commitAppend(p,true,true,true),j'=j.with("haveTicket",false)}
  action publishFence(p)=all {joined(p),j.allows,F::commitFence(p,true,true,true),j'=j.with("haveTicket",false)}
  action propose(p)=all {F::propose(p,true),j'=j}
  action financialCommit=all {F::financialCommit,j'=j}
  action query=all {F::query(A::a.epoch,true),j'=j}
  action copies=all {F::installCopies(true),j'=j}
  action project=all {F::project(A::a.epoch,true),j'=j}
  action resolve(id)=all {F::resolve(id),j'=j}
  action loseReply=all {F::loseReply,j'=j}
  action restart=all {idle,j'=j.with("haveTicket",false)}
  action restore=all {F::restore(F::i0,Set(),Set()),j'=j}
  action staged=init.then(propose(F::pFence)).then(validate(F::pFence,true))
  action accountChanged=staged.then(financialCommit)
  action sourceChanged=staged.then(sourceChange(false))
  action sourceReallowed=sourceChanged.then(sourceChange(true))
  action fenced=staged.then(publishFence(F::pFence))
  action appendStaged=appendInit.then(propose(F::pAppend)).then(validate(F::pAppend,true))
  action appendPublished=appendStaged.then(publishAppend(F::pAppend))
  action earlyCutStaged=appendInit.then(propose(F::pEarlyCut)).then(validate(F::pEarlyCut,true))
  action step={nondet p=Set(F::pAppend,F::pCut,F::pEarlyCut,F::pFence).oneOf()
    any {validate(p,true),sourceChange(true),sourceChange(false),publishCut(p),publishAppend(p),publishFence(p),propose(p),financialCommit,
      query,copies,project,resolve(p.id),loseReply,restart,restore}}
  run exactCurrentJoinAllowsPublicationTest=fenced.expect(safety and not(j.haveTicket))
  run sameFloorAccountChangeInvalidatesJoinTest=accountChanged.expect(safety and F::current==j.ticket.floor and A::a.anchor!=j.ticket.account and not(joined(F::pFence)))
  run changedAccountBlocksFinalCASTest=accountChanged.then(publishFence(F::pFence).fail())
  run revalidateAfterRealAccountChangeTest=accountChanged.then(validate(F::pFence,true)).then(publishFence(F::pFence)).expect(safety and A::a.journal.length()==2)
  run changedAttemptCannotReuseJoinTest=staged.then(publishFence(F::pFence.with("after",F::pFence.after.with("frontier",99))).fail())
  run sourceChangeBlocksFinalCASTest=sourceChanged.then(publishFence(F::pFence).fail())
  run sourceAllowAgainCannotReuseOldTicketTest=sourceReallowed.then(publishFence(F::pFence).fail())
  run revalidateSameIntentAfterSourceChangeTest=sourceReallowed.then(validate(F::pFence,true)).then(publishFence(F::pFence)).expect(safety)
  run sourceDenialPreventsValidationTest=sourceChanged.then(validate(F::pFence,true).fail())
  run unauthenticatedValidationRejectedTest=init.then(validate(F::pFence,false).fail())
  run differentOriginalOperationCannotUseJoinTest=appendStaged.then(publishCut(F::pEarlyCut).fail())
  run commitLostReplyResolvesOriginalOnlyTest=appendPublished.then(loseReply).then(resolve(1)).expect(safety and F::f.resolved.proposal==F::pAppend and not(j.haveTicket))
  run lostReplyRetryCannotReadmitTailTest=appendPublished.then(loseReply).then(resolve(1)).then(query).then(copies).then(project).then(validate(F::pAppend,true)).then(publishAppend(F::pAppend).fail())
  run restartClearsJoinTest=staged.then(restart).then(publishFence(F::pFence).fail())
  run oldWorkerCannotPublishAfterFenceTest=fenced.then(query).then(copies).then(project).then(propose(F::pOldFence)).then(validate(F::pOldFence,true)).then(publishFence(F::pOldFence).fail())
  run restoredOldImageCannotReuseJoinTest=staged.then(restore).then(publishFence(F::pFence).fail())
  run controlJoinDoesNotApplyMoneyTest=fenced.expect(safety and A::a.anchor==A::after0 and A::a.anchor.holds.get(12)==2 and A::a.journal.length()==1)
  run actualFinancialChangeRemainsSeparateTest=accountChanged.expect(safety and A::a.journal.length()==2 and A::a.anchor.used==Set(11,12))
  run sourceChangeKeepsUnknownHoldTest=sourceChanged.expect(safety and A::a.anchor.holds.get(12)==2 and A::a.anchor.used==Set(11))
  run reauthorizeDoesNotResetPendingIntentTest=sourceReallowed.then(validate(F::pFence,true)).expect(safety and F::f.pending.contains(F::pFence))
  action unsafeFence(p)=all {F::commitFence(p,true,true,true),j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
  action unsafeCut(p)=all {F::commitCut(p,true,true,true),j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
  action unsafeDescriptor(p)=all {idle,j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
  run sameFloorAccountJoinCounterexampleTest=accountChanged.then(unsafeFence(F::pFence)).expect(not(j.lastChecked))
  run sourceDeniedJoinCounterexampleTest=sourceChanged.then(unsafeFence(F::pFence)).expect(not(j.lastChecked))
  run sourceABAJoinCounterexampleTest=sourceReallowed.then(unsafeFence(F::pFence)).expect(not(j.lastChecked))
  run differentIntentJoinCounterexampleTest=appendStaged.then(propose(F::pEarlyCut)).then(unsafeCut(F::pEarlyCut)).expect(not(j.lastChecked))
  run lostReplyJoinCounterexampleTest=appendPublished.then(loseReply).then(resolve(1)).then(unsafeDescriptor(F::pAppend)).expect(not(j.lastChecked))
  run restartJoinCounterexampleTest=staged.then(restart).then(unsafeFence(F::pFence)).expect(not(j.lastChecked))
  run staleWorkerJoinCounterexampleTest=fenced.then(unsafeDescriptor(F::pOldFence)).expect(not(j.lastChecked))
}

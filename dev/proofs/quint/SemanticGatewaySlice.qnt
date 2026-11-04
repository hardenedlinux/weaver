// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module SemanticGatewaySlice {
  import LlmRouting as R from "./LlmRouting"
  import RoutineRoutingConfig as C from "./RoutineRoutingConfig"
  type Ticket={origin:int,profile:int,response:int,generation:int,epoch:int}
  type Execution={generation:int,epoch:int,recovered:bool,queued:bool,ticket:Ticket,consumed:bool,calls:int,bytes:int,terminal:bool,noExecution:bool,usageKnown:bool,usage:int,held:bool,settled:bool}
  var e:Execution
  pure val original={origin:0,payload:10,profile:11,response:1,allowance:10,history:3,budget:4}
  pure val emptyTicket:Ticket={origin:-1,profile:-1,response:-1,generation:-1,epoch:-1}
  pure val initial:Execution={generation:0,epoch:0,recovered:true,queued:false,ticket:emptyTicket,consumed:false,calls:0,bytes:0,terminal:false,noExecution:false,usageKnown:false,usage:0,held:true,settled:false}
  pure def sameOrigin(t:Ticket):bool=t.origin==original.origin and t.profile==original.profile and t.response==original.response
  def currentTicket:Ticket={origin:original.origin,profile:original.profile,response:original.response,generation:e.generation,epoch:e.epoch}
  val safety:bool=C::invariant and e.calls==R::r.dispatches.size() and e.calls<=1 and e.bytes>=0 and e.bytes<=3 and
    (e.consumed==(e.calls==1)) and (e.bytes>0 implies e.consumed) and
    (e.queued implies sameOrigin(e.ticket)) and
    (not(e.held) implies e.terminal and e.usageKnown and e.settled) and
    (e.noExecution implies e.terminal and e.calls==0 and not(e.queued) and e.usage==0) and
    (e.settled implies e.usageKnown and e.terminal and e.usage>=0 and e.usage<=original.allowance)
  action idle:bool=all {R::r'=R::r,C::cfg'=C::cfg}
  action boot:bool=all {C::boot,e'=initial}
  action configure:bool=all {C::configure(0,C::normal,true,true,true),e'=e}
  action pin:bool=all {C::pin,e'=e}
  action plan:bool=all {C::planRoute(0,100),e'=e}
  action enqueue(t:Ticket):bool=all {e.recovered,not(e.terminal),not(e.consumed),not(e.queued),sameOrigin(t),t==currentTicket,C::cfg.hasPin,C::cfg.plans.size()>0,idle,e'=e.with("queued",true).with("ticket",t)}
  // The same deciding event consumes durable execution identity and calls the prior router.
  // Native atomicity, authenticated current facts and actual transport ownership remain premises.
  action execute(t:Ticket,compilerCurrent:bool,policyCurrent:bool):bool=all {e.recovered,e.queued,not(e.terminal),not(e.consumed),t==e.ticket,t==currentTicket,sameOrigin(t),C::dispatch(0,compilerCurrent,policyCurrent),e'=e.with("queued",false).with("consumed",true).with("calls",e.calls+1)}
  action publishHardChange:bool=all {idle,e'=e.with("generation",e.generation+1)}
  action policyChange:bool=all {C::restrict,e'=e}
  action historyChange:bool=all {C::history,e'=e}
  action restart:bool=all {idle,e'=e.with("epoch",e.epoch+1).with("recovered",false)}
  action recover:bool=all {not(e.recovered),idle,e'=e.with("recovered",true)}
  action rejoin:bool=all {e.recovered,e.queued,not(e.consumed),not(e.terminal),idle,e'=e.with("ticket",currentTicket)}
  action write(worker:int):bool=all {worker==e.epoch,e.recovered,e.ticket==currentTicket,C::eligible(0),R::r.dispatches.forall(d=>d.snapshot==R::currentView),e.consumed,not(e.terminal),e.bytes<3,idle,e'=e.with("bytes",e.bytes+1)}
  action finish(worker:int):bool=all {worker==e.epoch,e.recovered,e.consumed,not(e.terminal),idle,e'=e.with("terminal",true)}
  // This is a deciding no-execution seal, not a source-side zero-call observation.
  action noExecutionSeal:bool=all {e.recovered,not(e.consumed),not(e.terminal),R::r.dispatches.size()==0,idle,e'=e.with("queued",false).with("generation",e.generation+1).with("terminal",true).with("noExecution",true).with("usageKnown",true).with("usage",0)}
  action usageReceipt(origin:int,profile:int,amount:int,authentic:bool):bool=all {authentic,origin==original.origin,profile==original.profile,e.consumed,e.terminal,not(e.usageKnown),amount>=0,amount<=original.allowance,idle,e'=e.with("usageKnown",true).with("usage",amount)}
  action settle:bool=all {e.recovered,e.terminal,e.usageKnown,not(e.settled),idle,e'=e.with("settled",true).with("held",false)}
  action timeout:bool=all {idle,e'=e}
  action ready:bool=boot.then(configure).then(pin).then(plan)
  action queued:bool=ready.then(enqueue(currentTicket))
  action sent:bool=queued.then(execute(e.ticket,true,true))
  action step:bool=any {configure,pin,plan,enqueue(currentTicket),execute(e.ticket,true,true),publishHardChange,policyChange,historyChange,restart,recover,rejoin,write(e.epoch),finish(e.epoch),noExecutionSeal,usageReceipt(0,11,6,true),settle,timeout}
  run queueHasNoExternalSendTest=queued.expect(safety and e.calls==0 and R::r.dispatches.size()==0 and e.held)
  run actualDispatchUsesOriginalRouterTest=sent.expect(safety and e.calls==1 and R::r.dispatches.size()==1)
  run forgedProfileCannotQueueTest=ready.then(enqueue(currentTicket.with("profile",12)).fail())
  run forgedOriginCannotQueueTest=ready.then(enqueue(currentTicket.with("origin",1)).fail())
  run changedResponseCannotQueueTest=ready.then(enqueue(currentTicket.with("response",2)).fail())
  run generationChangeRejectsOldPermitTest=queued.then(publishHardChange).then(execute(e.ticket,true,true).fail())
  run rejoinPreservesIdentityTest=queued.then(publishHardChange).then(rejoin).then(execute(e.ticket,true,true)).expect(safety and e.calls==1)
  run policyAfterQueueRejectsSendTest=queued.then(policyChange).then(execute(e.ticket,true,true).fail())
  run historyAfterQueueRejectsSendTest=queued.then(historyChange).then(execute(e.ticket,true,true).fail())
  run artifactCurrentnessRequiredTest=queued.then(execute(e.ticket,false,true).fail())
  run actualPolicyRequiredTest=queued.then(execute(e.ticket,true,false).fail())
  run crashBeforeDispatchKeepsQueueTest=queued.then(restart).expect(safety and e.queued and e.held and e.calls==0)
  run oldWorkerAfterRecoveryRejectedTest=queued.then(restart).then(recover).then(execute(e.ticket,true,true).fail())
  run recoveryRejoinCanProgressTest=queued.then(restart).then(recover).then(rejoin).then(execute(e.ticket,true,true)).expect(safety)
  run lostReplyCannotRetryTest=sent.then(timeout).then(execute(e.ticket,true,true).fail())
  run crashAfterDispatchCannotRetryTest=sent.then(restart).then(recover).then(enqueue(currentTicket).fail())
  run partialWriteRetainsUnknownHoldTest=sent.then(write(0)).then(timeout).expect(safety and e.bytes==1 and e.held and not(e.usageKnown))
  run policyChangeStopsNextWriteTest=sent.then(write(0)).then(policyChange).then(write(0).fail())
  run historyChangeStopsNextWriteTest=sent.then(write(0)).then(historyChange).then(write(0).fail())
  run newGenerationStopsNextWriteTest=sent.then(write(0)).then(publishHardChange).then(write(0).fail())
  run oldWriterCannotReleaseAfterRestartTest=sent.then(write(0)).then(restart).then(recover).then(finish(0).fail())
  run lateReceiptIsNotFreshSendTest=sent.then(finish(0)).then(restart).then(recover).then(usageReceipt(0,11,6,true)).then(settle).expect(safety and e.calls==1 and e.usage==6)
  run timeoutDoesNotReleaseBudgetTest=sent.then(timeout).then(settle.fail())
  run foreignUsageReceiptRejectedTest=sent.then(finish(0)).then(usageReceipt(1,11,0,true).fail())
  run untrustedUsageReceiptRejectedTest=sent.then(finish(0)).then(usageReceipt(0,11,0,false).fail())
  run settlementRequiresTerminalTest=sent.then(usageReceipt(0,11,6,true).fail())
  run noExecutionSealFencesQueuedWorkTest=queued.then(noExecutionSeal).then(settle).expect(safety and e.calls==0 and not(e.held))
  run noExecutionRejectsOldQueuedPermitTest=queued.then(noExecutionSeal).then(settle).then(execute(e.ticket,true,true).fail())
  run duplicateSettlementRejectedTest=sent.then(finish(0)).then(usageReceipt(0,11,6,true)).then(settle).then(timeout).then(settle.fail())
  // Deliberate faults are excluded from step.
  action unsafeQueueSend:bool=all {idle,e'=e.with("calls",1)}
  action unsafeBudgetRelease:bool=all {idle,e'=e.with("held",false)}
  action unsafeForgetExecution:bool=all {idle,e'=e.with("consumed",false).with("calls",0)}
  action unsafeNoExecution:bool=all {idle,e'=e.with("terminal",true).with("noExecution",true).with("usageKnown",true).with("usage",0)}
  action unsafeForeignTicket:bool=all {idle,e'=e.with("ticket",e.ticket.with("origin",1))}
  action unsafeSecondDispatch:bool=all {C::unsafeRetry,e'=e.with("calls",e.calls+1)}
  run queueSendCounterexampleTest=queued.then(unsafeQueueSend).expect(not(safety))
  run unknownRefundCounterexampleTest=sent.then(timeout).then(unsafeBudgetRelease).expect(not(safety))
  run forgottenConsumptionCounterexampleTest=sent.then(restart).then(unsafeForgetExecution).expect(not(safety))
  run sourceZeroCallCounterexampleTest=sent.then(unsafeNoExecution).expect(not(safety))
  run foreignTicketCounterexampleTest=queued.then(unsafeForeignTicket).expect(not(safety))
  run hiddenSdkRetryCounterexampleTest=sent.then(unsafeSecondDispatch).expect(not(safety))
}

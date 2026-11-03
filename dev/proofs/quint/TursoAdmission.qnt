// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module TursoAdmission {
  import RuntimeAdmission as R from "./RuntimeAdmission"
  var active:bool
  var before:R::State
  var acknowledged:bool
  val visible=if(active)before else R::s
  val safety=R::safety and visible.calls.get(0)<=1 and visible.calls.get(1)<=1
  action init=all{R::init,active'=false,before'=R::initial,acknowledged'=true}
  action reserve(k:int):bool=all{not(active),R::queue(k,3,true),before'=R::s,active'=true,acknowledged'=false}
  action consume(k:int):bool=all{not(active),R::consume(k),before'=R::s,active'=true,acknowledged'=false}
  action commit(reply:bool):bool=all{active,R::s'=R::s,active'=false,before'=before,acknowledged'=reply}
  action abort=all{active,R::s'=before,active'=false,before'=before,acknowledged'=false}
  action crash=all{
    R::s'=(if(active)before else R::s).with("tickets",Set()).with("lock",false),
    active'=false,before'=before,acknowledged'=false
  }
  action publish=all{not(active),R::publish,active'=active,before'=before,acknowledged'=acknowledged}
  action guard(k:int):bool=all{not(active),R::finalGuard(k),active'=active,before'=before,acknowledged'=acknowledged}
  action send(k:int):bool=all{not(active),R::send(k),active'=active,before'=before,acknowledged'=acknowledged}
  action unsafeTornCommit(k:int):bool=all{active,R::unsafeRefund(k),active'=false,before'=before,acknowledged'=true}
  action queued=init.then(reserve(0)).then(commit(true))
  action consumed=queued.then(consume(0)).then(commit(false))
  action step={nondet k=Set(0,1).oneOf() any{reserve(k),consume(k),commit(true),commit(false),abort,crash,publish,guard(k),send(k)}}
  run prepareIsNotVisibleTest=init.then(reserve(0)).expect(visible.holds.get(0)==0 and R::s.holds.get(0)==3 and visible.calls.get(0)==0)
  run abortPublishesNoReservationTest=init.then(reserve(0)).then(abort).expect(safety and R::held==0)
  run writeScopeExcludesPublicationTest=queued.then(consume(0)).then(publish.fail())
  run prepareCannotInvokeTest=queued.then(consume(0)).then(guard(0).fail())
  run unknownCommitKeepsConsumptionTest=consumed.expect(safety and not(acknowledged) and visible.spent.contains(0) and R::held==3).then(consume(0).fail())
  run restartCannotReissueConsumedClaimTest=consumed.then(crash).expect(safety and R::held==3).then(consume(0).fail())
  run finalUseFenceRemainsCurrentTest=consumed.then(publish).then(guard(0).fail())
  run finalWriterExcludesFenceChangeTest=consumed.then(guard(0)).then(publish.fail())
  run originalClaimSendsOnceTest=consumed.then(guard(0)).then(send(0)).then(crash).expect(safety and R::s.calls.get(0)==1 and R::held==3)
  run tornCommitRefundCounterexampleTest=queued.then(consume(0)).then(unsafeTornCommit(0)).expect(not(safety))
}

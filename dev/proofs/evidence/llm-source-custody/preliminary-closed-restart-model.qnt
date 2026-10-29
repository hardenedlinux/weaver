module LlmSourceCustody {
  import LlmSourceJoin as J from "../../qunit/LlmSourceJoin"
  import LlmAdmissionFloor as F from "../../qunit/LlmAdmissionFloor"
  type Custody={phase:int,fence:int,holder:int,original:F::Proposal,attempt:F::Proposal,haveIntent:bool,outcome:F::Record,haveOutcome:bool,resolved:bool,lastChecked:bool}
  var custody:Custody
  pure val initial={phase:0,fence:0,holder:0,original:F::pAppend,attempt:F::pAppend,haveIntent:false,outcome:F::seed,haveOutcome:false,resolved:true,lastChecked:true}
  def current(holder,fence)=holder==custody.holder and fence==custody.fence
  val safety=J::safety and custody.lastChecked and (custody.phase==0 or custody.haveIntent) and
    (not(custody.haveOutcome) or (F::f.log.indices().exists(i=>F::f.log.nth(i)==custody.outcome) and custody.outcome.proposal.id==custody.original.id)) and
    (custody.phase!=4 or (custody.haveOutcome and custody.resolved))
  action idle=all {J::idle,J::j'=J::j}
  action init=all {J::appendInit,custody'=initial}
  action begin(p)=all {custody.phase==0,idle,custody'=custody.with("phase",1).with("original",p).with("attempt",p).with("haveIntent",true)}
  action validate=all {custody.phase==1,custody.resolved,J::validate(custody.attempt,true),custody'=custody}
  action propose=all {custody.phase==1,J::propose(custody.attempt),custody'=custody}
  action arm(holder,fence,durable)=all {custody.phase==1,custody.resolved,current(holder,fence),durable,J::joined(custody.attempt),J::j.allows,idle,custody'=custody.with("phase",2).with("resolved",false)}
  action publish(holder,fence)=all {custody.phase==2,current(holder,fence),not(custody.haveOutcome),J::publishAppend(custody.attempt),custody'=custody.with("phase",3).with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("resolved",false)}
  action transfer(holder,durable)=all {custody.phase>0,custody.phase<4,durable,J::restart,custody'=custody.with("fence",custody.fence+1).with("holder",holder).with("phase",if(custody.haveOutcome) 3 else 1).with("resolved",false)}
  action resolve(holder,fence,authentic)=all {current(holder,fence),authentic,idle,custody'=custody.with("resolved",true)}
  action restart=all {J::restart,custody'=custody.with("resolved",false)}
  action close(holder,fence)=all {custody.phase==3,custody.haveOutcome,custody.resolved,current(holder,fence),idle,custody'=custody.with("phase",4)}
  action sourceChange=all {custody.phase!=2,J::sourceChange(true),custody'=custody}
  action armed=init.then(begin(F::pAppend)).then(propose).then(validate).then(arm(0,0,true))
  action handed=armed.then(transfer(1,true))
  action recovered=handed.then(resolve(1,1,true)).then(validate).then(arm(1,1,true))
  action committed=armed.then(publish(0,0))
  action transferredCommit=committed.then(transfer(1,true))
  action resolvedCommit=transferredCommit.then(resolve(1,1,true))
  action restarted=armed.then(restart)
  action closed=resolvedCommit.then(close(1,1))
  action step=any {begin(F::pAppend),propose,validate,arm(custody.holder,custody.fence,true),publish(custody.holder,custody.fence),transfer(1-custody.holder,true),resolve(custody.holder,custody.fence,true),restart,sourceChange,close(custody.holder,custody.fence)}
  run exactCustodyPublishesTest=committed.expect(safety)
  run transferRequiresResolutionTest=handed.then(validate.fail())
  run recoveredHolderPublishesTest=recovered.then(publish(1,1)).expect(safety)
  run oldCustodyCannotPublishTest=recovered.then(publish(0,0).fail())
  run oldCustodyCannotResolveTest=handed.then(resolve(0,0,true).fail())
  run unprotectedTransferRejectedTest=armed.then(transfer(1,false).fail())
  run unprotectedArmRejectedTest=init.then(begin(F::pAppend)).then(propose).then(validate).then(arm(0,0,false).fail())
  run unresolvedResultCannotCloseTest=committed.then(close(0,0).fail())
  run unknownResultCannotCloseTest=restarted.then(close(0,0).fail())
  run armedMutationBlockedTest=armed.then(sourceChange.fail())
  run lostCommitResolvedAfterTransferTest=resolvedCommit.expect(safety and custody.outcome.proposal==F::pAppend)
  run closeOnlyCustodyTest=closed.expect(safety and F::f.log.length()==2)
  run restartRequiresTransferBeforeRearmTest=restarted.then(arm(0,0,true).fail())
  run knownResultCannotPublishAgainTest=resolvedCommit.then(publish(1,1).fail())
  run forgedRecoveryRejectedTest=handed.then(resolve(1,1,false).fail())
  action unsafeOldPublish=all {J::publishAppend(custody.attempt),custody'=custody.with("phase",3).with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("lastChecked",current(0,0))}
  action unsafeClose=all {idle,custody'=custody.with("phase",4)}
  action unsafeDrop=all {J::restart,custody'=custody.with("haveIntent",false).with("haveOutcome",false)}
  action unsafeWrongResult=all {idle,custody'=custody.with("outcome",{proposal:F::pEarlyCut}).with("haveOutcome",true)}
  action unsafeSourceChange=all {J::sourceChange(true),custody'=custody.with("lastChecked",custody.phase!=2)}
  action unsafeRestoreFence=all {idle,custody'=custody.with("fence",0).with("lastChecked",false)}
  run oldPermitCustodyCounterexampleTest=recovered.then(unsafeOldPublish).expect(not(safety))
  run unknownCloseCustodyCounterexampleTest=restarted.then(unsafeClose).expect(not(safety))
  run unresolvedCloseCustodyCounterexampleTest=committed.then(unsafeClose).expect(not(safety))
  run droppedIntentCustodyCounterexampleTest=handed.then(unsafeDrop).expect(not(safety))
  run wrongResultCustodyCounterexampleTest=handed.then(unsafeWrongResult).expect(not(safety))
  run armedMutationCustodyCounterexampleTest=armed.then(unsafeSourceChange).expect(not(safety))
  run rolledBackFenceCustodyCounterexampleTest=handed.then(unsafeRestoreFence).expect(not(safety))
  run closedRestartMonitorWitnessTest=closed.then(restart).expect(not(safety))
}

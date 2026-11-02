module TaskOrigin {
  type State={registered:bool,origin:int,family:int,epoch:int,receipt:bool,spent:bool,held:int,history:bool,calls:int,unsafe:bool,birth:bool}
  var s:State
  val initial:State={registered:false,origin:0,family:0,epoch:0,receipt:false,spent:false,held:0,history:false,calls:0,unsafe:false,birth:true}
  val safety=not(s.unsafe) and (s.registered implies s.origin==0 and s.family==0) and s.calls<=1 and
    (s.spent implies s.held==4 and s.history) and (s.calls>0 implies s.spent)
  action init=s'=initial
  action register(origin:int,family:int,expected:int):bool=all{expected==s.epoch,s.birth,not(s.registered) or (origin==s.origin and family==s.family),origin==0,family==0,
    s'=s.with("registered",true).with("receipt",true)}
  action consume=all{s.registered,s.birth,not(s.spent),s'=s.with("spent",true).with("held",4).with("history",true)}
  action send=all{s.registered,s.birth,s.spent,s.calls==0,s'=s.with("calls",1)}
  action rotate=s'=s.with("epoch",s.epoch+1)
  action recover=all{s.receipt,s.birth,s'=s}
  action restart=s'=s
  action loseBirth=s'=s.with("birth",false)
  action unsafeRebuildBirth=s'=s.with("birth",true).with("unsafe",true)
  action unsafeRebind=s'=s.with("origin",1).with("family",1)
  action unsafeRepair=s'=s.with("held",0).with("history",false)
  // A source falsely assigning a different stable key is an issuer-trust failure,
  // not something a local registry can infer from equal task content.
  action unsafeIssuerRelabel=s'=s.with("unsafe",true)
  action accepted=init.then(register(0,0,0)).then(consume)
  action step={nondet expected=Set(0,1,2).oneOf() any{register(0,0,expected),consume,send,rotate,recover,restart,loseBirth}}
  run originalTaskCannotChangeOriginTest=accepted.then(register(1,0,0).fail())
  run originalTaskCannotChangeFamilyTest=accepted.then(register(0,1,0).fail())
  run oldWorkerCannotUseNewSourceEpochTest=accepted.then(rotate).then(register(0,0,0).fail())
  run historicalReplyAfterSourceSwitchTest=accepted.then(rotate).then(restart).then(recover).expect(safety and s.spent and s.held==4)
  run replayNeverResetsConsumptionTest=accepted.then(recover).then(consume.fail())
  run sourceSwitchPreservesClaimTest=accepted.then(rotate).then(register(0,0,1)).expect(safety and s.history)
  run rebindCounterexampleTest=accepted.then(unsafeRebind).expect(not(safety))
  run repairRefundCounterexampleTest=accepted.then(restart).then(unsafeRepair).expect(not(safety))
  run issuerTrustCounterexampleTest=accepted.then(unsafeIssuerRelabel).expect(not(safety))
  run missingBirthBlocksFinalUseTest=accepted.then(loseBirth).then(restart).expect(safety and s.held==4).then(send.fail())
  run missingBirthBlocksFreshRegistrationTest=accepted.then(loseBirth).then(register(0,0,0).fail())
  run birthReconstructionCounterexampleTest=accepted.then(loseBirth).then(unsafeRebuildBirth).expect(not(safety))
}

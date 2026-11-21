// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Models the original Magpie ownership record, not a second journal. File
// identities and whole-write-set recovery remain separate obligations.
module AgentConfigIntent {
  type S = {pending:int,local:int,observedOwner:int,owner:int,config:int,
    readable:bool,live:bool,setterDone:bool,intents:int,writes:int,commits:int,unsafe:bool}
  var s:S
  val safe = s.commits<=s.writes and s.writes<=s.intents and not(s.unsafe)
  action init=s'={pending:-1,local:-1,observedOwner:0,owner:0,config:0,
    readable:true,live:true,setterDone:false,intents:0,writes:0,commits:0,unsafe:false}
  action prepare=all {s.live,s.readable,s.pending== -1,
    s'=s.with("pending",s.intents).with("local",s.intents)
      .with("intents",s.intents+1).with("observedOwner",s.owner).with("setterDone",false)}
  action setter=all {s.live,s.local>=0,s.local==s.pending,not(s.setterDone),
    s'=s.with("config",1-s.config).with("writes",s.writes+1).with("setterDone",true)}
  action finish=all {s.live,s.readable,s.local>=0,s.local==s.pending,
    s.setterDone,s.owner==s.observedOwner,
    s'=s.with("owner",s.owner+1).with("commits",s.commits+1)
      .with("pending",-1).with("local",-1).with("setterDone",false)}
  action crash=s'=s.with("live",false).with("local",-1).with("setterDone",false)
  action restart=s'=s.with("live",true)
  action unknownRecord=s'=s.with("readable",false)
  action restoreRead=s'=s.with("readable",true)
  action externalOwnershipChange=s'=s.with("owner",s.owner+1)
  action observe=s'=s
  action step=any {prepare,setter,finish,crash,restart,unknownRecord,restoreRead,
    externalOwnershipChange,observe}
  // A deliberately unsafe recovery, excluded from the implementation schedule.
  action forgetPending=all {s.pending>=0,s'=s.with("pending",-1).with("unsafe",true)}
  run normalEditTest=init.then(prepare).then(setter).then(finish)
    .expect(safe and s.pending== -1 and s.commits==1)
  run setterRequiresIntentTest=init.then(setter.fail())
  run secondPreparationRefusesTest=init.then(prepare).then(prepare.fail())
  run beforeSetterCrashKeepsIntentTest=init.then(prepare).then(crash).then(restart)
    .expect(safe and s.pending==0 and s.config==0).then(prepare.fail())
  run afterSetterCrashKeepsIntentTest=init.then(prepare).then(setter).then(crash).then(restart)
    .expect(safe and s.pending==0 and s.config==1).then(prepare.fail())
  run restartCannotFinishUnknownEditTest=init.then(prepare).then(setter).then(crash)
    .then(restart).then(finish.fail())
  run unknownRecordRefusesPreparationTest=init.then(unknownRecord).then(prepare.fail())
  run unknownFinalWriteRetainsIntentTest=init.then(prepare).then(setter).then(unknownRecord)
    .expect(s.pending==0 and s.commits==0 and safe).then(finish.fail())
  run changedOwnershipRefusesFinishTest=init.then(prepare).then(setter)
    .then(externalOwnershipChange).expect(s.pending==0 and safe).then(finish.fail())
  run noDuplicateSetterTest=init.then(prepare).then(setter).then(setter.fail())
  run forgettingIntentCounterexampleTest=init.then(prepare).then(forgetPending).expect(not(safe))
}

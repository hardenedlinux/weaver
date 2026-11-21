// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Weaver owns this state; stock Magpie is an external protocol consumer.
module ConnectionConfiguration {
  type Intent={expected:int,profile:int,decision:int,revision:int}
  type Write={expected:int,before:int,after:int}
  type S={revision:int,profile:int,head:int,intents:int -> Intent,
    original:int -> Intent,writes:List[Write],leases:int,leasedRevision:int,live:bool}
  var s:S
  val cas=s.writes.indices().forall(i=>{
    val w=s.writes.nth(i)
    w.expected==w.before and w.after==w.before+1
  })
  val bound=s.intents.keys().forall(i=>s.intents.get(i).expected==s.original.get(i).expected
    and s.intents.get(i).profile==s.original.get(i).profile)
  val headBound=s.head== -1 or (s.intents.get(s.head).decision==1
    and s.intents.get(s.head).revision==s.revision and s.intents.get(s.head).profile==s.profile)
  val leased=s.leases==0 or (s.leasedRevision==s.revision and s.profile>0)
  val safe=cas and bound and headBound and leased
  action init=s'={revision:-1,profile:0,head:-1,intents:Map(),original:Map(),writes:List(),leases:0,leasedRevision:-1,live:true}
  action prepare(i:int,expected:int,profile:int):bool=all {
    s.live,not(s.intents.keys().contains(i)),
    val intent={expected:expected,profile:profile,decision:0,revision:-1}
    s'=s.with("intents",s.intents.put(i,intent)).with("original",s.original.put(i,intent))
  }
  action publish(i:int):bool=all {
    s.live,s.intents.keys().contains(i),s.intents.get(i).decision==0,
    val op=s.intents.get(i)
    if(op.expected==s.revision) all {s.leases==0,
      s'=s.with("revision",s.revision+1).with("profile",op.profile).with("head",i)
        .with("intents",s.intents.put(i,op.with("decision",1).with("revision",s.revision+1)))
        .with("writes",s.writes.append({expected:op.expected,before:s.revision,after:s.revision+1}))}
    else s'=s.with("intents",s.intents.put(i,op.with("decision",2).with("revision",s.revision)))
  }
  action abort(i:int):bool=all {s.live,s.intents.keys().contains(i),s.intents.get(i).decision==0,
    s'=s.with("intents",s.intents.put(i,s.intents.get(i).with("decision",3).with("revision",s.revision)))}
  action lease=all {s.live,s.profile>0,s.leases<4,
    s'=s.with("leases",s.leases+1).with("leasedRevision",s.revision)}
  action release=all {s.live,s.leases>0,s'=s.with("leases",s.leases-1)}
  // Process-local custody disappears; durable intents/heads/decisions do not.
  action crash=s'=s.with("live",false).with("leases",0)
  action restart=s'=s.with("live",true)
  action retry(i:int):bool=all {s.live,s.intents.keys().contains(i),s.intents.get(i).decision!=0,s'=s}
  action observe=s'=s
  action step={nondet i=0.to(3).oneOf()
    any {prepare(i,s.revision,1),prepare(i,-1,2),prepare(i,s.revision,0),publish(i),abort(i),retry(i),lease,release,crash,restart,observe}}
  // Competing implementations, deliberately excluded from the safe schedule.
  action replayAsHead(i:int):bool=all {s.intents.keys().contains(i),s.intents.get(i).decision==1,
    s'=s.with("head",i).with("profile",s.intents.get(i).profile)}
  action splitHead(i:int):bool=all {s.intents.keys().contains(i),
    s'=s.with("head",i).with("revision",s.revision+1).with("profile",s.intents.get(i).profile)}
  action rebase(i:int):bool=all {s.intents.keys().contains(i),
    s'=s.with("intents",s.intents.put(i,s.intents.get(i).with("expected",s.revision)))}
  action ignoreLease(i:int):bool=all {s.leases>0,s.intents.keys().contains(i),
    val op=s.intents.get(i)
    all {op.expected==s.revision,
    s'=s.with("revision",s.revision+1).with("profile",op.profile).with("head",i)
      .with("intents",s.intents.put(i,op.with("decision",1).with("revision",s.revision+1)))
      .with("writes",s.writes.append({expected:op.expected,before:s.revision,after:s.revision+1}))}}
  run fourContendersHaveOneCommitTest=init.then(prepare(0,-1,1)).then(prepare(1,-1,2))
    .then(prepare(2,-1,1)).then(prepare(3,-1,2)).then(publish(2)).then(publish(0))
    .then(publish(1)).then(publish(3)).expect(safe and s.revision==0 and s.head==2)
  run retirementKeepsABAVersionTest=init.then(prepare(0,-1,1)).then(publish(0))
    .then(prepare(1,0,0)).then(publish(1)).then(prepare(2,1,1)).then(publish(2))
    .then(retry(0)).expect(safe and s.revision==2 and s.head==2)
  run oldReceiptActivationCounterexampleTest=init.then(prepare(0,-1,1)).then(publish(0))
    .then(prepare(1,0,2)).then(publish(1)).then(replayAsHead(0)).expect(not(safe))
  run splitDecisionCounterexampleTest=init.then(prepare(0,-1,1)).then(splitHead(0)).expect(not(safe))
  run rebasedRetryCounterexampleTest=init.then(prepare(0,-1,1)).then(publish(0))
    .then(prepare(1,-1,2)).then(rebase(1)).expect(not(safe))
  run liveListenerFencesPublicationTest=init.then(prepare(0,-1,1)).then(publish(0)).then(lease)
    .then(prepare(1,0,2)).expect(safe and s.leases==1).then(crash).then(restart)
    .then(publish(1)).expect(safe and s.revision==1 and s.leases==0)
  run heldLeaseRejectsPublicationTest=init.then(prepare(0,-1,1)).then(publish(0)).then(lease)
    .then(prepare(1,0,2)).then(publish(1).fail())
  run unlockedActivationCounterexampleTest=init.then(prepare(0,-1,1)).then(publish(0)).then(lease)
    .then(prepare(1,0,2)).then(ignoreLease(1)).expect(cas and bound and headBound and not(leased))
  run preparedIntentSurvivesCrashTest=init.then(prepare(0,-1,1)).then(crash).then(restart)
    .then(publish(0)).then(crash).then(restart).then(retry(0)).expect(safe and s.revision==0)
  run abortedIntentCannotPublishTest=init.then(prepare(0,-1,1)).then(abort(0))
    .then(retry(0)).expect(safe and s.revision== -1).then(publish(0).fail())
}

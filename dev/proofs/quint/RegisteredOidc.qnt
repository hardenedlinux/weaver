// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module RegisteredOidc {
  // Share the pure identity predicate, without importing supplier transitions.
  import OpenAiLogin.Identity from "./OpenAiLogin"
  import OpenAiLogin.bound from "./OpenAiLogin"
  import OpenAiLogin.good from "./OpenAiLogin"
  type Receipt = {identity:Identity,subject:int,nonce:int,at:int,deadline:int}
  type Session = {client:int,resource:int,subject:int,generation:int,attempt:int,
    pending:bool,cut:int,status:int,durable:int,clock:int,deadline:int,receipts:List[Receipt]}
  var s:Session
  pure val initial = {client:1,resource:0,subject:-1,generation:0,attempt:-1,
    pending:false,cut:-1,status:0,durable:0,clock:0,deadline:0,receipts:[]}
  action init = s'=initial
  action begin = all {not(s.pending),s'=s.with("generation",s.generation+1)
    .with("attempt",s.generation+1).with("deadline",s.clock+2)}
  action consume = all {s.attempt==s.generation,not(s.pending),s.clock<s.deadline,
    s'=s.with("attempt",-1).with("pending",true).with("cut",s.generation)
      .with("status",2).with("durable",2)}
  action activate(identity:Identity):bool = all {s.pending,s.cut==s.generation,s.clock<s.deadline,
    bound(identity,s.client,s.generation,identity.subject),
    s.subject == -1 or identity.subject==s.subject,
    s'=s.with("subject",identity.subject).with("pending",false).with("status",1).with("durable",1)
      .with("receipts",s.receipts.append({identity:identity,subject:identity.subject,
        nonce:s.generation,at:s.clock,deadline:s.deadline}))}
  action checkRecord(client:int,resource:int):bool = all {client==s.client,resource==s.resource,s'=s}
  action cancel = s'=s.with("pending",false).with("attempt",-1).with("cut",-1)
  action restart = s'=s.with("status",s.durable).with("pending",false).with("attempt",-1).with("cut",-1)
  action logout = s'=s.with("generation",s.generation+1).with("status",0).with("durable",0)
    .with("pending",false).with("attempt",-1).with("cut",-1)
  action tick = s'=s.with("clock",s.clock+1)
  action unsafeReplaceClient = s'=s.with("client",2)
  action unsafeActivate = s'=s.with("receipts",s.receipts.append(
    {identity:good(2,99,2),subject:2,nonce:s.generation,at:s.clock,deadline:s.deadline}))
  val safety = s.client==1 and s.resource==0 and s.receipts.indices().forall(i=>{
    val r=s.receipts.nth(i)
    bound(r.identity,s.client,r.nonce,r.subject) and r.subject==s.subject and r.at<r.deadline
  }) and (s.status==2 implies s.durable==2)
  action step = any {begin,consume,activate(good(1,s.generation,1)),
    activate(good(1,s.generation,2)),checkRecord(1,0),checkRecord(2,0),checkRecord(1,1),
    cancel,restart,logout,tick}
  action ready = init.then(begin).then(consume).then(activate(good(1,1,1)))
  run clientIsFixedBeforeBrowserLoginTest = init.then(begin).then(checkRecord(2,0).fail())
  run resourceCannotRebindSavedIdentityTest = ready.then(restart).then(checkRecord(1,1).fail())
  run restartRetainsSelectedAccountTest = ready.then(restart).expect(s.subject==1 and s.client==1 and safety)
  run logoutDoesNotSelectAnotherAccountTest = ready.then(logout).then(restart).then(begin).then(consume)
    .then(activate(good(1,3,2)).fail())
  run cancellationCannotReplayCodeTest = init.then(begin).then(consume).then(cancel).then(restart)
    .then(consume.fail())
  run logoutRejectsLateCallbackTest = init.then(begin).then(consume).then(logout)
    .then(activate(good(1,1,1)).fail())
  run sharedIdentityVerifierRejectsWrongAudienceTest = init.then(begin).then(consume)
    .then(activate(good(2,1,1)).fail())
  run sharedIdentityVerifierRejectsWrongNonceTest = init.then(begin).then(consume)
    .then(activate(good(1,2,1)).fail())
  run originalDeadlineIncludesVerificationTest = init.then(begin).then(consume).then(tick).then(tick)
    .then(activate(good(1,1,1)).fail())
  run clientReplacementCounterexampleTest = ready.then(unsafeReplaceClient).expect(not(safety))
  run unverifiedIdentityCounterexampleTest = init.then(begin).then(consume).then(unsafeActivate)
    .expect(not(safety))
}

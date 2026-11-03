// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmIncarnationIssuance {
  import LlmCallerCustody as C from "./LlmCallerCustody"
  import LlmCustodyPublication.pub from "./LlmCustodyPublication"
  import LlmSourceCustody.custody from "./LlmSourceCustody"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  type Ticket={id:int,launch:int,parent:int,epoch:int,challenge:int,session:int,audience:int,purpose:int,root:int,previous:C::Grant,target:C::Grant}
  type Registry={tickets:List[Ticket],issued:Set[int],launches:Set[int],proofs:Set[int],proofTickets:List[Ticket],outcomes:Set[int],reserved:Set[int],challenge:int,epoch:int,revision:int,seen:int,reply:int,haveReply:bool,checked:bool}
  var registry:Registry
  pure val target=C::first.with("serial",1).with("inc",1).with("key",200).with("holder",1).with("fence",1)
  pure val ticket={id:0,launch:17,parent:1,epoch:0,challenge:0,session:51,audience:7,purpose:1,root:12,previous:C::first,target:target}
  pure val ticket2=ticket.with("id",1).with("launch",18).with("challenge",1).with("session",52).with("target",target.with("inc",2).with("key",300).with("holder",2))
  pure val initial={tickets:List(ticket,ticket2),issued:Set(),launches:Set(),proofs:Set(),proofTickets:List(ticket,ticket2),outcomes:Set(),reserved:Set(0),challenge:0,epoch:0,revision:0,seen:-1,reply:0,haveReply:false,checked:true}
  // Bootstrap proves a key and channel, not a pre-existing new incarnation.
  pure def bootstrap(ch) = if(ch==1) {workload:9,key:200,session:51}
    else if(ch==4) {workload:9,key:300,session:52} else {workload:9,key:100,session:50}
  def exact(t)=registry.issued.contains(t.id) and registry.tickets.nth(t.id)==t
  def current(t)=exact(t) and t.previous==C::auth.grant and t.parent==pub.log.length() and t.epoch==registry.epoch and t.audience==t.target.domain and t.purpose==1 and t.root==custody.original.intent and C::auth.now<t.target.expires
  def possession(ch,t,verified)=Set(0,1,2,4).contains(ch) and verified and bootstrap(ch).workload==t.target.workload and bootstrap(ch).key==t.target.key and bootstrap(ch).session==t.session
  def canActivate(ch,t)=current(t) and possession(ch,t,true) and registry.proofs.contains(t.id) and registry.proofTickets.nth(t.id)==t and not(registry.outcomes.contains(t.id)) and registry.seen==registry.revision
  def originalScope(g)=g.domain==C::auth.grant.domain and g.workload==C::auth.grant.workload and g.expires==C::auth.grant.expires and g.purpose==C::auth.grant.purpose
  val invariant=C::invariant and registry.checked and registry.outcomes.subseteq(registry.proofs) and registry.proofs.subseteq(registry.issued) and registry.proofs.forall(id=>registry.proofTickets.nth(id)==registry.tickets.nth(id)) and registry.reserved.contains(C::auth.grant.inc) and registry.issued.forall(id=>registry.launches.contains(registry.tickets.nth(id).launch))
  action idle=all {C::idle,C::auth'=C::auth}
  action boot=all {C::boot,registry'=initial}
  // approved and assigned are trusted native/Cedar outcomes, never client booleans.
  def assignment(t)=(t.launch==17 and t.target.inc==1 and t.target.key==200 and t.session==51) or (t.launch==18 and t.target.inc==2 and t.target.key==300 and t.session==52)
  action issue(ch,t,approved,assigned,deliver)=all {Set(0,1).contains(t.id),C::peer(ch).recovery,approved,assigned,assignment(t),
    not(registry.issued.contains(t.id)),not(registry.launches.contains(t.launch)),not(registry.reserved.contains(t.target.inc)),not(C::auth.used.contains(t.target.inc)),
    t.previous==C::auth.grant,t.parent==pub.log.length(),t.epoch==registry.epoch,t.challenge==registry.challenge,t.audience==t.target.domain,t.purpose==1,t.root==custody.original.intent,
    originalScope(t.target),t.target.serial==C::auth.grant.serial+1,t.target.fence==C::auth.grant.fence+1,C::auth.now<t.target.expires,
    idle,registry'=registry.with("tickets",registry.tickets.replaceAt(t.id,t)).with("issued",registry.issued.union(Set(t.id))).with("launches",registry.launches.union(Set(t.launch))).with("reserved",registry.reserved.union(Set(t.target.inc))).with("challenge",registry.challenge+1).with("revision",registry.revision+1).with("seen",-1).with("reply",t.id).with("haveReply",deliver)}
  action prove(ch,t,verified)=all {current(t),possession(ch,t,verified),not(registry.proofs.contains(t.id)),idle,registry'=registry.with("proofs",registry.proofs.union(Set(t.id))).with("proofTickets",registry.proofTickets.replaceAt(t.id,t)).with("revision",registry.revision+1).with("seen",-1)}
  action read=all {idle,registry'=registry.with("seen",registry.revision)}
  action redeliver(ch,t)=all {exact(t),possession(ch,t,true),idle,registry'=registry.with("reply",t.id).with("haveReply",true)}
  action lookup(ch,launch,allowed)={val id=if(launch==17) 0 else 1
    all {C::peer(ch).recovery,allowed,registry.launches.contains(launch),registry.issued.contains(id),registry.tickets.nth(id).launch==launch,idle,registry'=registry.with("reply",id).with("haveReply",true)}}
  action readCustody=all {C::read,registry'=registry.with("revision",registry.revision+1).with("seen",-1)}
  action stage(t)=all {C::stage(1,1,t.target.holder,C::auth.grant.fence),registry'=registry.with("revision",registry.revision+1).with("seen",-1)}
  action prepare(t)=readCustody.then(stage(t))
  action activate(ch,t,deliver)=all {canActivate(ch,t),C::handoff(9,true,true,t.target.inc,t.target.key,t.target.holder,1,deliver),registry'=registry.with("outcomes",registry.outcomes.union(Set(t.id))).with("revision",registry.revision+1).with("seen",-1).with("reply",t.id).with("haveReply",deliver)}
  action revoke=all {idle,registry'=registry.with("epoch",registry.epoch+1).with("revision",registry.revision+1).with("seen",-1)}
  action crash=all {C::crash,registry'=registry.with("revision",registry.revision+1).with("seen",-1).with("haveReply",false)}
  action sourceStage=all {C::stage(0,0,0,0),registry'=registry.with("revision",registry.revision+1).with("seen",-1)}
  action sourceCommit=all {C::publish(0,C::first,0,false),registry'=registry.with("revision",registry.revision+1).with("seen",-1)}
  action sourceMove=readCustody.then(sourceStage).then(sourceCommit)
  action issued=boot.then(issue(9,ticket,true,true,false))
  action proven=issued.then(prove(1,ticket,true))
  action ready=proven.then(prepare(ticket)).then(read)
  action activated=ready.then(activate(1,ticket,false))
  action competing=proven.then(issue(9,ticket2,true,true,false)).then(prove(4,ticket2,true))
  action moved=proven.then(sourceMove)
  action revoked=ready.then(revoke)
  action step={nondet ch=Set(0,1,4,9).oneOf()
    nondet t=Set(ticket,ticket2).oneOf()
    any {lookup(ch,t.launch,true),issue(ch,t,true,true,false),prove(ch,t,true),read,redeliver(ch,t),prepare(t),activate(ch,t,false),revoke,crash}}
  run issueDoesNotActivateCustodyTest=issued.expect(invariant and C::auth.grant==C::first and f.log.length()==1 and not(registry.haveReply))
  run sharedWorkloadCannotIssueTest=boot.then(issue(0,ticket,true,true,true).fail())
  run independentLaunchApprovalRequiredTest=boot.then(issue(9,ticket,false,true,true).fail())
  run assignedKeyRequiredTest=boot.then(issue(9,ticket,true,false,true).fail())
  run lostIssueReplySameLaunchCannotRemintTest=issued.then(issue(9,ticket.with("id",1).with("challenge",1).with("target",ticket2.target),true,true,true).fail())
  run reservedIncarnationCannotReissueTest=issued.then(issue(9,ticket.with("id",1).with("launch",18).with("challenge",1),true,true,true).fail())
  run selfSelectedOldKeyCannotIssueTest=boot.then(issue(9,ticket.with("target",target.with("key",100)).with("session",50),true,true,true).fail())
  run lostIssueReplyRecoveredByLaunchLookupTest=issued.then(lookup(9,17,true)).expect(invariant and registry.reply==0 and registry.haveReply and registry.seen!=registry.revision and C::auth.grant==C::first)
  run sharedWorkloadCannotLookupNewLaunchTest=issued.then(lookup(0,17,true).fail())
  run launchLookupNeedsCurrentReadPolicyTest=issued.then(lookup(9,17,false).fail())
  run oldWorkerCannotProveNewKeyTest=issued.then(prove(0,ticket,true).fail())
  run invalidSignatureRejectedTest=issued.then(prove(1,ticket,false).fail())
  run substitutedKeyRejectedTest=issued.then(prove(0,ticket.with("target",target.with("key",100)),true).fail())
  run wrongTranscriptChallengeRejectedTest=issued.then(prove(1,ticket.with("challenge",1),true).fail())
  run wrongFutureIncarnationRejectedTest=issued.then(prove(1,ticket.with("target",target.with("inc",2)),true).fail())
  run wrongBootstrapSessionRejectedTest=issued.then(prove(1,ticket.with("session",50),true).fail())
  run proofWithoutActivationHasNoGrantTest=proven.expect(invariant and C::auth.grant==C::first and f.log.length()==1)
  run issuedWithoutProofCannotActivateTest=issued.then(prepare(ticket)).then(read).then(activate(1,ticket,true).fail())
  run currentBootstrapActivatesOriginalTest=activated.expect(invariant and C::auth.grant==target and registry.outcomes.contains(0) and f.log.length()==1)
  run lostActivationReplyCannotRepeatTest=activated.then(crash).then(read).then(activate(1,ticket,true).fail())
  run oldWorkerCannotCollectNewTicketTest=issued.then(redeliver(0,ticket).fail())
  run redeliveryDoesNotRefreshActivationReadTest=proven.then(redeliver(1,ticket)).expect(invariant and registry.seen!=registry.revision and C::auth.grant==C::first)
  run issuerEpochChangeRejectsQueuedActivationTest=revoked.then(read).then(activate(1,ticket,true).fail())
  run sourcePublicationRejectsOldIssueParentTest=moved.then(prepare(ticket)).then(read).then(activate(1,ticket,true).fail())
  run twoLaunchesCannotBothUseOldParentTest=competing.then(prepare(ticket)).then(read).then(activate(1,ticket,false)).then(prepare(ticket2)).then(read).then(activate(4,ticket2,true).fail())
  // Faults below are outside the guarded transition relation.
  action unsafeActivate(ch,t)=all {not(canActivate(ch,t)),C::handoff(9,true,true,t.target.inc,t.target.key,t.target.holder,1,false),registry'=registry.with("outcomes",registry.outcomes.union(Set(t.id))).with("checked",false)}
  action replaceTicket=all {idle,registry'=registry.with("tickets",registry.tickets.replaceAt(0,ticket.with("target",target.with("key",100)))).with("checked",false)}
  action eraseIssue=all {idle,registry'=registry.with("issued",Set()).with("launches",Set()).with("reserved",Set(0))}
  action eraseOutcome=all {idle,registry'=registry.with("outcomes",Set()).with("checked",false)}
  run sharedIdentityIssuanceCounterexampleTest=ready.then(unsafeActivate(0,ticket)).expect(not(invariant) and C::auth.grant.inc==1 and f.log.length()==1)
  run noProofIssuanceCounterexampleTest=issued.then(prepare(ticket)).then(read).then(unsafeActivate(1,ticket)).expect(not(invariant) and registry.outcomes.contains(0) and not(registry.proofs.contains(0)))
  run revokedProofIssuanceCounterexampleTest=revoked.then(read).then(unsafeActivate(1,ticket)).expect(not(invariant) and registry.epoch==1 and C::auth.grant.inc==1)
  run keySubstitutionIssuanceCounterexampleTest=issued.then(replaceTicket).expect(not(invariant) and registry.tickets.nth(0).target.key==100)
  run rollbackIssueIssuanceCounterexampleTest=proven.then(eraseIssue).expect(not(invariant) and registry.proofs.contains(0) and not(registry.issued.contains(0)))
  run lostActivationResultIssuanceCounterexampleTest=activated.then(eraseOutcome).expect(not(invariant) and C::auth.grant==target and not(registry.outcomes.contains(0)))
}

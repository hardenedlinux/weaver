// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmEnrollmentCredential {
  import LlmBeneficiaryRegistration as B from "./LlmBeneficiaryRegistration"
  import LlmIncarnationIssuance as I from "./LlmIncarnationIssuance"
  import LlmCallerCustody.auth from "./LlmCallerCustody"
  import LlmAccountCommit.a from "./LlmAccountCommit"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  type Plan={root:B::Root,subject:int,subjectKey:int,session:int,challenge:int,audience:int,purpose:int}
  type Peer={subject:int,subjectKey:int,enrollmentKey:int,session:int,challenge:int,credentialId:int}
  type Credential={plan:Plan,id:int,epoch:int,peer:Peer}
  type Ledger={plans:Set[int],planRows:List[Plan],credentials:Set[int],rows:List[Credential],ids:Set[int],owners:int->int,requested:Set[int],released:Set[int],activated:Set[int],epoch:int,nextId:int,revision:int,seen:int,reply:bool}
  var ledger:Ledger
  pure val plan:Plan={root:B::root,subject:401,subjectKey:700,session:81,challenge:91,audience:7,purpose:2}
  pure val plan2:Plan={root:B::root2,subject:402,subjectKey:800,session:82,challenge:92,audience:7,purpose:2}
  pure def peer(ch:int):Peer=if(ch==1) {subject:401,subjectKey:700,enrollmentKey:500,session:81,challenge:91,credentialId:101}
    else if(ch==2) {subject:402,subjectKey:800,enrollmentKey:600,session:82,challenge:92,credentialId:102}
    else if(ch==3) {subject:401,subjectKey:100,enrollmentKey:501,session:81,challenge:91,credentialId:101}
    else if(ch==4) {subject:401,subjectKey:700,enrollmentKey:501,session:81,challenge:91,credentialId:101}
    else if(ch==5) {subject:401,subjectKey:700,enrollmentKey:500,session:83,challenge:91,credentialId:101}
    else {subject:9,subjectKey:100,enrollmentKey:100,session:80,challenge:90,credentialId:100}
  pure val credential:Credential={plan:plan,id:101,epoch:0,peer:peer(1)}
  pure val credential2:Credential={plan:plan2,id:102,epoch:0,peer:peer(2)}
  pure val initial:Ledger={plans:Set(),planRows:List(plan,plan2),credentials:Set(),rows:List(credential,credential2),ids:Set(),owners:Map(101-> -1,102-> -1),requested:Set(),released:Set(),activated:Set(),epoch:0,nextId:101,revision:0,seen:-1,reply:false}
  pure def issueBinding(c:Credential):bool=c.peer.subject==c.plan.subject and c.peer.subjectKey==c.plan.subjectKey and c.peer.enrollmentKey==c.plan.root.enrollmentKey and c.peer.session==c.plan.session and c.peer.challenge==c.plan.challenge and c.peer.credentialId==c.id
  val valid:bool=ledger.credentials.forall(k=>{val c=ledger.rows.nth(k)
    ledger.plans.contains(k) and ledger.planRows.nth(k)==c.plan and c.plan.root.template.id==k and issueBinding(c) and ledger.ids.contains(c.id) and ledger.owners.get(c.id)==k and c.id<ledger.nextId})
  val joins:bool=ledger.requested.subseteq(ledger.credentials) and ledger.released.subseteq(ledger.requested) and ledger.activated==B::enrollment.roots and ledger.activated.subseteq(ledger.released) and ledger.activated.forall(k=>B::enrollment.rootRows.nth(k)==ledger.rows.nth(k).plan.root)
  val invariant:bool=B::invariant and valid and joins
  def current(c:Credential,approved:bool):bool={val k=c.plan.root.template.id
    ledger.credentials.contains(k) and ledger.rows.nth(k)==c and c.epoch==ledger.epoch and c.plan.root.epoch==B::enrollment.epoch and B::blueprint(c.plan.root.template) and ledger.seen==ledger.revision and approved and invariant}
  action idle:bool=all {B::idle,B::enrollment'=B::enrollment}
  action boot:bool=all {B::boot,ledger'=initial}
  // Producer assignment is a native authenticated fact, independent of shared workload eligibility.
  action registerPlan(ch:int,p:Plan,approved:bool):bool=all {ch==9,approved,Set(plan,plan2).contains(p),not(ledger.plans.contains(p.root.template.id)),p.root.epoch==B::enrollment.epoch,idle,ledger'=ledger.with("plans",ledger.plans.union(Set(p.root.template.id))).with("planRows",ledger.planRows.replaceAt(p.root.template.id,p)).with("revision",ledger.revision+1).with("seen",-1)}
  action read:bool=all {invariant,idle,ledger'=ledger.with("seen",ledger.revision)}
  action issue(ch:int,c:Credential,subjectAuth:bool,keyProof:bool,approved:bool,deliver:bool):bool={val k=c.plan.root.template.id
    all {invariant,ledger.plans.contains(k),ledger.planRows.nth(k)==c.plan,not(ledger.credentials.contains(k)),c.id==ledger.nextId,not(ledger.ids.contains(c.id)),c.epoch==ledger.epoch,c.plan.root.epoch==B::enrollment.epoch,B::blueprint(c.plan.root.template),ledger.seen==ledger.revision,approved,subjectAuth,keyProof,c.peer==peer(ch),issueBinding(c),idle,ledger'=ledger.with("credentials",ledger.credentials.union(Set(k))).with("rows",ledger.rows.replaceAt(k,c)).with("ids",ledger.ids.union(Set(c.id))).with("owners",ledger.owners.set(c.id,k)).with("nextId",ledger.nextId+1).with("revision",ledger.revision+1).with("seen",-1).with("reply",deliver)}}
  action request(c:Credential):bool={val k=c.plan.root.template.id
    all {current(c,true),not(ledger.requested.contains(k)),idle,ledger'=ledger.with("requested",ledger.requested.union(Set(k))).with("revision",ledger.revision+1).with("seen",-1)}}
  action release(c:Credential,signature:bool):bool={val k=c.plan.root.template.id
    all {current(c,true),ledger.requested.contains(k),not(ledger.released.contains(k)),signature,idle,ledger'=ledger.with("released",ledger.released.union(Set(k))).with("revision",ledger.revision+1).with("seen",-1)}}
  // A fresh holder transcript uses the bootstrap channel, never the issuance channel.
  action activateRoot(ch:int,c:Credential,possession:bool,approved:bool):bool={val k=c.plan.root.template.id
    all {current(c,approved),ledger.released.contains(k),not(ledger.activated.contains(k)),possession,peer(ch).subject==c.plan.subject,peer(ch).enrollmentKey==c.plan.root.enrollmentKey,if(ch==1) c.plan.root.template.session==51 else if(ch==2) c.plan.root.template.session==52 else false,B::registerRoot(9,c.plan.root,true,false),ledger'=ledger.with("activated",ledger.activated.union(Set(k))).with("revision",ledger.revision+1).with("seen",-1)}}
  // Current subject read authorization can recover over a new connection; it adds no freshness.
  action recover(ch:int,k:int,subjectAuth:bool,readPolicy:bool):bool=all {ledger.plans.contains(k),subjectAuth,readPolicy,peer(ch).subject==ledger.planRows.nth(k).subject,peer(ch).subjectKey==ledger.planRows.nth(k).subjectKey,idle,ledger'=ledger.with("reply",true)}
  action crash:bool=all {B::crash,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1).with("reply",false)}
  action revoke:bool=all {B::revoke,ledger'=ledger.with("epoch",ledger.epoch+1).with("revision",ledger.revision+1).with("seen",-1)}
  action readBinding:bool=all {invariant,B::read,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action bind:bool=all {invariant,B::bindKey(1,I::ticket,true,true,false),ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action readPublication:bool=all {invariant,B::read,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action publish:bool=all {invariant,B::publish(I::ticket,true,false),ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action readInvitation:bool=all {invariant,B::readInvitation,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action consume:bool=all {invariant,B::consume,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action prove:bool=all {invariant,B::prove,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action readCustody:bool=all {invariant,B::readCustody,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action stage:bool=all {invariant,B::stage,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action readActivation:bool=all {invariant,B::readActivation,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action activate:bool=all {invariant,B::activate,ledger'=ledger.with("revision",ledger.revision+1).with("seen",-1)}
  action planned:bool=boot.then(registerPlan(9,plan,true))
  action ready:bool=planned.then(read)
  action issued:bool=ready.then(issue(1,credential,true,true,true,false))
  action requested:bool=issued.then(read).then(request(credential))
  action released:bool=requested.then(read).then(release(credential,true))
  action rooted:bool=released.then(read).then(activateRoot(1,credential,true,true))
  action bound:bool=rooted.then(readBinding).then(bind)
  action published:bool=bound.then(readPublication).then(publish)
  action activated:bool=published.then(readInvitation).then(consume).then(prove).then(readCustody).then(stage).then(readActivation).then(activate)
  action step:bool=any {registerPlan(9,plan,true),read,issue(1,credential,true,true,true,false),request(credential),release(credential,true),activateRoot(1,credential,true,true),recover(1,0,true,true),crash,revoke,readBinding,bind,readPublication,publish,readInvitation,consume,prove,readCustody,stage,readActivation,activate}
  run sharedWorkloadCannotAssignSubjectTest=boot.then(registerPlan(0,plan,true).fail())
  run producerAssignmentRequiredTest=boot.then(registerPlan(9,plan,false).fail())
  run sharedWorkloadCannotIssueTest=ready.then(issue(0,credential.with("peer",peer(0)),true,true,true,true).fail())
  run forwardedSubjectCredentialRejectedTest=ready.then(issue(3,credential.with("peer",peer(3)),true,true,true,true).fail())
  run authenticatedSubjectCannotNominateKeyTest=ready.then(issue(4,credential.with("peer",peer(4)),true,true,true,true).fail())
  run subjectAuthenticationRequiredTest=ready.then(issue(1,credential,false,true,true,true).fail())
  run enrollmentPossessionRequiredTest=ready.then(issue(1,credential,true,false,true,true).fail())
  run issuanceSessionBoundTest=ready.then(issue(5,credential.with("peer",peer(5)),true,true,true,true).fail())
  run currentIssuancePolicyRequiredTest=ready.then(issue(1,credential,true,true,false,true).fail())
  run commitDoesNotSignOrEnrollTest=issued.expect(invariant and ledger.requested==Set() and ledger.released==Set() and B::enrollment.roots==Set() and B::enrollment.bindings==Set() and auth.grant.inc==0 and a.anchor.holds.get(12)==2)
  run lostIssueReplyRecoversSameCredentialTest=issued.then(crash).then(recover(5,0,true,true)).expect(invariant and ledger.rows.nth(0)==credential and ledger.ids==Set(101) and ledger.nextId==102 and ledger.seen!=ledger.revision and ledger.reply)
  run oldWorkerCannotRecoverSubjectTest=issued.then(recover(0,0,true,true).fail())
  run recoveryAuthenticationRequiredTest=issued.then(recover(1,0,false,true).fail())
  run recoveryPolicyRequiredTest=issued.then(recover(1,0,true,false).fail())
  run canonicalLaunchCannotReissueTest=issued.then(crash).then(read).then(issue(1,credential,true,true,true,true).fail())
  run crossLaunchIdCannotBeReusedTest=issued.then(registerPlan(9,plan2,true)).then(read).then(issue(2,credential2.with("id",101),true,true,true,true).fail())
  run secondSubjectGetsDistinctIdTest=issued.then(registerPlan(9,plan2,true)).then(read).then(issue(2,credential2,true,true,true,false)).expect(invariant and ledger.ids==Set(101,102) and ledger.owners.get(101)==0 and ledger.owners.get(102)==1)
  run uncommittedBodyCannotReachSignerTest=ready.then(request(credential).fail())
  run signatureWithoutRequestRejectedTest=issued.then(read).then(release(credential,true).fail())
  run lostSignerReplyRetainsExactIntentTest=requested.then(crash).then(recover(5,0,true,true)).then(read).then(release(credential,true)).expect(invariant and ledger.rows.nth(0)==credential and ledger.released==Set(0) and ledger.ids==Set(101))
  run wrongBodyCallbackRejectedTest=requested.then(read).then(release(credential.with("plan",plan.with("subject",9)),true).fail())
  run authenticSignatureRequiredTest=requested.then(read).then(release(credential,false).fail())
  run lateCallbackAfterRevocationRejectedTest=requested.then(revoke).then(read).then(release(credential,true).fail())
  run interveningCommitInvalidatesReadTest=requested.then(read).then(registerPlan(9,plan2,true)).then(release(credential,true).fail())
  run releasedCredentialStillNeedsHolderTest=released.then(read).then(activateRoot(1,credential,false,true).fail())
  run forwardedCredentialCannotActivateTest=released.then(read).then(activateRoot(3,credential,true,true).fail())
  run recoveredConnectionCannotActivateTest=released.then(crash).then(recover(5,0,true,true)).then(read).then(activateRoot(5,credential,true,true).fail())
  run oldEpochCannotActivateTest=released.then(revoke).then(read).then(activateRoot(1,credential,true,true).fail())
  run activationNeedsCurrentPolicyTest=released.then(read).then(activateRoot(1,credential,true,false).fail())
  run rootActivationDoesNotBindBeneficiaryTest=rooted.expect(invariant and B::enrollment.roots==Set(0) and ledger.activated==Set(0) and B::enrollment.bindings==Set() and I::registry.issued==Set() and auth.grant.inc==0)
  run activationCannotRepeatTest=rooted.then(read).then(activateRoot(1,credential,true,true).fail())
  run recoveryCannotReplaceFirstKeyTest=bound.then(crash).then(recover(5,0,true,true)).then(readBinding).then(all {invariant,B::bindKey(3,I::ticket.with("target",I::target.with("key",201)),true,true,true),ledger'=ledger}.fail())
  run actualActivationPreservesOriginalBudgetTest=activated.expect(invariant and auth.grant.inc==1 and a.anchor.holds.get(12)==2 and not(a.anchor.used.contains(12)) and f.log.length()==1)
  run revocationFencesPublishedInvitationTest=published.then(revoke).then(readInvitation).then(consume.fail())
  // Fault injection is excluded from step: these expose native contracts that must not be omitted.
  action forgeSubject:bool=all {idle,ledger'=ledger.with("rows",ledger.rows.replaceAt(0,credential.with("peer",peer(3))))}
  action eraseCredential:bool=all {idle,ledger'=ledger.with("credentials",Set())}
  action eraseRelease:bool=all {idle,ledger'=ledger.with("released",Set())}
  action rootWithoutOutcome:bool=all {B::registerRoot(9,B::root,true,false),ledger'=ledger}
  action outcomeWithoutRoot:bool=all {idle,ledger'=ledger.with("activated",Set(0))}
  run forgedSubjectCounterexampleTest=issued.then(forgeSubject).expect(not(invariant) and ledger.rows.nth(0).peer.subjectKey==100)
  run erasedCredentialCounterexampleTest=rooted.then(eraseCredential).expect(not(invariant) and ledger.activated==Set(0) and ledger.credentials==Set())
  run erasedReleaseCounterexampleTest=rooted.then(eraseRelease).expect(not(invariant) and B::enrollment.roots==Set(0) and ledger.released==Set())
  run missingActivationOutcomeCounterexampleTest=released.then(rootWithoutOutcome).expect(not(invariant) and B::enrollment.roots==Set(0) and ledger.activated==Set())
  run phantomActivationOutcomeCounterexampleTest=released.then(outcomeWithoutRoot).expect(not(invariant) and B::enrollment.roots==Set() and ledger.activated==Set(0))
  run splitRecoveryCannotBindFirstKeyTest=released.then(rootWithoutOutcome).then(all {B::read,ledger'=ledger}).then(all {not(invariant),B::enrollment.seen==B::enrollment.revision,B::enrollment.bindings==Set(),auth.grant.inc==0,a.anchor.holds.get(12)==2,idle,ledger'=ledger}).then(bind.fail())
}

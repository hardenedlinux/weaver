// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmBootstrapInvitation {
  import LlmIncarnationIssuance as B from "./LlmIncarnationIssuance"
  import LlmCallerCustody.auth from "./LlmCallerCustody"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  import LlmAccountCommit.a from "./LlmAccountCommit"
  type Invitations={registered:Set[int],spent:Set[int],bindings:List[B::Ticket],results:List[B::Ticket],revision:int,seen:int,reply:bool,checked:bool}
  var invitations:Invitations
  pure val initial:Invitations={registered:Set(),spent:Set(),bindings:List(B::ticket,B::ticket2),results:List(B::ticket,B::ticket2),revision:0,seen:-1,reply:false,checked:true}
  val covered:bool=B::registry.issued.forall(id=>invitations.spent.contains(id) and invitations.results.nth(id)==B::registry.tickets.nth(id))
  val bound:bool=invitations.spent.forall(id=>invitations.registered.contains(id) and invitations.results.nth(id)==invitations.bindings.nth(id))
  val invariant:bool=B::invariant and invitations.checked and covered and bound and invitations.registered.forall(id=>B::assignment(invitations.bindings.nth(id)))
  action boot:bool=all {B::boot,invitations'=initial}
  action register(t:B::Ticket,approved:bool):bool=all {Set(0,1).contains(t.id),approved,B::assignment(t),not(invitations.registered.contains(t.id)),invitations.registered.forall(id=>invitations.bindings.nth(id).launch!=t.launch),B::idle,B::registry'=B::registry,invitations'=invitations.with("registered",invitations.registered.union(Set(t.id))).with("bindings",invitations.bindings.replaceAt(t.id,t)).with("revision",invitations.revision+1).with("seen",-1)}
  action read:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("seen",invitations.revision)}
  def ready(ch:int,t:B::Ticket,verified:bool):bool=invitations.registered.contains(t.id) and invitations.bindings.nth(t.id)==t and not(invitations.spent.contains(t.id)) and invitations.seen==invitations.revision and B::possession(ch,t,verified)
  // One authority event consumes the invitation and commits the exact pending issuance.
  action consume(ch:int,t:B::Ticket,verified:bool,deliver:bool):bool=all {ready(ch,t,verified),B::issue(9,t,true,true,false),invitations'=invitations.with("spent",invitations.spent.union(Set(t.id))).with("results",invitations.results.replaceAt(t.id,t)).with("revision",invitations.revision+1).with("seen",-1).with("reply",deliver)}
  // Recovery returns the old result; it does not create an issuance or grant freshness.
  action recover(ch:int,t:B::Ticket,allowed:bool):bool=all {invitations.spent.contains(t.id),invitations.results.nth(t.id)==t,allowed,B::possession(ch,t,true),B::idle,B::registry'=B::registry,invitations'=invitations.with("reply",true)}
  action prove(ch:int,t:B::Ticket):bool=all {B::prove(ch,t,true),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action readCustody:bool=all {B::readCustody,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action stage(t:B::Ticket):bool=all {B::stage(t),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action prepare(t:B::Ticket):bool=readCustody.then(stage(t))
  action readActivation:bool=all {B::read,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action activate(ch:int,t:B::Ticket):bool=all {B::activate(ch,t,false),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action revoke:bool=all {B::revoke,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action crash:bool=all {B::crash,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1).with("reply",false)}
  action registered:bool=boot.then(register(B::ticket,true))
  action readyState:bool=registered.then(read)
  action consumed:bool=readyState.then(consume(1,B::ticket,true,false))
  action activated:bool=consumed.then(prove(1,B::ticket)).then(prepare(B::ticket)).then(readActivation).then(activate(1,B::ticket))
  action competing:bool=registered.then(register(B::ticket2,true)).then(read)
  action step:bool={nondet ch=Set(0,1,4,9).oneOf()
    nondet t=Set(B::ticket,B::ticket2).oneOf()
    any {register(t,true),read,consume(ch,t,true,false),recover(ch,t,true),prove(ch,t),readCustody,stage(t),readActivation,activate(ch,t),revoke,crash}}
  run registrationDoesNotIssueTest=registered.expect(invariant and B::registry.issued==Set() and auth.grant.inc==0)
  run independentAssignmentRequiredTest=boot.then(register(B::ticket,false).fail())
  run selfSelectedKeyRejectedTest=boot.then(register(B::ticket.with("target",B::target.with("key",100)),true).fail())
  run duplicateCanonicalLaunchRejectedTest=registered.then(register(B::ticket2.with("launch",17),true).fail())
  run unregisteredInvitationRejectedTest=boot.then(read).then(consume(1,B::ticket,true,true).fail())
  run sharedKubernetesIdentityRejectedTest=readyState.then(consume(0,B::ticket,true,true).fail())
  run forwardedInvitationNoKeyRejectedTest=readyState.then(consume(0,B::ticket,true,true).fail())
  run invalidPossessionRejectedTest=readyState.then(consume(1,B::ticket,false,true).fail())
  run substitutedSessionRejectedTest=readyState.then(consume(1,B::ticket.with("session",50),true,true).fail())
  run exactBindingRequiredTest=readyState.then(consume(1,B::ticket.with("challenge",1),true,true).fail())
  run consumptionCommitsExactResultTest=consumed.expect(invariant and invitations.spent==Set(0) and invitations.results.nth(0)==B::ticket and B::registry.issued==Set(0) and auth.grant.inc==0 and not(invitations.reply))
  run lostReplyCannotConsumeTwiceTest=consumed.then(crash).then(read).then(consume(1,B::ticket,true,true).fail())
  run lostReplyRecoversSameResultTest=consumed.then(crash).then(recover(1,B::ticket,true)).expect(invariant and invitations.reply and B::registry.challenge==1 and invitations.seen!=invitations.revision)
  run oldWorkerCannotRecoverTest=consumed.then(recover(0,B::ticket,true).fail())
  run recoveryReadPolicyRequiredTest=consumed.then(recover(1,B::ticket,false).fail())
  run concurrentReadInvalidatedTest=readyState.then(register(B::ticket2,true)).then(consume(1,B::ticket,true,true).fail())
  run revokedEpochRejectedTest=readyState.then(revoke).then(read).then(consume(1,B::ticket,true,true).fail())
  run recoveryDoesNotReactivateTest=activated.then(crash).then(recover(1,B::ticket,true)).then(readActivation).then(activate(1,B::ticket).fail())
  run originalUnknownBudgetRetainedTest=activated.expect(invariant and f.log.length()==1 and auth.grant.inc==1 and a.anchor.holds.get(12)==2 and not(a.anchor.used.contains(12)))
  // Deliberately unsafe mutations, excluded from step. They expose broken contracts.
  action unsafeIssue:bool=all {B::issue(9,B::ticket,true,true,false),invitations'=invitations}
  action eraseResult:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set())}
  action consumeWithoutIssue:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set(0)).with("results",invitations.results.replaceAt(0,B::ticket2))}
  action replaceBinding:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("bindings",invitations.bindings.replaceAt(0,B::ticket2))}
  run bearerOnlyInvitationCounterexampleTest=readyState.then(unsafeIssue).expect(not(invariant) and B::registry.issued.contains(0) and not(invitations.spent.contains(0)) and auth.grant.inc==0)
  run lostConsumptionRecordInvitationCounterexampleTest=consumed.then(eraseResult).expect(not(invariant) and B::registry.issued.contains(0) and not(invitations.spent.contains(0)))
  run splitCommitInvitationCounterexampleTest=registered.then(consumeWithoutIssue).expect(not(invariant) and invitations.spent.contains(0) and B::registry.issued==Set())
  run replacedKeyBindingInvitationCounterexampleTest=consumed.then(replaceBinding).expect(not(invariant) and invitations.results.nth(0)!=invitations.bindings.nth(0))
}

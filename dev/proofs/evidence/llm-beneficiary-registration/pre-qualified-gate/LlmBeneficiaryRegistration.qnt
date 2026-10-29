module LlmBeneficiaryRegistration {
  import LlmBootstrapInvitation as P from "./LlmBootstrapInvitation"
  import LlmIncarnationIssuance as I from "./LlmIncarnationIssuance"
  import LlmCallerCustody.auth from "./LlmCallerCustody"
  import LlmCustodyPublication.pub from "./LlmCustodyPublication"
  import LlmAccountCommit.a from "./LlmAccountCommit"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  import LlmSourceCustody.custody from "./LlmSourceCustody"
  type Root={template:I::Ticket,enrollmentKey:int,epoch:int,challenge:int}
  type Peer={enrollmentKey:int,beneficiaryKey:int,workload:int,session:int,challenge:int}
  type Claim={root:Root,ticket:I::Ticket,peer:Peer}
  type Registration={roots:Set[int],rootRows:List[Root],bindings:Set[int],claims:List[Claim],published:Set[int],results:List[I::Ticket],epoch:int,revision:int,seen:int,reply:bool}
  var enrollment:Registration
  pure def erase(t:I::Ticket):I::Ticket=t.with("target",t.target.with("key",0))
  pure val second:I::Ticket=I::ticket2.with("challenge",0)
  pure val root:Root={template:erase(I::ticket),enrollmentKey:500,epoch:0,challenge:71}
  pure val root2:Root={template:erase(second),enrollmentKey:600,epoch:0,challenge:72}
  pure def peer(ch:int):Peer=if(ch==1) {enrollmentKey:500,beneficiaryKey:200,workload:9,session:51,challenge:71}
    else if(ch==2) {enrollmentKey:100,beneficiaryKey:201,workload:9,session:51,challenge:71}
    else if(ch==3) {enrollmentKey:500,beneficiaryKey:201,workload:9,session:51,challenge:71}
    else if(ch==4) {enrollmentKey:500,beneficiaryKey:200,workload:9,session:52,challenge:71}
    else if(ch==5) {enrollmentKey:600,beneficiaryKey:300,workload:9,session:52,challenge:72}
    else {enrollmentKey:100,beneficiaryKey:100,workload:9,session:50,challenge:71}
  pure val initial:Registration={roots:Set(),rootRows:List(root,root2),bindings:Set(),claims:List({root:root,ticket:I::ticket,peer:peer(1)},{root:root2,ticket:second,peer:peer(5)}),published:Set(),results:List(I::ticket,second),epoch:0,revision:0,seen:-1,reply:false}
  pure def boundPeer(r:Root,t:I::Ticket,p:Peer):bool=p.enrollmentKey==r.enrollmentKey and p.beneficiaryKey==t.target.key and p.workload==t.target.workload and p.session==r.template.session and p.challenge==r.challenge
  def credential(ch:int,r:Root,t:I::Ticket,entitlement:bool,possession:bool):bool=entitlement and possession and boundPeer(r,t,peer(ch))
  def blueprint(t:I::Ticket):bool=t.previous==auth.grant and t.parent==pub.log.length() and t.epoch==I::registry.epoch and t.challenge==I::registry.challenge and auth.now<t.target.expires and I::originalScope(t.target) and t.root==custody.original.intent
  val validBindings:bool=enrollment.bindings.forall(id=>enrollment.roots.contains(id) and enrollment.claims.nth(id).root==enrollment.rootRows.nth(id) and erase(enrollment.claims.nth(id).ticket)==enrollment.rootRows.nth(id).template and boundPeer(enrollment.claims.nth(id).root,enrollment.claims.nth(id).ticket,enrollment.claims.nth(id).peer))
  val joined:bool=P::invitations.registered==enrollment.published and enrollment.published.subseteq(enrollment.bindings) and enrollment.published.forall(id=>P::invitations.bindings.nth(id)==enrollment.results.nth(id) and enrollment.results.nth(id)==enrollment.claims.nth(id).ticket)
  val invariant:bool=P::invariant and validBindings and joined
  action idle:bool=all {I::idle,I::registry'=I::registry,P::invitations'=P::invitations}
  action boot:bool=all {P::boot,enrollment'=initial}
  // approved is a trusted producer result; channel 9 is its authenticated principal.
  action registerRoot(ch:int,r:Root,approved:bool,deliver:bool):bool=all {ch==9,approved,Set(root,root2).contains(r),not(enrollment.roots.contains(r.template.id)),r.epoch==enrollment.epoch,idle,enrollment'=enrollment.with("roots",enrollment.roots.union(Set(r.template.id))).with("rootRows",enrollment.rootRows.replaceAt(r.template.id,r)).with("revision",enrollment.revision+1).with("seen",-1).with("reply",deliver)}
  action read:bool=all {idle,enrollment'=enrollment.with("seen",enrollment.revision)}
  def canBind(ch:int,t:I::Ticket,entitlement:bool,possession:bool):bool={val r=enrollment.rootRows.nth(t.id)
    enrollment.roots.contains(t.id) and not(enrollment.bindings.contains(t.id)) and erase(t)==r.template and r.epoch==enrollment.epoch and credential(ch,r,t,entitlement,possession) and blueprint(t) and enrollment.seen==enrollment.revision}
  action bindKey(ch:int,t:I::Ticket,entitlement:bool,possession:bool,deliver:bool):bool=all {canBind(ch,t,entitlement,possession),idle,enrollment'=enrollment.with("bindings",enrollment.bindings.union(Set(t.id))).with("claims",enrollment.claims.replaceAt(t.id,{root:enrollment.rootRows.nth(t.id),ticket:t,peer:peer(ch)})).with("revision",enrollment.revision+1).with("seen",-1).with("reply",deliver)}
  def canPublish(t:I::Ticket,approved:bool):bool=enrollment.bindings.contains(t.id) and enrollment.claims.nth(t.id).ticket==t and enrollment.claims.nth(t.id).root==enrollment.rootRows.nth(t.id) and enrollment.rootRows.nth(t.id).epoch==enrollment.epoch and not(enrollment.published.contains(t.id)) and blueprint(t) and enrollment.seen==enrollment.revision and approved
  action publish(t:I::Ticket,approved:bool,deliver:bool):bool=all {canPublish(t,approved),P::register(t,true),enrollment'=enrollment.with("published",enrollment.published.union(Set(t.id))).with("results",enrollment.results.replaceAt(t.id,t)).with("revision",enrollment.revision+1).with("seen",-1).with("reply",deliver)}
  // Coordinator recovery can read a result after a new transport session; it cannot rebind.
  action recover(ch:int,id:int,allowed:bool):bool=all {ch==9,allowed,enrollment.roots.contains(id),idle,enrollment'=enrollment.with("reply",true)}
  action crash:bool=all {P::crash,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1).with("reply",false)}
  action revoke:bool=all {P::revoke,enrollment'=enrollment.with("epoch",enrollment.epoch+1).with("revision",enrollment.revision+1).with("seen",-1)}
  action readInvitation:bool=all {P::read,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action consume:bool=all {P::consume(1,I::ticket,true,false),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action prove:bool=all {P::prove(1,I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action readCustody:bool=all {P::readCustody,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action stage:bool=all {P::stage(I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action readActivation:bool=all {P::readActivation,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action activate:bool=all {P::activate(1,I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action rooted:bool=boot.then(registerRoot(9,root,true,false))
  action ready:bool=rooted.then(read)
  action bound:bool=ready.then(bindKey(1,I::ticket,true,true,false))
  action published:bool=bound.then(read).then(publish(I::ticket,true,false))
  action consumed:bool=published.then(readInvitation).then(consume)
  action activated:bool=consumed.then(prove).then(readCustody).then(stage).then(readActivation).then(activate)
  action step:bool=any {registerRoot(9,root,true,false),read,bindKey(1,I::ticket,true,true,false),publish(I::ticket,true,false),recover(9,0,true),crash,revoke,readInvitation,consume,prove,readCustody,stage,readActivation,activate}
  run sharedWorkloadCannotCreateEntitlementTest=boot.then(registerRoot(0,root,true,true).fail())
  run producerApprovalRequiredTest=boot.then(registerRoot(9,root,false,true).fail())
  run rootHasNoBeneficiaryAuthorityTest=rooted.expect(invariant and enrollment.bindings==Set() and P::invitations.registered==Set() and auth.grant.inc==0)
  run sharedIdentityCannotRegisterKeyTest=ready.then(bindKey(0,I::ticket,true,true,true).fail())
  run forwardedBearerWithOwnKeyRejectedTest=ready.then(bindKey(2,I::ticket.with("target",I::target.with("key",201)),true,true,true).fail())
  run entitlementProofRequiredTest=ready.then(bindKey(1,I::ticket,false,true,true).fail())
  run beneficiaryPossessionRequiredTest=ready.then(bindKey(1,I::ticket,true,false,true).fail())
  run substitutedSessionRejectedTest=ready.then(bindKey(4,I::ticket,true,true,true).fail())
  run originalScopeCannotBeRewrittenTest=ready.then(bindKey(1,I::ticket.with("root",99),true,true,true).fail())
  run firstBindingDoesNotPublishTest=bound.expect(invariant and enrollment.bindings==Set(0) and P::invitations.registered==Set() and not(enrollment.reply))
  run lostBindingReplyRetainsFirstKeyTest=bound.then(crash).then(recover(9,0,true)).expect(invariant and enrollment.claims.nth(0).ticket.target.key==200 and enrollment.reply and enrollment.seen!=enrollment.revision)
  run authorizedSecondKeyCannotReplaceFirstTest=bound.then(crash).then(read).then(bindKey(3,I::ticket.with("target",I::target.with("key",201)),true,true,true).fail())
  run oldWorkerCannotRecoverEnrollmentTest=bound.then(recover(0,0,true).fail())
  run recoveryNeedsCurrentReadPolicyTest=bound.then(recover(9,0,false).fail())
  run newRootInvalidatesPublicationReadTest=bound.then(read).then(registerRoot(9,root2,true,true)).then(publish(I::ticket,true,true).fail())
  run currentPolicyRequiredAtPublicationTest=bound.then(read).then(publish(I::ticket,false,true).fail())
  run changedPayloadCannotPublishTest=bound.then(read).then(publish(I::ticket.with("target",I::target.with("key",201)),true,true).fail())
  run lostPublicationReplyRetainsExactOutcomeTest=published.then(crash).then(recover(9,0,true)).expect(invariant and enrollment.results.nth(0)==I::ticket and P::invitations.bindings.nth(0)==I::ticket and I::registry.issued==Set())
  run publicationCannotRepeatTest=published.then(read).then(publish(I::ticket,true,true).fail())
  run rootRevocationBlocksPublicationTest=bound.then(revoke).then(read).then(publish(I::ticket,true,true).fail())
  run rootRevocationFencesPublishedConsumptionTest=published.then(revoke).then(readInvitation).then(consume.fail())
  run actualActivationRetainsOriginalHoldTest=activated.expect(invariant and auth.grant.inc==1 and f.log.length()==1 and a.anchor.holds.get(12)==2 and not(a.anchor.used.contains(12)))
  run lostRootReplyRetainsEnrollmentPrincipalTest=rooted.then(crash).then(recover(9,0,true)).expect(invariant and enrollment.rootRows.nth(0).enrollmentKey==500 and enrollment.bindings==Set() and enrollment.reply and enrollment.seen!=enrollment.revision)
  run rootCannotBeReplacedAfterRecoveryTest=rooted.then(crash).then(recover(9,0,true)).then(registerRoot(9,root.with("enrollmentKey",100),true,true).fail())
  run signatureForAnotherBeneficiaryKeyRejectedTest=ready.then(bindKey(1,I::ticket.with("target",I::target.with("key",201)),true,true,true).fail())
  run sourceEpochChangeInvalidatesPublicationTest=bound.then(read).then(all {P::revoke,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}).then(read).then(publish(I::ticket,true,true).fail())
  // Unsafe mutations below are excluded from step and expose missing native contracts.
  action unsafeBind:bool=all {idle,enrollment'=enrollment.with("bindings",Set(0)).with("claims",enrollment.claims.replaceAt(0,{root:root,ticket:I::ticket,peer:peer(0)}))}
  action replaceFirstKey:bool=all {idle,enrollment'=enrollment.with("claims",enrollment.claims.replaceAt(0,enrollment.claims.nth(0).with("ticket",I::ticket.with("target",I::target.with("key",201)))))}
  action publishWithoutOutcome:bool=all {P::register(I::ticket,true),enrollment'=enrollment}
  action outcomeWithoutPublication:bool=all {idle,enrollment'=enrollment.with("published",Set(0))}
  action eraseFirstBinding:bool=all {idle,enrollment'=enrollment.with("bindings",Set())}
  run sharedIdentityRegistrationCounterexampleTest=ready.then(unsafeBind).expect(not(invariant) and enrollment.claims.nth(0).peer.enrollmentKey==100)
  run replacedKeyRegistrationCounterexampleTest=published.then(replaceFirstKey).expect(not(invariant) and enrollment.claims.nth(0).ticket.target.key==201 and P::invitations.bindings.nth(0).target.key==200)
  run missingOutcomeRegistrationCounterexampleTest=bound.then(publishWithoutOutcome).expect(not(invariant) and P::invitations.registered.contains(0) and enrollment.published==Set())
  run splitPublicationRegistrationCounterexampleTest=bound.then(outcomeWithoutPublication).expect(not(invariant) and enrollment.published.contains(0) and P::invitations.registered==Set())
  run rollbackFirstBindingRegistrationCounterexampleTest=published.then(eraseFirstBinding).expect(not(invariant) and enrollment.published.contains(0) and enrollment.bindings==Set())
}

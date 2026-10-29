module LlmSubjectAuthority {
  import LlmEnrollmentCredential as E from "./LlmEnrollmentCredential"
  import LlmBeneficiaryRegistration as B from "./LlmBeneficiaryRegistration"
  import LlmIncarnationIssuance as I from "./LlmIncarnationIssuance"
  import LlmCallerCustody.auth from "./LlmCallerCustody"
  import LlmAccountCommit.a from "./LlmAccountCommit"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  type Principal={authority:int,tenant:int,subject:int,key:int,generation:int}
  type Task={template:E::Plan,authority:int,tenant:int,producer:int}
  type Assignment={task:Task,plan:E::Plan}
  type Approval={subject:Principal,producer:Principal}
  type Authority={hasSubject:bool,subject:Principal,hasProducer:bool,producer:Principal,hasTask:bool,task:Task,assigned:bool,assignment:Assignment,approved:bool,approval:Approval,published:bool,revision:int,seen:int,reply:bool}
  var authority:Authority
  pure val subject:Principal={authority:1,tenant:77,subject:401,key:700,generation:0}
  pure val producer:Principal={authority:1,tenant:77,subject:900,key:9000,generation:0}
  pure val task:Task={template:E::plan.with("subjectKey",0),authority:1,tenant:77,producer:900}
  pure val assignment:Assignment={task:task,plan:E::plan}
  pure val approval:Approval={subject:subject,producer:producer}
  pure val initial:Authority={hasSubject:false,subject:subject,hasProducer:false,producer:producer,hasTask:false,task:task,assigned:false,assignment:assignment,approved:false,approval:approval,published:false,revision:0,seen:-1,reply:false}
  pure def original(a:Assignment):bool=a.plan.with("subjectKey",0)==a.task.template
  pure def authBinding(a:Assignment,v:Approval):bool=v.subject.subject==a.plan.subject and v.subject.authority==a.task.authority and v.subject.tenant==a.task.tenant and v.subject.key==a.plan.subjectKey and v.producer.subject==a.task.producer and v.producer.authority==a.task.authority and v.producer.tenant==a.task.tenant
  pure def rotation(old:Principal,next:Principal):bool=next.authority==old.authority and next.tenant==old.tenant and next.subject==old.subject and next.generation==old.generation+1
  pure def subjectShape(r:Principal):bool=r.authority==1 and r.tenant==77 and r.subject==401 and Set(700,701).contains(r.key) and r.generation>=0
  pure def producerShape(r:Principal):bool=r.authority==1 and r.tenant==77 and r.subject==900 and Set(9000,9001).contains(r.key) and r.generation>=0
  val invariant:bool=E::invariant and (not(authority.hasSubject) or subjectShape(authority.subject)) and (not(authority.hasProducer) or producerShape(authority.producer)) and (not(authority.assigned) or (authority.hasTask and authority.assignment.task==authority.task and original(authority.assignment))) and E::ledger.plans==(if(authority.published) Set(0) else Set()) and (not(authority.published) or (authority.assigned and E::ledger.planRows.nth(0)==authority.assignment.plan))
  def live(a:Assignment,v:Approval,proof:bool,policy:bool):bool=authority.assigned and authority.assignment==a and authority.hasSubject and authority.hasProducer and authority.subject==v.subject and authority.producer==v.producer and authBinding(a,v) and proof and policy and authority.seen==authority.revision and a.plan.root.epoch==B::enrollment.epoch and B::blueprint(a.plan.root.template) and invariant
  action idle:bool=all {E::idle,E::ledger'=E::ledger}
  action boot:bool=all {E::boot,authority'=initial}
  // Channel 8 is a configured identity/task authority, never an arbitrary OIDC issuer.
  action registerSubject(ch:int,r:Principal,native:bool):bool=all {ch==8,native,subjectShape(r),not(authority.hasSubject),idle,authority'=authority.with("hasSubject",true).with("subject",r).with("revision",authority.revision+1).with("seen",-1)}
  action registerProducer(ch:int,r:Principal,native:bool):bool=all {ch==8,native,producerShape(r),not(authority.hasProducer),idle,authority'=authority.with("hasProducer",true).with("producer",r).with("revision",authority.revision+1).with("seen",-1)}
  action registerTask(ch:int,t:Task,native:bool):bool=all {ch==8,native,t==task,not(authority.hasTask),idle,authority'=authority.with("hasTask",true).with("task",t).with("revision",authority.revision+1).with("seen",-1)}
  action rotateSubject(ch:int,old:Principal,next:Principal,native:bool):bool=all {ch==8,native,authority.hasSubject,authority.subject==old,rotation(old,next),subjectShape(next),idle,authority'=authority.with("subject",next).with("revision",authority.revision+1).with("seen",-1)}
  action rotateProducer(ch:int,old:Principal,next:Principal,native:bool):bool=all {ch==8,native,authority.hasProducer,authority.producer==old,rotation(old,next),producerShape(next),idle,authority'=authority.with("producer",next).with("revision",authority.revision+1).with("seen",-1)}
  action read:bool=all {invariant,idle,authority'=authority.with("seen",authority.revision)}
  // proof authenticates subject, producer and enrollment possession over this exact body.
  action assign(a:Assignment,v:Approval,proof:bool,policy:bool,deliver:bool):bool=all {authority.hasTask,authority.task==a.task,not(authority.assigned),original(a),authority.hasSubject,authority.hasProducer,authority.subject==v.subject,authority.producer==v.producer,authBinding(a,v),proof,policy,authority.seen==authority.revision,invariant,idle,authority'=authority.with("assigned",true).with("assignment",a).with("revision",authority.revision+1).with("seen",-1).with("reply",deliver)}
  action approve(a:Assignment,v:Approval,proof:bool,policy:bool):bool=all {live(a,v,proof,policy),idle,authority'=authority.with("approved",true).with("approval",v).with("revision",authority.revision+1).with("seen",-1)}
  action publish(a:Assignment,v:Approval,proof:bool,policy:bool,deliver:bool):bool=all {live(a,v,proof,policy),authority.approved,authority.approval==v,not(E::ledger.plans.contains(0)),E::registerPlan(9,a.plan,true),authority'=authority.with("published",true).with("revision",authority.revision+1).with("seen",-1).with("reply",deliver)}
  // Recovery requires a current subject proof; no arbitrary new session creates a read permit.
  action recover(r:Principal,proof:bool,policy:bool):bool=all {authority.hasTask,authority.hasSubject,authority.subject==r,r.subject==authority.task.template.subject,r.authority==authority.task.authority,r.tenant==authority.task.tenant,proof,policy,idle,authority'=authority.with("reply",true)}
  action crash:bool=all {E::crash,authority'=authority.with("revision",authority.revision+1).with("seen",-1).with("reply",false)}
  // Only a new credential needs this additional current identity/assignment gate.
  action issue:bool=all {live(assignment,authority.approval,true,true),authority.approved,E::issue(1,E::credential,true,true,true,false),authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readEnrollment:bool=all {invariant,E::read,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action request:bool=all {invariant,E::request(E::credential),authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action release:bool=all {invariant,E::release(E::credential,true),authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action root:bool=all {invariant,E::activateRoot(1,E::credential,true,true),authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readBinding:bool=all {invariant,E::readBinding,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action bind:bool=all {invariant,E::bind,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readPublication:bool=all {invariant,E::readPublication,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action publishInvitation:bool=all {invariant,E::publish,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readInvitation:bool=all {invariant,E::readInvitation,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action consume:bool=all {invariant,E::consume,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action prove:bool=all {invariant,E::prove,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readCustody:bool=all {invariant,E::readCustody,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action stage:bool=all {invariant,E::stage,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action readActivation:bool=all {invariant,E::readActivation,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action activate:bool=all {invariant,E::activate,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action revoke:bool=all {invariant,E::revoke,authority'=authority.with("revision",authority.revision+1).with("seen",-1)}
  action sourced:bool=boot.then(registerSubject(8,subject,true)).then(registerProducer(8,producer,true)).then(registerTask(8,task,true))
  action ready:bool=sourced.then(read)
  action assigned:bool=ready.then(assign(assignment,approval,true,true,false))
  action approved:bool=assigned.then(read).then(approve(assignment,approval,true,true))
  action published:bool=approved.then(read).then(publish(assignment,approval,true,true,false))
  action issued:bool=published.then(readEnrollment).then(read).then(issue)
  action rooted:bool=issued.then(readEnrollment).then(request).then(readEnrollment).then(release).then(readEnrollment).then(root)
  action bound:bool=rooted.then(readBinding).then(bind)
  action activated:bool=bound.then(readPublication).then(publishInvitation).then(readInvitation).then(consume).then(prove).then(readCustody).then(stage).then(readActivation).then(activate)
  action step:bool=any {registerSubject(8,subject,true),registerProducer(8,producer,true),registerTask(8,task,true),read,assign(assignment,approval,true,true,false),approve(assignment,authority.approval,true,true),publish(assignment,authority.approval,true,true,false),rotateSubject(8,authority.subject,authority.subject.with("generation",authority.subject.generation+1),true),rotateProducer(8,authority.producer,authority.producer.with("generation",authority.producer.generation+1),true),recover(authority.subject,true,true),crash,readEnrollment,issue,request,release,root,readBinding,bind,readPublication,publishInvitation,readInvitation,consume,prove,readCustody,stage,readActivation,activate,revoke}
  run sharedWorkloadCannotRegisterSubjectTest=boot.then(registerSubject(0,subject,true).fail())
  run configuredAuthorityEvidenceRequiredTest=boot.then(registerSubject(8,subject,false).fail())
  run otherIdentityIssuerRejectedTest=boot.then(registerSubject(8,subject.with("authority",2),true).fail())
  run taskOriginCannotComeFromSharedWorkloadTest=sourced.then(registerTask(0,task,true).fail())
  run sharedIdentityCannotAssignTest=ready.then(assign(assignment,approval.with("subject",subject.with("key",100)),true,true,true).fail())
  run tenantSubstitutionRejectedTest=ready.then(assign(assignment,approval.with("subject",subject.with("tenant",78)),true,true,true).fail())
  run producerSubstitutionRejectedTest=ready.then(assign(assignment,approval.with("producer",producer.with("subject",901)),true,true,true).fail())
  run exactJointProofRequiredTest=ready.then(assign(assignment,approval,false,true,true).fail())
  run originalEnrollmentKeyCannotChangeTest=ready.then(assign(assignment.with("plan",E::plan.with("root",B::root.with("enrollmentKey",501))),approval,true,true,true).fail())
  run assignmentDoesNotPublishOrIssueTest=assigned.expect(invariant and E::ledger.plans==Set() and E::ledger.credentials==Set() and B::enrollment.roots==Set() and auth.grant.inc==0)
  run lostAssignmentReplyRetainsOriginalTest=assigned.then(crash).then(recover(subject,true,true)).expect(invariant and authority.assignment==assignment and authority.assigned and authority.reply and authority.seen!=authority.revision)
  run existingAssignmentCannotBeReplacedTest=assigned.then(crash).then(recover(subject,true,true)).then(read).then(assign(assignment.with("plan",E::plan.with("root",B::root.with("enrollmentKey",501))),approval,true,true,true).fail())
  run subjectRotationInvalidatesOldApprovalTest=approved.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(read).then(publish(assignment,approval,true,true,true).fail())
  run producerRotationInvalidatesOldApprovalTest=approved.then(rotateProducer(8,producer,producer.with("generation",1),true)).then(read).then(publish(assignment,approval,true,true,true).fail())
  run sameKeyCredentialRotationCanReauthorizeTest=approved.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(read).then(approve(assignment,approval.with("subject",subject.with("generation",1)),true,true)).then(read).then(publish(assignment,approval.with("subject",subject.with("generation",1)),true,true,true)).expect(invariant and authority.assignment==assignment and E::ledger.planRows.nth(0).root.enrollmentKey==500 and authority.subject.generation==1)
  run producerRotationCanReauthorizeSamePlanTest=approved.then(rotateProducer(8,producer,producer.with("key",9001).with("generation",1),true)).then(read).then(approve(assignment,approval.with("producer",producer.with("key",9001).with("generation",1)),true,true)).then(read).then(publish(assignment,approval.with("producer",producer.with("key",9001).with("generation",1)),true,true,true)).expect(invariant and E::ledger.planRows.nth(0)==E::plan)
  run changedSubjectKeyCannotRewritePendingPlanTest=assigned.then(rotateSubject(8,subject,subject.with("key",701).with("generation",1),true)).then(read).then(approve(assignment,approval.with("subject",subject.with("key",701).with("generation",1)),true,true).fail())
  run oldWorkerCannotRotateFromOldParentTest=sourced.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(rotateSubject(8,subject,subject.with("generation",1),true).fail())
  run generationCannotBeReopenedTest=sourced.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(rotateSubject(8,subject.with("generation",1),subject,true).fail())
  run rotationCannotRenameSubjectTest=sourced.then(rotateSubject(8,subject,subject.with("subject",9).with("generation",1),true).fail())
  run sameKeyRotationDoesNotChangeHistoricalPlanTest=published.then(rotateSubject(8,subject,subject.with("generation",1),true)).expect(invariant and E::ledger.planRows.nth(0)==E::plan and authority.assignment.plan.root.enrollmentKey==500)
  run oldSourceReadCannotPublishTest=approved.then(read).then(rotateProducer(8,producer,producer.with("generation",1),true)).then(publish(assignment,approval,true,true,true).fail())
  run publicationNeedsCurrentPolicyTest=approved.then(read).then(publish(assignment,approval,true,false,true).fail())
  run lostPublicationReplyRecoversExactPlanTest=published.then(crash).then(recover(subject,true,true)).expect(invariant and E::ledger.planRows.nth(0)==E::plan and E::ledger.credentials==Set() and not(authority.seen==authority.revision))
  run publicationCannotRepeatTest=published.then(read).then(publish(assignment,approval,true,true,true).fail())
  run planPublicationHasNoCredentialEffectTest=published.expect(invariant and E::ledger.credentials==Set() and E::ledger.requested==Set() and B::enrollment.roots==Set() and I::registry.issued==Set() and a.anchor.holds.get(12)==2)
  run rotatedIdentityRecheckedAtNewIssueTest=published.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(readEnrollment).then(read).then(issue.fail())
  run renewedIdentityCanIssueOriginalPlanTest=published.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(read).then(approve(assignment,approval.with("subject",subject.with("generation",1)),true,true)).then(readEnrollment).then(read).then(issue).expect(invariant and E::ledger.rows.nth(0)==E::credential and E::ledger.ids==Set(101))
  run sharedWorkloadCannotRecoverSubjectTest=assigned.then(recover(subject.with("key",100),true,true).fail())
  run recoveryRequiresCurrentProofTest=assigned.then(recover(subject,false,true).fail())
  run oldSubjectCredentialCannotRecoverTest=assigned.then(rotateSubject(8,subject,subject.with("generation",1),true)).then(recover(subject,true,true).fail())
  run recoveryRequiresReadPolicyTest=assigned.then(recover(subject,true,false).fail())
  run actualActivationPreservesOriginalHoldTest=activated.expect(invariant and auth.grant.inc==1 and a.anchor.holds.get(12)==2 and not(a.anchor.used.contains(12)) and f.log.length()==1)
  run recoveredWorkerCannotReplaceFirstKeyTest=bound.then(crash).then(recover(subject,true,true)).then(readBinding).then(all {invariant,E::ledger'=E::ledger,B::bindKey(3,I::ticket.with("target",I::target.with("key",201)),true,true,true),authority'=authority}.fail())
  // Unsafe mutations below are excluded from step.
  action forgedSource:bool=all {idle,authority'=authority.with("subject",subject.with("authority",2))}
  action replacedAssignment:bool=all {idle,authority'=authority.with("assignment",assignment.with("plan",E::plan.with("root",B::root.with("enrollmentKey",501))))}
  action eraseAssignment:bool=all {idle,authority'=authority.with("assigned",false)}
  action planWithoutOutcome:bool=all {E::registerPlan(9,E::plan,true),authority'=authority}
  action outcomeWithoutPlan:bool=all {idle,authority'=authority.with("published",true)}
  run forgedAuthorityCounterexampleTest=assigned.then(forgedSource).expect(not(invariant) and authority.subject.authority==2)
  run replacedEnrollmentCounterexampleTest=published.then(replacedAssignment).expect(not(invariant) and authority.assignment.plan.root.enrollmentKey==501 and E::ledger.planRows.nth(0).root.enrollmentKey==500)
  run erasedAssignmentCounterexampleTest=published.then(eraseAssignment).expect(not(invariant) and E::ledger.plans==Set(0) and not(authority.assigned))
  run missingPlanOutcomeCounterexampleTest=approved.then(planWithoutOutcome).expect(not(invariant) and E::ledger.plans==Set(0) and not(authority.published))
  run phantomPlanOutcomeCounterexampleTest=approved.then(outcomeWithoutPlan).expect(not(invariant) and E::ledger.plans==Set() and authority.published)
  run splitRecoveryCannotIssueTest=approved.then(planWithoutOutcome).then(all {E::read,authority'=authority}).then(read.fail())
}

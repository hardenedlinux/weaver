module LlmPolicyContinuation {
  type Change={id:int,root:int,parent:int,tip:int,content:int,allowed:bool,claim:int,profile:int,budget:int,history:int}
  type View={generation:int,tip:int,fence:int,revision:int}
  type Approval={candidate:Change,view:View,authorized:bool}
  type Publication={change:Change,generation:int,actual:View,approval:View,reauthorized:bool}
  type Alias={protocol:int,task:int,canonicalRoot:int}
  type Permit={id:int,generation:int,fence:int,revision:int}
  type Use={permit:Permit,actual:View,allowed:bool}
  // Composition slice of the existing owner, not a second ledger. Durability is
  // an explicit host premise: restart preserves this state except local views.
  type Barrier={id:int,floor:int,proposedCut:int}
  type Receipt={id:int,root:int,domain:int,complete:bool}
  type NextAdmission={slot:int,receipt:int,domain:int,floor:int,fence:int,revision:int,pending:Set[int],frontier:int,root:int}
  type NextUse={admission:NextAdmission,actual:View,floor:int,pending:Set[int],allowed:bool}
  type FactClosure={backend:int,engine:int,rule:int,query:int,schema:int,cut:int,authority:int,scope:int,limits:int,adapter:int,environment:int,freshness:int}
  type FactEvidence={closure:FactClosure,complete:bool,covered:Set[int],owned:bool,timedOut:bool,value:int,rows:Set[int]}
  type SourceImage={cut:int,value:int,rows:Set[int]}
  type Freshness={contract:int,authority:int,cut:int,scope:int,channel:int,clock:int,fence:int,before:int}
  type FactUse={evidence:FactEvidence,closure:FactClosure,scope:Set[int],sourceValue:int,sourceRows:Set[int],readValue:int,mode:int,grant:Freshness,connected:bool,channel:int,clock:int,now:int,timeFloor:int,owner:int}
  type FactDelta={before:FactClosure,after:FactClosure}
  // Adapter evidence refinement; this is not a second execution/session owner.
  // Native source admission separately checks nonempty character/UTF-8 byte
  // bounds before FFI. A readable/stable buffer and status zero do not prove
  // bounded encoding allocation; Scheme/Rust framework properties own that
  // implementation evidence. These protocol schedules grant no allocator proof.
  type BoundaryEvidence={kind:int,root:int,claim:int,profile:int,configurationSchema:int,normalizer:int,programModule:int,environment:int,
    vm:int,call:int,epoch:int,cut:int,input:int,output:int,schemaChecked:bool,governanceChecked:bool,
    readable:bool,stable:bool,owned:bool,retainedPointer:bool,reentrant:bool,status:int}
  type BoundaryCheck={evidence:BoundaryEvidence,configurationSchema:int,normalizer:int,programModule:int,environment:int,vm:int,call:int,epoch:int,cut:int,value:int,senderVM:int,senderCall:int,senderEpoch:int}
  type FactState={closure:FactClosure,candidate:FactEvidence,installed:FactEvidence,hostValue:int,sourceValue:int,sourceImages:Set[SourceImage],truth:Set[int],scope:Set[int],
    mode:int,grant:Freshness,connected:bool,channel:int,clock:int,now:int,timeFloor:int,uses:List[FactUse],deltas:List[FactDelta]}
  type State={staged:Set[Change],log:List[Publication],generation:int,allowed:bool,fence:int,revision:int,online:bool,
    inspections:Set[View],approvals:Set[Approval],winner:int,visibleWinner:int,acks:Set[int],aliases:Set[Alias],permits:Set[Permit],
    uses:List[Use],spent:bool,everSpent:bool,calls:int,hold:int,usage:int,
    factFloor:int,barriers:List[Barrier],resolved:Set[int],pending:Set[int],hardAllowed:bool,visibleBarrier:int,
    receipts:Set[Receipt],frontier:int,nextAdmissions:List[NextAdmission],visibleAdmission:int,nextUses:List[NextUse],
    nextSpent:bool,nextCalls:int,nextHold:int,facts:FactState,semanticVM:int,ffiCall:int,captureEpoch:int,
    configurationSchema:int,configurationNormalizer:int,schemeModule:int,boundaryRecords:List[BoundaryCheck]}
  var s:State
  pure val original={id:10,root:10,parent:0,tip:0,content:100,allowed:true,claim:11,profile:20,budget:5,history:9}
  pure val external0=original.with("id",20).with("root",20).with("content",200).with("allowed",false)
  pure val continuation=original.with("id",11).with("parent",1).with("tip",20)
  pure val sibling=continuation.with("id",12)
  pure val second=original.with("id",12).with("parent",2).with("tip",11)
  pure val v1={generation:1,tip:20,fence:0,revision:0}
  pure val permit0={id:0,generation:0,fence:0,revision:0}
  pure val permit2={id:1,generation:2,fence:0,revision:0}
  pure val closure0={backend:0,engine:0,rule:0,query:0,schema:0,cut:0,authority:0,scope:0,limits:0,adapter:0,environment:0,freshness:0}
  pure val evidence0={closure:closure0,complete:true,covered:Set(1,2),owned:true,timedOut:false,value:0,rows:Set()}
  pure val facts0={closure:closure0,candidate:evidence0,installed:evidence0,hostValue:0,sourceValue:0,sourceImages:Set({cut:0,value:0,rows:Set()}),truth:Set(),scope:Set(1,2),mode:0,
    grant:{contract:0,authority:0,cut:0,scope:0,channel:0,clock:0,fence:0,before:2},connected:true,channel:0,clock:0,now:0,timeFloor:0,uses:List(),deltas:List()}
  pure val initial={staged:Set(original,external0),log:List(),generation:0,allowed:true,fence:0,revision:0,online:true,
    inspections:Set(),approvals:Set(),winner:-1,visibleWinner:-1,acks:Set(),aliases:Set(),permits:Set(permit0),uses:List(),spent:false,everSpent:false,calls:0,hold:6,usage:-1,
    factFloor:0,barriers:List(),resolved:Set(),pending:Set(),hardAllowed:true,visibleBarrier:-1,receipts:Set(),frontier:0,
    nextAdmissions:List(),visibleAdmission:-1,nextUses:List(),nextSpent:false,nextCalls:0,nextHold:0,facts:facts0,
    semanticVM:0,ffiCall:0,captureEpoch:0,configurationSchema:1,configurationNormalizer:1,schemeModule:0,boundaryRecords:List()}
  pure val boundary0={kind:0,root:10,claim:11,profile:20,configurationSchema:1,normalizer:1,programModule:0,environment:0,
    vm:0,call:0,epoch:0,cut:0,input:0,output:0,schemaChecked:true,governanceChecked:true,
    readable:true,stable:true,owned:true,retainedPointer:false,reentrant:false,status:0}
  def tip=if(s.log.length()==0)0 else s.log.nth(s.log.length()-1).change.id
  def effective=if(s.log.length()==0)true else s.log.nth(s.log.length()-1).change.allowed
  def view={generation:s.generation,tip:tip,fence:s.fence,revision:s.revision}
  pure def sameIntent(c)=c.root==10 and c.content==original.content and c.allowed==original.allowed and c.claim==original.claim and c.profile==original.profile and c.budget==original.budget and c.history==original.history
  def registered(c)=c==original or s.approvals.exists(a=>a.candidate==c)
  def approvalCurrent(c)=c==original or s.approvals.exists(a=>a.candidate==c and a.view==view and a.authorized)
  pure def factUse(f,e,owner)={evidence:e,closure:f.closure,scope:f.scope,sourceValue:f.sourceValue,sourceRows:f.truth,readValue:e.value,mode:f.mode,grant:f.grant,
    connected:f.connected,channel:f.channel,clock:f.clock,now:f.now,timeFloor:f.timeFloor,owner:owner}
  pure def factUseValid(u)=u.evidence.closure==u.closure and u.evidence.complete and u.evidence.covered==u.scope and
    u.evidence.owned and not(u.evidence.timedOut) and u.readValue==u.evidence.value and
    u.evidence.value==u.sourceValue and u.evidence.rows==u.sourceRows and
    u.grant.contract==u.closure.freshness and u.grant.authority==u.closure.authority and u.grant.cut==u.closure.cut and u.grant.scope==u.closure.scope and
    u.grant.fence==u.owner and u.grant.clock==u.clock and u.now>=u.timeFloor and
    (if(u.mode==0)u.connected and u.grant.channel==u.channel else u.mode==1 and u.now<u.grant.before)
  def currentFacts=factUse(s.facts,s.facts.installed,s.fence)
  def candidateFacts=factUse(s.facts,s.facts.candidate,s.fence)
  def recordCurrentFacts=s.facts.with("uses",s.facts.uses.append(currentFacts))
  def boundaryCheckFrom(e,senderVM,senderCall,senderEpoch)={evidence:e,configurationSchema:s.configurationSchema,normalizer:s.configurationNormalizer,
    programModule:s.schemeModule,environment:s.facts.closure.environment,vm:s.semanticVM,call:s.ffiCall,epoch:s.captureEpoch,
    cut:s.facts.closure.cut,value:s.facts.sourceValue,senderVM:senderVM,senderCall:senderCall,senderEpoch:senderEpoch}
  def boundaryCheck(e)=boundaryCheckFrom(e,s.semanticVM,s.ffiCall,s.captureEpoch)
  pure def boundaryValid(u:BoundaryCheck):bool={val e=u.evidence
    val validKind=e.kind==0 or e.kind==1
    validKind and e.root==10 and e.claim==11 and e.profile==20 and
    e.configurationSchema>0 and e.configurationSchema==u.configurationSchema and e.normalizer==u.normalizer and
    e.programModule==u.programModule and e.environment==u.environment and e.vm==u.vm and e.call==u.call and e.epoch==u.epoch and
    u.senderVM==u.vm and u.senderCall==u.call and u.senderEpoch==u.epoch and
    e.cut==u.cut and e.input==u.value and e.output==u.value and e.schemaChecked and e.governanceChecked and
    e.readable and e.stable and e.owned and not(e.retainedPointer) and not(e.reentrant) and e.status==0}
  action recordBoundary(e)=all {boundaryValid(boundaryCheck(e)),s'=s.with("boundaryRecords",s.boundaryRecords.append(boundaryCheck(e)))}
  action semanticRestart=s'=s.with("semanticVM",s.semanticVM+1).with("ffiCall",s.ffiCall+1).with("captureEpoch",s.captureEpoch+1)
  action endBorrow=s'=s.with("ffiCall",s.ffiCall+1)
  action rebindConfiguration=s'=s.with("configurationSchema",s.configurationSchema+1).with("captureEpoch",s.captureEpoch+1)
  action loseVolatileCaptures=s'=s.with("boundaryRecords",List())
  action init=s'=initial
  action stage(c,qualified)=all {qualified,c.root==10,s.staged.forall(old=>old.id!=c.id),s'=s.with("staged",s.staged.union(Set(c)))}
  action inspect(qualified)=all {s.online,s.winner == -1,s.log.indices().forall(i=>s.log.nth(i).change.root!=10),qualified,
    s'=s.with("inspections",s.inspections.union(Set(view)))}
  action approve(c,observed,authorized,durable)=all {s.staged.contains(c),s.staged.contains(original),c.id!=10,sameIntent(c),s.winner == -1,
    s.inspections.contains(observed),observed==view,original.parent<s.generation,c.parent==s.generation,c.tip==tip,s.online,authorized,durable,
    s'=s.with("approvals",s.approvals.union(Set({candidate:c,view:observed,authorized:authorized})))}
  action publish(c,worker,durable,policy)=all {s.staged.contains(c),registered(c),sameIntent(c),s.winner == -1,approvalCurrent(c),s.online,
    c.parent==s.generation,c.tip==tip,worker==s.fence,durable,policy,s.log.indices().forall(i=>s.log.nth(i).change.id!=c.id),
    s'=s.with("generation",s.generation+1).with("allowed",c.allowed).with("winner",c.id).with("visibleWinner",c.id)
      .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:view,reauthorized:true}))}
  action otherPublish(c,qualified)=all {qualified,c.root!=10,s.online,c.parent==s.generation,c.tip==tip,
    s.log.indices().forall(i=>s.log.nth(i).change.id!=c.id),s'=s.with("generation",s.generation+1).with("allowed",c.allowed)
      .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:view,reauthorized:true}))}
  action queryWinner(qualified)=all {qualified,s'=s.with("visibleWinner",s.winner)}
  action loseReply=s'=s.with("visibleWinner",-1)
  action ack(id)=all {s.log.indices().exists(i=>s.log.nth(i).change.id==id),s'=s.with("acks",s.acks.union(Set(id)))}
  action alias(protocol,task,root,qualified)=all {qualified,root==10,protocol>=1,protocol<=5,
    s'=s.with("aliases",s.aliases.union(Set({protocol:protocol,task:task,canonicalRoot:root})))}
  action restart=s'=s.with("online",false).with("fence",s.fence+1).with("revision",s.revision+1).with("visibleWinner",-1)
    .with("visibleBarrier",-1).with("visibleAdmission",-1)
    .with("facts",s.facts.with("connected",false).with("channel",s.facts.channel+1).with("clock",s.facts.clock+1))
  action recover(qualified)=all {qualified,s'=s.with("online",true)}
  action ledgerWrite=s'=s.with("revision",s.revision+1)
  action issue=s'=s.with("permits",s.permits.union(Set({id:s.permits.size(),generation:s.generation,fence:s.fence,revision:s.revision})))
  action consume(p)=all {s.online,s.allowed,s.hardAllowed,s.pending.size()==0,factUseValid(currentFacts),s.permits.contains(p),p.generation==s.generation,p.fence==s.fence,p.revision==s.revision,not(s.spent),
    s'=s.with("spent",true).with("everSpent",true).with("calls",s.calls+1).with("revision",s.revision+1)
      .with("uses",s.uses.append({permit:p,actual:view.with("generation",s.log.length()),allowed:effective})).with("facts",recordCurrentFacts)}
  val originalRetained=s.staged.contains(original)
  val familyUnique=s.log.indices().filter(i=>s.log.nth(i).change.root==10).size()<=1
  val winnerBound=s.log.indices().forall(i=>s.log.nth(i).change.root==10 implies s.winner==s.log.nth(i).change.id) and
    (s.winner != -1 implies s.log.indices().exists(i=>s.log.nth(i).change.root==10 and s.log.nth(i).change.id==s.winner))
  val continuationBound=s.approvals.forall(a=>sameIntent(a.candidate) and a.authorized) and
    s.log.indices().forall(i=>{val r=s.log.nth(i)
      r.change.root==10 implies sameIntent(r.change) and r.reauthorized and r.approval==r.actual})
  val prefixBound=s.generation==s.log.length() and s.allowed==effective and s.log.indices().forall(i=>s.log.nth(i).change.parent==i)
  val aliasesBound=s.aliases.forall(a=>a.canonicalRoot==10)
  val accounting=s.calls<=1 and (s.everSpent implies s.spent) and (s.usage == -1 implies s.hold==6)
  val usesBound=s.uses.indices().forall(i=>{val u=s.uses.nth(i)
    u.allowed and u.permit.generation==u.actual.generation and u.permit.fence==u.actual.fence and u.permit.revision==u.actual.revision})
  action barrierForCut(id,proposedCut,worker,durable,qualified)=all {s.online,worker==s.fence,durable,qualified,
    not(s.barriers.indices().exists(i=>s.barriers.nth(i).id==id)),s'=s.with("factFloor",s.factFloor+1).with("revision",s.revision+1)
      .with("barriers",s.barriers.append({id:id,floor:s.factFloor+1,proposedCut:proposedCut})).with("pending",s.pending.union(Set(id))).with("visibleBarrier",id)}
  action barrier(id,worker,durable,qualified)=barrierForCut(id,s.facts.closure.cut,worker,durable,qualified)
  action queryBarrier(id)=all {s.online,s.barriers.indices().exists(i=>s.barriers.nth(i).id==id),s'=s.with("visibleBarrier",id)}
  action loseBarrierReply=s'=s.with("visibleBarrier",-1)
  action project(id,floor,pending,worker,durable,qualified,allowed)=all {
    s.online,s.pending.contains(id),floor==s.factFloor,pending==s.pending,worker==s.fence,durable,qualified,factUseValid(candidateFacts),
    s.barriers.indices().forall(i=>s.barriers.nth(i).id==id implies s.barriers.nth(i).proposedCut==s.facts.candidate.closure.cut),
    (allowed implies not(s.facts.candidate.rows.contains(2))),
    s'=s.with("pending",s.pending.exclude(Set(id))).with("resolved",s.resolved.union(Set(id)))
      .with("hardAllowed",allowed).with("revision",s.revision+1)
      .with("facts",s.facts.with("installed",s.facts.candidate).with("uses",s.facts.uses.append(candidateFacts)))}
  // Recording a known invocation receipt is historical; no frontier/account write.
  action recordTypedReceipt(id,root,domain,complete,authentic)=all {authentic,
    s.receipts.forall(r=>r.id!=id or r=={id:id,root:root,domain:domain,complete:complete}),
    s'=s.with("receipts",s.receipts.union(Set({id:id,root:root,domain:domain,complete:complete})))}
  action recordReceipt(id,authentic)=recordTypedReceipt(id,10,1,true,authentic)
  action admitNext(id,domain,root,floor,frontier,worker,durable,qualified)=all {
    s.online,s.allowed,s.hardAllowed,s.pending.size()==0,factUseValid(currentFacts),domain==1,root==10,
    s.receipts.contains({id:id,root:root,domain:domain,complete:true}),
    floor==s.factFloor,frontier==s.frontier,s.frontier==0,worker==s.fence,durable,qualified,
    s.hold+s.nextHold+6<=12,
    s'=s.with("frontier",1).with("nextHold",6).with("visibleAdmission",1).with("revision",s.revision+1)
      .with("nextAdmissions",s.nextAdmissions.append({slot:1,receipt:id,domain:domain,floor:floor,fence:worker,
        revision:s.revision+1,pending:s.pending,frontier:frontier,root:root})).with("facts",recordCurrentFacts)}
  action loseAdmissionReply=s'=s.with("visibleAdmission",-1)
  action queryAdmission=all {s.online,s.nextAdmissions.length()==1,s'=s.with("visibleAdmission",1)}
  // These Host-qualified actions represent admitted AA/Ascent/source results;
  // the model does not prove derivation truth, deep copying or source promises.
  action deriveFacts(complete,covered,owned,timedOut,qualified)=all {s.online,qualified,s.facts.hostValue==s.facts.sourceValue,
    s'=s.with("facts",s.facts.with("candidate",{closure:s.facts.closure,complete:complete,covered:covered,
      owned:owned,timedOut:timedOut,value:s.facts.hostValue,rows:s.facts.truth.filter(v=>covered.contains(v))}))}
  def candidateSourceValue(c)=if(c.cut==s.facts.closure.cut)s.facts.sourceValue else s.facts.hostValue
  action changeFactContract(c,truth,qualified)=all {s.online,qualified,s.pending.size()>0,
    s.facts.sourceImages.forall(b=>b.cut!=c.cut or (b.value==candidateSourceValue(c) and b.rows==truth)),
    s'=s.with("revision",s.revision+1).with("facts",s.facts.with("closure",c).with("truth",truth)
      .with("sourceValue",candidateSourceValue(c)).with("sourceImages",s.facts.sourceImages.union(Set({cut:c.cut,value:candidateSourceValue(c),rows:truth}))))}
  action mutateNestedValue=s'=s.with("facts",s.facts.with("hostValue",s.facts.hostValue+1))
  action reloadFrozenSource(qualified)=all {qualified,s'=s.with("facts",s.facts.with("hostValue",s.facts.sourceValue))}
  action disconnect=s'=s.with("revision",s.revision+1).with("facts",s.facts.with("connected",false).with("channel",s.facts.channel+1))
  action tick=s'=s.with("facts",s.facts.with("now",s.facts.now+1).with("timeFloor",s.facts.timeFloor+1))
  action renewFreshness(c,channel,clock,owner,before,qualified)=all {s.online,qualified,c==s.facts.closure,
    channel==s.facts.channel,clock==s.facts.clock,owner==s.fence,before>s.facts.now,
    s'=s.with("facts",s.facts.with("connected",true).with("grant",{contract:c.freshness,authority:c.authority,cut:c.cut,scope:c.scope,
      channel:channel,clock:clock,fence:owner,before:before}))}
  action fixedFactDelta(before,after,qualified)=all {qualified,before==after,
    s'=s.with("facts",s.facts.with("deltas",s.facts.deltas.append({before:before,after:after})))}
  action boundedInit={
    val c=closure0.with("freshness",1)
    val e=evidence0.with("closure",c)
    s'=initial.with("facts",facts0.with("mode",1).with("closure",c).with("candidate",e).with("installed",e)
      .with("grant",facts0.grant.with("contract",1)))
  }
  action sendNext(a)=all {s.online,s.nextAdmissions.indices().exists(i=>s.nextAdmissions.nth(i)==a),not(s.nextSpent),s.allowed,s.hardAllowed,s.pending.size()==0,factUseValid(currentFacts),
    a.floor==s.factFloor,a.fence==s.fence,a.revision==s.revision,
    s'=s.with("nextSpent",true).with("nextCalls",s.nextCalls+1).with("nextUses",s.nextUses.append({admission:a,
      actual:view,floor:s.factFloor,pending:s.pending,allowed:s.allowed and s.hardAllowed})).with("facts",recordCurrentFacts)}
  val barriersBound=s.factFloor==s.barriers.length() and
    s.barriers.indices().forall(i=>s.barriers.nth(i).floor==i+1) and
    s.barriers.indices().map(i=>s.barriers.nth(i).id).size()==s.barriers.length() and
    s.pending==s.barriers.indices().map(i=>s.barriers.nth(i).id).filter(id=>not(s.resolved.contains(id)))
  val nextBound=s.nextAdmissions.length()<=1 and s.frontier==s.nextAdmissions.length() and
    s.nextAdmissions.indices().forall(i=>{val a=s.nextAdmissions.nth(i)
      a.root==10 and a.slot==1 and a.domain==1 and a.frontier==0 and a.pending.size()==0 and
      s.receipts.contains({id:a.receipt,root:a.root,domain:a.domain,complete:true})}) and
    s.nextCalls<=1 and (s.nextSpent implies s.nextCalls==1) and
    (s.nextAdmissions.length()==1 implies s.nextHold==6) and s.hold+s.nextHold<=12
  val nextUsesBound=s.nextUses.indices().forall(i=>{val u=s.nextUses.nth(i)
    u.allowed and u.pending.size()==0 and u.admission.floor==u.floor and
    u.admission.fence==u.actual.fence and u.admission.revision==u.actual.revision})
  val factUsesBound=s.facts.uses.indices().forall(i=>factUseValid(s.facts.uses.nth(i)))
  val factDeltasBound=s.facts.deltas.indices().forall(i=>{val d=s.facts.deltas.nth(i)
    d.before==d.after})
  val sourceImagesBound=s.facts.sourceImages.forall(a=>s.facts.sourceImages.forall(b=>a.cut==b.cut implies a==b)) and
    s.facts.sourceImages.contains({cut:s.facts.closure.cut,value:s.facts.sourceValue,rows:s.facts.truth})
  val boundaryBound=s.boundaryRecords.indices().forall(i=>boundaryValid(s.boundaryRecords.nth(i)))
  val safety=originalRetained and familyUnique and winnerBound and continuationBound and prefixBound and aliasesBound and accounting and usesBound and barriersBound and nextBound and nextUsesBound and factUsesBound and factDeltasBound and sourceImagesBound and boundaryBound
  action step={
    nondet protocol=1.to(5).oneOf()
    nondet task=10.to(12).oneOf()
    any {stage(continuation,true),stage(sibling,true),inspect(true),approve(continuation,view,true,true),approve(sibling,view,true,true),
      publish(original,s.fence,true,true),publish(continuation,s.fence,true,true),publish(sibling,s.fence,true,true),otherPublish(external0,true),
      queryWinner(true),loseReply,ack(10),ack(11),alias(protocol,task,10,true),restart,recover(true),ledgerWrite,issue,consume(permit0)}
  }
  action conflicted=init.then(otherPublish(external0,true))
  action inspected=conflicted.then(inspect(true)).then(stage(continuation,true))
  action approved=inspected.then(approve(continuation,v1,true,true))
  action committed=approved.then(publish(continuation,0,true,true))
  action restarted=approved.then(restart).then(recover(true))
  action unknown=init.then(consume(permit0)).then(otherPublish(external0,true))
  run staleOriginalCannotPublishTest=conflicted.then(publish(original,0,true,true).fail())
  run inspectionNeedsQualifiedAbsenceTest=conflicted.then(inspect(false).fail())
  run freshInspectionDoesNotGrantUseTest=inspected.expect(safety and s.calls==0 and not(s.allowed))
  run originalPendingIntentIsRetainedTest=committed.expect(safety and s.staged.contains(original))
  run continuationRequiresFreshAuthorizationTest=inspected.then(approve(continuation,v1,false,true).fail())
  run continuationApprovalRequiresDurabilityTest=inspected.then(approve(continuation,v1,true,false).fail())
  run exactContinuationCanPublishTest=committed.expect(safety and s.winner==11 and s.generation==2)
  run staleApprovalAfterLedgerWriteTest=approved.then(ledgerWrite).then(publish(continuation,0,true,true).fail())
  run staleApprovalAfterFenceChangeTest=restarted.then(publish(continuation,1,true,true).fail())
  run staleInspectionAfterFenceChangeTest=inspected.then(restart).then(recover(true)).then(approve(continuation,v1,true,true).fail())
  run publishStillNeedsCurrentPolicyTest=approved.then(publish(continuation,0,true,false).fail())
  run publishNeedsDurableDecisionTest=approved.then(publish(continuation,0,false,true).fail())
  run changedContentCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("content",999),true))
    .then(approve(continuation.with("content",999),v1,true,true).fail())
  run changedProfileCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("profile",21),true))
    .then(approve(continuation.with("profile",21),v1,true,true).fail())
  run changedBudgetCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("budget",99),true))
    .then(approve(continuation.with("budget",99),v1,true,true).fail())
  run changedHistoryCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("history",99),true))
    .then(approve(continuation.with("history",99),v1,true,true).fail())
  run changedClaimCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("claim",12),true))
    .then(approve(continuation.with("claim",12),v1,true,true).fail())
  run sameIDCannotReplacePendingTest=conflicted.then(stage(original.with("parent",1),true).fail())
  run wrongParentCannotAuthorizeTest=conflicted.then(inspect(true)).then(stage(continuation.with("parent",0),true))
    .then(approve(continuation.with("parent",0),v1,true,true).fail())
  run wrongTipCannotAuthorizeTest=conflicted.then(inspect(true)).then(stage(continuation.with("tip",999),true))
    .then(approve(continuation.with("tip",999),v1,true,true).fail())
  run unknownOriginalCommitCannotBecomeConflictTest=init.then(publish(original,0,true,true)).then(loseReply).then(inspect(true).fail())
  run lostWinnerReplyQueriesSameDecisionTest=committed.then(loseReply).then(queryWinner(true)).expect(safety and s.visibleWinner==11 and s.log.length()==2)
  run originalReplyLossCannotRepublishTest=init.then(publish(original,0,true,true)).then(loseReply).then(publish(original,0,true,true).fail())
  run twoApprovalsStillHaveOneWinnerTest=approved.then(stage(sibling,true)).then(approve(sibling,v1,true,true))
    .then(publish(continuation,0,true,true)).then(publish(sibling,0,true,true).fail())
  run winnerBlocksFreshContinuationTest=committed.then(stage(second,true)).then(approve(second,view,true,true).fail())
  run winnerBlocksNewAbsenceReadTest=committed.then(loseReply).then(inspect(true).fail())
  run lateAcknowledgementIsOnlyHistoryTest=committed.then(loseReply).then(ack(11)).expect(safety and s.winner==11 and s.generation==2)
  run newProtocolAliasPreservesPendingTest=conflicted.then(alias(1,10,10,true)).then(alias(2,11,10,true)).then(alias(3,12,10,true))
    .then(alias(4,12,10,true)).then(alias(5,10,10,true)).expect(safety and s.staged.contains(original) and s.winner == -1)
  run forgedCanonicalProtocolRootTest=conflicted.then(alias(2,12,99,true).fail())
  run aliasRequiresAuthenticatedRegistryTest=conflicted.then(alias(2,12,10,false).fail())
  run unknownCostSurvivesProtocolSwitchTest=unknown.then(alias(1,10,10,true)).then(alias(2,12,10,true)).expect(safety and s.hold==6 and s.spent)
  run reauthorizationDoesNotConsumeTest=approved.expect(safety and s.calls==0 and s.hold==6)
  run missingStageCannotContinueTest=conflicted.then(inspect(true)).then(approve(continuation,v1,true,true).fail())
  run newOwnerCanReauthorizeOriginalIntentTest=inspected.then(restart).then(recover(true)).then(inspect(true)).then(approve(continuation,view,true,true))
    .then(publish(continuation,1,true,true)).expect(safety)
  action unsafePublish(c,observed,authorized)=s'=s.with("generation",s.generation+1).with("allowed",c.allowed).with("winner",c.id)
    .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:observed,reauthorized:authorized}))
  action unsafeApprove(c)=s'=s.with("approvals",s.approvals.union(Set({candidate:c,view:view,authorized:true})))
  action unsafeAckReset=s'=s.with("generation",2).with("allowed",true)
  action unsafeProtocolReset=s'=s.with("spent",false).with("hold",0)
  action unsafeDropOriginal=s'=s.with("staged",s.staged.filter(c=>c.id!=10))
  run silentRebaseContinuationCounterexampleTest=inspected.then(unsafePublish(continuation,v1,false)).expect(not(continuationBound))
  run lostWinnerContinuationCounterexampleTest=init.then(publish(original,0,true,true)).then(loseReply)
    .then(stage(continuation.with("tip",10),true)).then(unsafeApprove(continuation.with("tip",10)))
    .then(unsafePublish(continuation.with("tip",10),view,true)).expect(not(familyUnique))
  run doubleContinuationContinuationCounterexampleTest=committed.then(stage(second,true)).then(unsafeApprove(second))
    .then(unsafePublish(second,view,true)).expect(not(familyUnique))
  run staleApprovalContinuationCounterexampleTest=approved.then(ledgerWrite).then(unsafePublish(continuation,v1,true)).expect(not(continuationBound))
  run semanticSwapContinuationCounterexampleTest=conflicted.then(inspect(true)).then(stage(continuation.with("profile",21),true))
    .then(unsafeApprove(continuation.with("profile",21)))
    .then(unsafePublish(continuation.with("profile",21),view,true)).expect(not(continuationBound))
  run lateAckContinuationCounterexampleTest=committed.then(issue).then(otherPublish(external0.with("id",21).with("parent",2).with("tip",11),true))
    .then(ack(11)).then(unsafeAckReset).then(consume(permit2)).expect(not(usesBound))
  run protocolResetContinuationCounterexampleTest=unknown.then(alias(2,12,10,true)).then(unsafeProtocolReset).expect(not(accounting))
  run droppedIntentContinuationCounterexampleTest=approved.then(unsafeDropOriginal).expect(not(originalRetained))

  // SysML HardFactBarrier -> SessionProgressionProposal -> FinalEffectJoin.
  // One original family, two pending intents, one successor slot, allowance 12.
  action receiptReady=init.then(recordReceipt(7,true))
  action factPending=receiptReady.then(barrier(30,0,true,true))
  action nextReady=receiptReady.then(admitNext(7,1,10,0,0,0,true,true))
  action sendCurrent=if(s.nextAdmissions.length()==1)sendNext(s.nextAdmissions.nth(0)) else all {false,s'=s}
  action compositionStep=any {step,barrier(30,s.fence,true,true),barrier(31,s.fence,true,true),
    queryBarrier(30),loseBarrierReply,recordReceipt(7,true),
    project(30,s.factFloor,s.pending,s.fence,true,true,true),project(31,s.factFloor,s.pending,s.fence,true,true,false),
    admitNext(7,1,10,s.factFloor,s.frontier,s.fence,true,true),loseAdmissionReply,queryAdmission,sendCurrent}

  run barrierReplyLossKeepsOriginalFloorTest=factPending.then(loseBarrierReply).then(queryBarrier(30))
    .expect(safety and s.factFloor==1 and s.pending==Set(30)).then(barrier(30,0,true,true).fail())
  run localPrepareIsNotDurableWithdrawalTest=receiptReady.then(consume(permit0))
    .expect(safety and s.calls==1 and s.factFloor==0)
  run barrierRequiresDurabilityTest=receiptReady.expect(safety and s.factFloor==0).then(barrier(30,0,false,true).fail())
  run pendingFactBlocksSuccessorTest=factPending.expect(safety and s.hold==6).then(admitNext(7,1,10,1,0,0,true,true).fail())
  run twoPendingOnlyResolveOriginalTest=factPending.then(barrier(31,0,true,true))
    .then(project(30,2,Set(30,31),0,true,true,true)).expect(safety and s.pending==Set(31) and s.hold==6)
    .then(admitNext(7,1,10,2,0,0,true,true).fail())
  run changedPendingPrefixRejectsProjectionTest=factPending.then(barrier(31,0,true,true))
    .expect(safety).then(project(30,1,Set(30),0,true,true,true).fail())
  run rejectedProjectionRetainsBarrierTest=factPending.expect(safety and s.pending==Set(30) and s.hold==6)
    .then(project(30,1,Set(30),0,true,false,true).fail())
  run lateBarrierObservationCannotActivateTest=factPending.then(project(30,1,Set(30),0,true,true,true))
    .then(barrier(31,0,true,true)).then(queryBarrier(30)).expect(safety).then(admitNext(7,1,10,2,0,0,true,true).fail())
  run barrierRestartPreservesPendingAndHoldTest=factPending.then(loseBarrierReply).then(restart).then(recover(true))
    .then(queryBarrier(30)).expect(safety and s.pending==Set(30) and s.hold==6)
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run currentOwnerCanResolveOriginalBarrierTest=factPending.then(restart).then(recover(true))
    .then(renewFreshness(closure0,1,1,1,2,true))
    .then(project(30,1,Set(30),1,true,true,true)).then(admitNext(7,1,10,1,0,1,true,true)).expect(safety)
  run receiptRecordingDoesNotAdmitOrRefundTest=factPending.then(recordReceipt(8,true))
    .expect(safety and s.frontier==0 and s.nextHold==0 and s.hold==6)
  run wrongReceiptDomainCannotAdvanceTest=receiptReady.expect(safety).then(admitNext(7,2,10,0,0,0,true,true).fail())
  run forgedReceiptCannotAdvanceTest=init.then(recordReceipt(7,false).fail())
  run missingReceiptCannotAdvanceTest=init.then(admitNext(7,1,10,0,0,0,true,true).fail())
  run relabelledAccountingReceiptCannotAdvanceTest=init.then(recordTypedReceipt(7,10,2,true,true))
    .then(admitNext(7,1,10,0,0,0,true,true).fail())
  run incompleteReceiptCannotAdvanceTest=init.then(recordTypedReceipt(7,10,1,false,true))
    .then(admitNext(7,1,10,0,0,0,true,true).fail())
  run otherRootReceiptCannotAdvanceTest=init.then(recordTypedReceipt(7,99,1,true,true))
    .then(admitNext(7,1,10,0,0,0,true,true).fail())
  run receiptIdentityCannotChangeDomainTest=receiptReady.then(recordTypedReceipt(7,10,2,true,true).fail())
  run wrongOriginalRootCannotAdvanceTest=receiptReady.then(admitNext(7,1,99,0,0,0,true,true).fail())
  run nextAdmissionNeedsDurableOutcomeTest=receiptReady.expect(safety).then(admitNext(7,1,10,0,0,0,false,true).fail())
  run admissionReplyLossDoesNotReserveTwiceTest=nextReady.then(loseAdmissionReply).then(queryAdmission)
    .expect(safety and s.nextHold==6 and s.hold==6).then(admitNext(7,1,10,0,1,0,true,true).fail())
  run withdrawalAfterAdmissionBlocksFinalSendTest=nextReady.then(barrier(30,0,true,true))
    .expect(safety and s.nextCalls==0 and s.nextHold==6).then(sendCurrent.fail())
  run policyWithdrawalAfterAdmissionBlocksFinalSendTest=nextReady.then(otherPublish(external0,true)).expect(safety).then(sendCurrent.fail())
  run restartCannotReviveOldAdmissionTest=nextReady.then(loseAdmissionReply).then(restart).then(recover(true))
    .then(queryAdmission).expect(safety and s.nextHold==6 and s.hold==6).then(sendCurrent.fail())
  run unknownSuccessorCannotSendTwiceTest=nextReady.then(sendCurrent).then(loseAdmissionReply).then(restart).then(recover(true))
    .then(queryAdmission).expect(safety and s.nextCalls==1 and s.nextHold==6 and s.hold==6).then(sendCurrent.fail())
  run unknownOriginalAndSuccessorKeepSharedExposureTest=init.then(consume(permit0)).then(recordReceipt(7,true))
    .then(admitNext(7,1,10,0,0,0,true,true)).then(sendCurrent).then(restart).then(recover(true)).then(queryAdmission)
    .expect(safety and s.calls==1 and s.nextCalls==1 and s.usage == -1 and s.hold+s.nextHold==12).then(sendCurrent.fail())
  run identicalProjectionCannotResetFloorTest=factPending.then(project(30,1,Set(30),0,true,true,true))
    .then(barrier(31,0,true,true)).then(project(31,2,Set(31),0,true,true,true))
    .expect(safety and s.factFloor==2).then(admitNext(7,1,10,0,0,0,true,true).fail())
  run resolvedFactCanAdmitAndSendOnceTest=factPending.then(project(30,1,Set(30),0,true,true,true))
    .then(admitNext(7,1,10,1,0,0,true,true)).then(sendCurrent).expect(safety and s.nextCalls==1).then(sendCurrent.fail())

  action unsafeClearPending=s'=s.with("pending",Set())
  action unsafeRefund=s'=s.with("hold",0).with("nextHold",0)
  action unsafeDuplicateAdmission=s'=s.with("nextAdmissions",s.nextAdmissions.append(s.nextAdmissions.nth(0))).with("nextHold",12)
  action unsafeNextSend=s'=s.with("nextSpent",true).with("nextCalls",s.nextCalls+1)
    .with("nextUses",s.nextUses.append({admission:s.nextAdmissions.nth(0),actual:view,floor:s.factFloor,pending:s.pending,allowed:s.allowed and s.hardAllowed}))
  action unsafeRelabelAdmission=s'=s.with("frontier",1).with("nextHold",6).with("nextAdmissions",
    s.nextAdmissions.append({slot:1,receipt:7,domain:1,floor:s.factFloor,fence:s.fence,revision:s.revision,pending:s.pending,frontier:0,root:10}))
  run clearAllOnFirstProjectionCounterexampleTest=factPending.then(barrier(31,0,true,true))
    .then(project(30,2,Set(30,31),0,true,true,true)).then(unsafeClearPending).expect(not(barriersBound))
  run pendingResetOnRecoveryCounterexampleTest=factPending.then(restart).then(recover(true)).then(unsafeClearPending).expect(not(barriersBound))
  run receiptRefundCounterexampleTest=nextReady.then(recordReceipt(8,true)).then(unsafeRefund).expect(not(accounting) and not(nextBound))
  run lostAdmissionReplyRecreatesClaimCounterexampleTest=nextReady.then(loseAdmissionReply).then(unsafeDuplicateAdmission).expect(not(nextBound))
  run omittedFinalFactGuardCounterexampleTest=nextReady.then(barrier(30,0,true,true)).then(unsafeNextSend).expect(not(nextUsesBound))
  run copiedNewOwnerFenceCounterexampleTest=nextReady.then(restart).then(recover(true)).then(unsafeNextSend).expect(not(nextUsesBound))
  run repeatedUnknownSendCounterexampleTest=nextReady.then(sendCurrent).then(unsafeNextSend).expect(not(nextBound))
  run receiptDomainRelabellingCounterexampleTest=init.then(recordTypedReceipt(7,10,2,true,true))
    .then(unsafeRelabelAdmission).expect(not(nextBound))
  run incompleteReceiptPromotionCounterexampleTest=init.then(recordTypedReceipt(7,10,1,false,true))
    .then(unsafeRelabelAdmission).expect(not(nextBound))

  action projectionStep=any {compositionStep,disconnect,tick,mutateNestedValue,
    deriveFacts(true,Set(1,2),true,false,true),deriveFacts(false,Set(1),true,false,true),
    deriveFacts(true,Set(1,2),false,false,true),deriveFacts(true,Set(1,2),true,true,true),
    changeFactContract(closure0.with("cut",1),Set(2),true),changeFactContract(closure0.with("environment",1),Set(),true),
    renewFreshness(s.facts.closure,s.facts.channel,s.facts.clock,s.fence,s.facts.now+2,true),reloadFrozenSource(true),
    fixedFactDelta(s.facts.closure,s.facts.closure,true)}
  action rejectChangedClosure(c)=factPending.then(changeFactContract(c,Set(),true))
    .then(renewFreshness(c,0,0,0,2,true)).expect(safety).then(project(30,1,Set(30),0,true,true,true).fail())
  run changedBackendRejectsEvidenceTest=rejectChangedClosure(closure0.with("backend",1))
  run changedEngineRejectsEvidenceTest=rejectChangedClosure(closure0.with("engine",1))
  run changedRuleRejectsEvidenceTest=rejectChangedClosure(closure0.with("rule",1))
  run changedQueryRejectsEvidenceTest=rejectChangedClosure(closure0.with("query",1))
  run changedSchemaRejectsEvidenceTest=rejectChangedClosure(closure0.with("schema",1))
  run changedSourceCutRejectsEvidenceTest=rejectChangedClosure(closure0.with("cut",1))
  run changedSourceAuthorityRejectsEvidenceTest=rejectChangedClosure(closure0.with("authority",1))
  run changedScopeRejectsEvidenceTest=rejectChangedClosure(closure0.with("scope",1))
  run changedLimitsRejectsEvidenceTest=rejectChangedClosure(closure0.with("limits",1))
  run changedAdapterRejectsEvidenceTest=rejectChangedClosure(closure0.with("adapter",1))
  run changedCallbackEnvironmentRejectsEvidenceTest=rejectChangedClosure(closure0.with("environment",1))
  run changedFreshnessContractRejectsEvidenceTest=rejectChangedClosure(closure0.with("freshness",1))
  run matchingRowsCannotReplaceCapturedEnvironmentTest=factPending.then(changeFactContract(closure0.with("environment",1),Set(),true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run newClosureRequiresFreshDerivationTest=factPending.then(changeFactContract(closure0.with("rule",1),Set(),true))
    .then(deriveFacts(true,Set(1,2),true,false,true)).then(project(30,1,Set(30),0,true,true,true)).expect(safety)
  run incompleteNegativeCannotClearBarrierTest=factPending.then(deriveFacts(false,Set(1,2),true,false,true))
    .expect(safety and s.pending==Set(30) and s.hold==6).then(project(30,1,Set(30),0,true,true,true).fail())
  run declaredCompleteButPartialScopeCannotPublishTest=factPending.then(deriveFacts(true,Set(1),true,false,true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run timeoutWithFullScopeCannotPublishTest=factPending.then(deriveFacts(true,Set(1,2),true,true,true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run hiddenCounterevidenceCannotBecomeNegativeTest=factPending.then(changeFactContract(closure0.with("cut",1),Set(2),true))
    .then(renewFreshness(s.facts.closure,0,0,0,2,true)).then(deriveFacts(true,Set(1),true,false,true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run completeCounterevidenceCannotGrantTest=factPending.then(changeFactContract(closure0.with("cut",1),Set(2),true))
    .then(renewFreshness(s.facts.closure,0,0,0,2,true)).then(deriveFacts(true,Set(1,2),true,false,true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run sameWorldDeltaCannotResolveFactIntentTest=factPending.then(fixedFactDelta(closure0,closure0,true))
    .expect(safety and s.pending==Set(30) and s.factFloor==1 and s.hold==6)
  run pointwiseDeltaRejectsChangedFactWorldTest=factPending.then(fixedFactDelta(closure0,closure0.with("cut",1),true).fail())
  run nakedMutableRowsCannotPublishTest=factPending.then(deriveFacts(true,Set(1,2),false,false,true)).then(mutateNestedValue)
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run detachedCandidateSurvivesCallerMutationTest=factPending.then(deriveFacts(true,Set(1,2),true,false,true)).then(mutateNestedValue)
    .then(project(30,1,Set(30),0,true,true,true)).expect(safety and s.facts.installed.value==0 and s.facts.hostValue==1)
  run detachedInstalledImageSurvivesCallerMutationTest=nextReady.then(mutateNestedValue).then(sendCurrent)
    .expect(safety and s.facts.installed.value==0 and s.facts.hostValue==1)
  run mutatedInputCannotRehashUnderOldSourceCutTest=factPending.then(mutateNestedValue)
    .then(deriveFacts(true,Set(1,2),true,false,true).fail())
  run reloadUsesOriginalSourceImageTest=factPending.then(mutateNestedValue).then(reloadFrozenSource(true))
    .then(deriveFacts(true,Set(1,2),true,false,true)).then(project(30,1,Set(30),0,true,true,true))
    .expect(safety and s.facts.installed.value==0)
  run sourceCutCannotChangeCommittedRowsTest=factPending.then(changeFactContract(closure0,Set(2),true).fail())
  run revisitedSourceCutCannotRebindBodyTest=factPending.then(changeFactContract(closure0.with("cut",1),Set(2),true))
    .then(mutateNestedValue).then(changeFactContract(closure0,Set(),true).fail())
  run disconnectedOrderedSourceBlocksAdmissionTest=receiptReady.then(disconnect).then(admitNext(7,1,10,0,0,0,true,true).fail())
  run disconnectAfterAdmissionBlocksFinalUseTest=nextReady.then(disconnect).then(sendCurrent.fail())
  run boundedPromisePermitsOfflineUseBeforeExpiryTest=boundedInit.then(recordReceipt(7,true)).then(disconnect)
    .then(admitNext(7,1,10,0,0,0,true,true)).then(sendCurrent).expect(safety and not(s.facts.connected))
  run expiryAtExactBoundaryBlocksFinalUseTest=boundedInit.then(recordReceipt(7,true)).then(admitNext(7,1,10,0,0,0,true,true))
    .then(tick).then(tick).expect(safety and s.nextHold==6).then(sendCurrent.fail())
  run restartCannotReuseOldClockPromiseTest=boundedInit.then(recordReceipt(7,true)).then(restart).then(recover(true))
    .then(admitNext(7,1,10,0,0,1,true,true).fail())
  run lateSourceCallbackCannotRenewOldSessionTest=receiptReady.then(disconnect).then(renewFreshness(closure0,0,0,0,2,true).fail())
  run unqualifiedRenewalCannotExtendPromiseTest=boundedInit.then(tick).then(tick)
    .then(renewFreshness(s.facts.closure,0,0,0,4,false).fail())
  run reconnectRequiresCurrentSourcePromiseTest=receiptReady.then(disconnect).then(renewFreshness(closure0,1,0,0,2,true))
    .then(admitNext(7,1,10,0,0,0,true,true)).then(sendCurrent).expect(safety)
  run renewedSourceCannotEraseUnknownExposureTest=nextReady.then(sendCurrent).then(disconnect)
    .then(renewFreshness(closure0,1,0,0,2,true)).expect(safety and s.nextHold==6 and s.hold==6).then(sendCurrent.fail())
  run renewedEvidenceCannotReuseOtherScopePromiseTest=factPending.then(changeFactContract(closure0.with("scope",1),Set(),true))
    .then(deriveFacts(true,Set(1,2),true,false,true)).then(project(30,1,Set(30),0,true,true,true).fail())
  run validNewCutCannotResolveOtherOriginalIntentTest=factPending.then(changeFactContract(closure0.with("cut",1),Set(),true))
    .then(renewFreshness(s.facts.closure,0,0,0,2,true)).then(deriveFacts(true,Set(1,2),true,false,true))
    .then(project(30,1,Set(30),0,true,true,true).fail())
  run originalIntentCanInstallItsProposedCutTest=receiptReady.then(barrierForCut(30,1,0,true,true))
    .then(changeFactContract(closure0.with("cut",1),Set(),true)).then(renewFreshness(s.facts.closure,0,0,0,2,true))
    .then(deriveFacts(true,Set(1,2),true,false,true)).then(project(30,1,Set(30),0,true,true,true))
    .then(admitNext(7,1,10,1,0,0,true,true)).then(sendCurrent).expect(safety and s.hold+s.nextHold==12)

  action unsafeFactUse(e,readValue)=s'=s.with("facts",s.facts.with("uses",s.facts.uses.append(factUse(s.facts,e,s.fence).with("readValue",readValue))))
  action unsafeDeltaWorldChange=s'=s.with("facts",s.facts.with("deltas",s.facts.deltas.append({before:closure0,after:closure0.with("cut",1)})))
  run equalRowsOldClosureCounterexampleTest=factPending.then(changeFactContract(closure0.with("environment",1),Set(),true))
    .then(unsafeFactUse(s.facts.candidate,0)).expect(not(factUsesBound))
  run incompleteNegativePromotionCounterexampleTest=factPending.then(deriveFacts(false,Set(1,2),true,false,true))
    .then(unsafeFactUse(s.facts.candidate,0)).expect(not(factUsesBound))
  run partialScopePromotionCounterexampleTest=factPending.then(deriveFacts(true,Set(1),true,false,true))
    .then(unsafeFactUse(s.facts.candidate,0)).expect(not(factUsesBound))
  run mutableAliasReadCounterexampleTest=nextReady.then(mutateNestedValue)
    .then(unsafeFactUse(s.facts.installed,s.facts.hostValue)).expect(not(factUsesBound))
  run pointwiseCrossWorldPromotionCounterexampleTest=factPending.then(unsafeDeltaWorldChange).expect(not(factDeltasBound))
  run disconnectedSourcePromotionCounterexampleTest=nextReady.then(disconnect)
    .then(unsafeFactUse(s.facts.installed,0)).expect(not(factUsesBound))
  run expiredPromisePromotionCounterexampleTest=boundedInit.then(tick).then(tick)
    .then(unsafeFactUse(s.facts.installed,0)).expect(not(factUsesBound))
  run restartClockEpochPromotionCounterexampleTest=boundedInit.then(restart).then(recover(true))
    .then(unsafeFactUse(s.facts.installed,0)).expect(not(factUsesBound))
  run rehashedAliasUnderOldCutCounterexampleTest=factPending.then(mutateNestedValue)
    .then(unsafeFactUse(s.facts.candidate.with("value",s.facts.hostValue),s.facts.hostValue)).expect(not(factUsesBound))

  // Wrapper instantiates some qualified-Host premises of the existing abstract
  // projection action. All production entrypoint coverage remains an acceptance
  // obligation; the abstract projectionStep does not implement a C ABI.
  action projectFromBoundary(e)=all {boundaryValid(boundaryCheck(e)),project(30,s.factFloor,s.pending,s.fence,true,true,true)}
  // Sender coordinates are trusted host/channel observations, not payload fields.
  action projectFromSender(e,vm,call,epoch)=all {boundaryValid(boundaryCheckFrom(e,vm,call,epoch)),project(30,s.factFloor,s.pending,s.fence,true,true,true)}
  // Previously admitted Rust-owned data is not a live VM callback. Its receipt
  // survives producer return/restart, while current source custody still gates CAS.
  action projectFromCaptured(e,worker,sourceQualified)=all {
    s.boundaryRecords.indices().exists(i=>{val r=s.boundaryRecords.nth(i)
      r.evidence==e and boundaryValid(r)}),
    e.configurationSchema==s.configurationSchema,e.normalizer==s.configurationNormalizer,
    e.programModule==s.schemeModule,e.environment==s.facts.closure.environment,
    e.cut==s.facts.closure.cut,e.input==s.facts.sourceValue,e.output==s.facts.sourceValue,
    project(30,s.factFloor,s.pending,worker,true,sourceQualified,true)}
  action boundaryStep=any {projectionStep,recordBoundary(boundary0),recordBoundary(boundary0.with("kind",1)),
    semanticRestart,endBorrow,rebindConfiguration,loseVolatileCaptures,projectFromBoundary(boundary0),projectFromCaptured(boundary0,s.fence,true)}
  run jsonAndSchemeShareSemanticOutputTest=init.then(recordBoundary(boundary0)).then(recordBoundary(boundary0.with("kind",1)))
    .expect(safety and s.boundaryRecords.length()==2 and s.calls==0 and s.frontier==0 and s.hold==6)
  run jsonCannotSkipGovernanceTest=init.then(recordBoundary(boundary0.with("governanceChecked",false)).fail())
  run schemeCannotSkipConfigurationValidationTest=init.then(recordBoundary(boundary0.with("kind",1).with("schemaChecked",false)).fail())
  run unconstrainedDefaultSchemaCannotAdmitTest=init.then(recordBoundary(boundary0.with("configurationSchema",0)).fail())
  run changedConfigurationSchemaRejectsOldCaptureTest=factPending.then(rebindConfiguration).then(projectFromBoundary(boundary0).fail())
  run changedNormalizerRejectsCaptureTest=init.then(recordBoundary(boundary0.with("normalizer",2)).fail())
  run changedProgramRejectsCaptureTest=init.then(recordBoundary(boundary0.with("programModule",1)).fail())
  run changedCapturedEnvironmentRejectsCaptureTest=init.then(recordBoundary(boundary0.with("environment",1)).fail())
  // Source labels copied from two agreeing live aliases cannot replace the
  // original captured binding. Native refinement must freeze that original.
  run coordinatedLiveProfileLabelsCannotReplaceOriginalCaptureTest=init
    .then(recordBoundary(boundary0.with("profile",21).with("environment",1)).fail())
  run newSourceCutCannotUseOldCaptureTest=factPending.then(changeFactContract(closure0.with("cut",1),Set(),true))
    .then(projectFromBoundary(boundary0).fail())
  run callerOutputCannotReplaceCommittedValueTest=init.then(recordBoundary(boundary0.with("output",1)).fail())
  run unreadableBorrowIsOutsideAcceptedContractTest=init.then(recordBoundary(boundary0.with("readable",false)).fail())
  run concurrentBorrowMutationIsOutsideAcceptedContractTest=init.then(recordBoundary(boundary0.with("stable",false)).fail())
  run borrowedOnlyDataCannotEnterAsyncQueueTest=init.then(recordBoundary(boundary0.with("owned",false)).fail())
  run retainedSchemePointerCannotEnterAsyncQueueTest=init.then(recordBoundary(boundary0.with("retainedPointer",true)).fail())
  run reentrantCallbackCannotPublishUnderGuardTest=factPending.then(projectFromBoundary(boundary0.with("reentrant",true)).fail())
  run oldVMCallbackCannotInstallProjectionTest=factPending.then(recordBoundary(boundary0)).then(semanticRestart)
    .then(projectFromBoundary(boundary0).fail())
  run oldSenderCannotCopyFreshCallbackLabelsTest=factPending.then(semanticRestart)
    .then(projectFromSender(boundary0.with("vm",1).with("call",1).with("epoch",1),0,0,0).fail())
  run oldBorrowCallCannotInstallProjectionTest=factPending.then(recordBoundary(boundary0)).then(endBorrow)
    .then(projectFromBoundary(boundary0).fail())
  run preflightSuccessDoesNotAdmitOrRefundTest=factPending.then(recordBoundary(boundary0))
    .expect(safety and s.pending==Set(30) and s.frontier==0 and s.hold==6 and s.calls==0)
  run freshCaptureStillNeedsCurrentFreshnessTest=factPending.then(recordBoundary(boundary0)).then(disconnect)
    .then(projectFromBoundary(boundary0).fail())
  run ownedRustEffectSurvivesProducerVMRestartTest=nextReady.then(recordBoundary(boundary0)).then(semanticRestart).then(sendCurrent)
    .expect(safety and s.nextCalls==1 and s.hold+s.nextHold==12)
  run ownedRustEffectSurvivesBorrowReturnTest=nextReady.then(recordBoundary(boundary0)).then(endBorrow).then(sendCurrent)
    .expect(safety and s.nextCalls==1 and s.nextHold==6)
  run validBoundaryReachesExistingProjectionTest=factPending.then(recordBoundary(boundary0)).then(projectFromBoundary(boundary0))
    .then(admitNext(7,1,10,1,0,0,true,true)).then(sendCurrent).expect(safety and s.nextCalls==1)
  run ownedCandidateCanPublishAfterBorrowReturnTest=factPending.then(recordBoundary(boundary0)).then(endBorrow)
    .then(projectFromCaptured(boundary0,0,true)).expect(safety and s.pending.size()==0 and s.hold==6)
  run ownedCandidateCanPublishAfterVMRestartTest=factPending.then(recordBoundary(boundary0)).then(semanticRestart)
    .then(projectFromCaptured(boundary0,0,true)).then(admitNext(7,1,10,1,0,0,true,true)).then(sendCurrent).expect(safety)
  run unrecordedPreflightCannotPublishOwnedDataTest=factPending.then(projectFromCaptured(boundary0,0,true).fail())
  run oldSourceWorkerCannotPublishOwnedCaptureTest=factPending.then(recordBoundary(boundary0)).then(restart).then(recover(true))
    .then(renewFreshness(closure0,1,1,1,2,true)).then(projectFromCaptured(boundary0,0,true).fail())
  run freshSourceOwnerCanReuseOriginalOwnedCaptureTest=factPending.then(recordBoundary(boundary0)).then(restart).then(recover(true))
    .then(renewFreshness(closure0,1,1,1,2,true)).then(projectFromCaptured(boundary0,1,true))
    .then(admitNext(7,1,10,1,0,1,true,true)).then(sendCurrent).expect(safety and s.nextCalls==1)
  run changedConfigurationBlocksOwnedCapturePublicationTest=factPending.then(recordBoundary(boundary0)).then(rebindConfiguration)
    .then(projectFromCaptured(boundary0,0,true).fail())
  run lostCaptureCannotManufactureOwnedArtifactTest=factPending.then(recordBoundary(boundary0)).then(loseVolatileCaptures)
    .expect(safety and s.pending==Set(30) and s.hold==6).then(projectFromCaptured(boundary0,0,true).fail())
  action unsafeBoundaryRecord(e)=s'=s.with("boundaryRecords",s.boundaryRecords.append(boundaryCheck(e)))
  run agreeingLiveAliasesWithoutOriginalSnapshotCounterexampleTest=init
    .then(unsafeBoundaryRecord(boundary0.with("profile",21).with("environment",1)))
    .expect(not(boundaryBound) and s.hold==6 and s.calls==0)
  action unsafePreflightGrant=s'=s.with("pending",Set()).with("frontier",1).with("hold",0)
  run jsonGovernanceBypassCounterexampleTest=init.then(unsafeBoundaryRecord(boundary0.with("governanceChecked",false))).expect(not(boundaryBound))
  run retainedForeignPointerCounterexampleTest=init.then(unsafeBoundaryRecord(boundary0.with("retainedPointer",true))).expect(not(boundaryBound))
  run oldVMCallbackPromotionCounterexampleTest=factPending.then(semanticRestart).then(unsafeBoundaryRecord(boundary0)).expect(not(boundaryBound))
  run preflightAsExecutionPermitCounterexampleTest=factPending.then(recordBoundary(boundary0)).then(unsafePreflightGrant)
    .expect(not(barriersBound) and not(nextBound) and not(accounting))
  action unsafeOldSenderRecord=s'=s.with("boundaryRecords",s.boundaryRecords.append(
    boundaryCheckFrom(boundary0.with("vm",s.semanticVM).with("call",s.ffiCall).with("epoch",s.captureEpoch),0,0,0)))
  run copiedFreshLabelsFromOldSenderCounterexampleTest=factPending.then(semanticRestart).then(unsafeOldSenderRecord).expect(not(boundaryBound))
}

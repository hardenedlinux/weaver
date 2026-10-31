module PublicationRecovery {
  type Decision = {payload:int,parent:int,requestedFence:int,outcome:int,resultHead:int,resultFence:int,review:Set[Review],validatedFence:int,validatedCut:Cut,validatedEpoch:int}
  type Event = {id:int,decision:Decision}
  type Proposal = {id:int,payload:int,parent:int,fence:int}
  type Review = {command:Proposal,artifact:int,head:int,fence:int,parentPolicy:int,parentSchema:int,cut:Cut,epoch:int}
  type ReviewEntry={review:Review,owner:int,term:int,index:int}
  // Opaque references to Lean-qualified bindings. No role, subject, public-key,
  // scope, audience or signature semantics are evaluated in this schedule owner.
  type SourceDecision={slot:int,credential:int}
  type SourceUse={credential:int,epoch:int,owner:int,command:int,purpose:int,artifact:int}
  type SourceCut={epoch:int,owner:int,revoked:Set[int],decisions:List[SourceDecision],registry:List[ReviewEntry],head:int,fence:int}
  type SourceObservation={use:SourceUse,cut:SourceCut,session:int}
  type Part={id:int,payload:int,key:int}
  type Cut={publication:List[Part],consumption:List[Part],account:List[Part],history:List[Part]}
  type Intent={id:int,payload:int,key:int,kind:int,scope:int,epoch:int,before:Cut}
  type FloorOutcome={intent:Intent,committed:bool,after:Cut,epoch:int}
  // Only this existing recovery owner models the protocol envelope. Domain
  // publication/account/effect validity remains with its existing owner.
  type Floor={epoch:int,cut:Cut,outcomes:List[FloorOutcome],pending:Set[Intent],local:Cut,
    observed:Cut,observedEpoch:int,haveRead:bool,active:bool,burned:Set[int],admitted:Set[int],handles:Set[int],tickets:Set[{key:int,cut:Cut,epoch:int}],
    owner:int,liveOwners:Set[int],egressOwners:Set[int],handoff:bool,calls:int,external:int,
    registry:List[ReviewEntry],registrarOwner:int,registrarTerm:int,
    sourceDecisions:List[SourceDecision],sourceRevoked:Set[int]}
  type Ledger = {head:int,fence:int,policy:int,schema:int,records:int->Decision,log:List[Event],commits:List[Event],held:int,calls:int,floor:Floor,pending:Set[Proposal],reviews:int->Set[Review],reviewProjection:List[ReviewEntry],sourceUses:Set[SourceUse],requiredReviews:Set[int],sourceObservations:Set[SourceObservation],sourceImage:SourceCut,sourceReachable:bool,sourceSession:int}
  var authority:Ledger
  val ids=Set(0,1,2)
  val empty={payload:0,parent:-1,requestedFence:1,outcome:0,resultHead:-1,resultFence:1,review:Set(),validatedFence:1,validatedCut:emptyCut,validatedEpoch:0}
  val safe = authority.head==authority.commits.length()-1 and authority.held==4 and authority.calls==1 and
    authority.pending.forall(p=>authority.records.get(p.id).outcome==0 and authority.pending.forall(q=>q.id!=p.id or q==p)) and
    authority.log.indices().forall(i=>authority.records.get(authority.log.nth(i).id)==authority.log.nth(i).decision) and
    authority.commits.indices().forall(i=>authority.commits.nth(i).decision.outcome==1 and
      authority.commits.nth(i).decision.resultHead==i and authority.commits.nth(i).decision.parent==i-1) and
    (authority.head>=0 implies authority.policy==authority.commits.nth(authority.head).decision.payload and authority.schema==authority.policy) and floorSafe(authority.floor)
  pure val emptyCut={publication:List(),consumption:List(),account:List(),history:List()}
  pure val floor0={epoch:0,cut:emptyCut,outcomes:List(),pending:Set(),local:emptyCut,observed:emptyCut,observedEpoch:0,haveRead:true,active:true,burned:Set(),admitted:Set(),handles:Set(),tickets:Set(),owner:1,liveOwners:Set(1),egressOwners:Set(1),handoff:false,calls:0,external:0,registry:List(),registrarOwner:1,registrarTerm:0,sourceDecisions:List({slot:0,credential:100}),sourceRevoked:Set()}
  pure val sourceCut0={epoch:0,owner:1,revoked:Set(),decisions:List({slot:0,credential:100}),registry:List(),head:-1,fence:1}
  action init = authority'={head:-1,fence:1,policy:0,schema:0,records:ids.mapBy(_=>empty),log:[],commits:[],held:4,calls:1,floor:floor0,pending:Set(),reviews:ids.mapBy(_=>Set()),reviewProjection:List(),sourceUses:Set(),requiredReviews:Set(),sourceObservations:Set(),sourceImage:sourceCut0,sourceReachable:true,sourceSession:0}
  def canStage(q:Proposal):bool={val d=authority.records.get(q.id)
    authority.pending.forall(p=>p.id!=q.id or p==q) and
      (d.outcome==0 or (d.payload==q.payload and d.parent==q.parent and d.requestedFence==q.fence))}
  action stage(q:Proposal):bool={val d=authority.records.get(q.id)
    all {canStage(q),
      authority'=authority.with("pending",if(d.outcome==0)authority.pending.union(Set(q)) else authority.pending)}}
  action stageRequiringReview(q:Proposal):bool={val d=authority.records.get(q.id)
    all {canStage(q),d.outcome==0 or authority.requiredReviews.contains(q.id),
      authority'=authority.with("requiredReviews",authority.requiredReviews.union(Set(q.id)))
        .with("pending",if(d.outcome==0)authority.pending.union(Set(q)) else authority.pending)}}
  action decidePublication(id:int,payload:int,parent:int,fence:int,review:Set[Review],qualified:bool):bool = {
    val accepted=parent==authority.head and fence>=authority.fence and qualified
    val d={payload:payload,parent:parent,requestedFence:fence,outcome:if(accepted)1 else 2,
      resultHead:if(accepted)authority.head+1 else authority.head,resultFence:if(accepted)fence else authority.fence,review:review,validatedFence:authority.fence,validatedCut:authority.floor.cut,validatedEpoch:authority.floor.epoch}
    val event={id:id,decision:d}
    all {authority.records.get(id).outcome==0,
      authority.pending.forall(p=>p.id!=id or p=={id:id,payload:payload,parent:parent,fence:fence}),
      authority'=authority.with("records",authority.records.set(id,d)).with("log",authority.log.append(event))
        .with("pending",authority.pending.filter(p=>p.id!=id))
        .with("commits",if(accepted)authority.commits.append(event) else authority.commits)
        .with("head",d.resultHead).with("fence",d.resultFence)
        .with("policy",if(accepted)payload else authority.policy).with("schema",if(accepted)payload else authority.schema)}
  }
  // Native local review latch. Unlatched source RPCs retain their explicit
  // trusted-source profile. This local guard does NOT establish floor recovery,
  // registrar incarnation or independent semantic qualification.
  def locallyApproved(q:Proposal):bool=authority.reviews.get(q.id).size()==1 and authority.reviews.get(q.id).exists(r=>
    r.command==q and r.head==authority.head and r.fence==authority.fence and
      r.parentPolicy==authority.policy and r.parentSchema==authority.schema)
  action publish(id:int,payload:int,parent:int,fence:int):bool = all {
    not(authority.requiredReviews.contains(id)) or parent!=authority.head or fence<authority.fence or
      locallyApproved({id:id,payload:payload,parent:parent,fence:fence}),
    decidePublication(id,payload,parent,fence,if(authority.requiredReviews.contains(id))authority.reviews.get(id) else Set(),true)}
  // Trusted review registration is a Host premise: actual Delta/schema/replay
  // qualification and independent parent selection are not simulated here.
  // Registration may be separate from stage; the barrier remains until the
  // original final outcome, even if registration or its acknowledgment fails.
  // The existing independent floor owns the durable full-content registration.
  // reviews and reviewProjection are recoverable local projections, not authority.
  pure def projectedReviews(log:List[ReviewEntry],id:int):Set[Review]=log.foldl(Set(),(acc,e)=>
    if(e.review.command.id==id)acc.union(Set(e.review)) else acc)
  def anchoredReviews(id:int):Set[Review]=projectedReviews(authority.floor.registry,id)
  val registryRecovered=authority.reviewProjection==authority.floor.registry and ids.forall(id=>authority.reviews.get(id)==anchoredReviews(id))
  // Trusted authority event: the semantic qualification receipt is supplied by
  // the existing Lean/adapter boundary. This is not a source-role issuance API.
  action recordSourceDecision(slot:int,credential:int):bool={
    val existing=authority.floor.sourceDecisions.indices().filter(i=>authority.floor.sourceDecisions.nth(i).slot==slot)
    if(existing!=Set()) all {existing.exists(i=>authority.floor.sourceDecisions.nth(i).credential==credential),authority'=authority}
    else all {slot==authority.floor.registrarTerm,
      authority.floor.sourceDecisions.indices().forall(i=>authority.floor.sourceDecisions.nth(i).credential!=credential),
      authority'=authority.with("floor",authority.floor.with("sourceDecisions",authority.floor.sourceDecisions.append({slot:slot,credential:credential})))}}
  action revokeSource(credential:int):bool=authority'=authority.with("floor",authority.floor.with("sourceRevoked",authority.floor.sourceRevoked.union(Set(credential))))
  def sourceUseCurrent(use:SourceUse):bool=use.epoch==authority.floor.registrarTerm and use.owner==authority.floor.registrarOwner and
    not(authority.floor.sourceRevoked.contains(use.credential)) and authority.floor.sourceDecisions.indices().exists(i=>
      authority.floor.sourceDecisions.nth(i)=={slot:use.epoch,credential:use.credential})
  action captureSourceUse(use:SourceUse):bool=all {sourceUseCurrent(use),authority'=authority.with("sourceUses",authority.sourceUses.union(Set(use)))}
  action registerUsingSource(use:SourceUse,r:Review):bool=all {authority.sourceUses.contains(use),sourceUseCurrent(use),
    use.command==r.command.id,use.purpose==0,use.artifact==r.artifact,registerReviewBy(use.owner,use.epoch,r)}
  action publishUsingSource(use:SourceUse,q:Proposal,r:Review):bool=all {authority.sourceUses.contains(use),sourceUseCurrent(use),
    use.command==q.id,use.purpose==1,use.artifact==r.artifact,publishReviewedBy(use.owner,use.epoch,q,r)}
  // Read/restore/final-join timing only. Binding and signature meaning remain SPEC-owned.
  def sourceAuthorityCut:SourceCut={epoch:authority.floor.registrarTerm,owner:authority.floor.registrarOwner,
    revoked:authority.floor.sourceRevoked,decisions:authority.floor.sourceDecisions,registry:authority.floor.registry,head:authority.head,fence:authority.fence}
  action readSourceObservation(use:SourceUse):bool=all {authority.sourceReachable,sourceUseCurrent(use),
    authority'=authority.with("sourceUses",authority.sourceUses.union(Set(use)))
      .with("sourceObservations",authority.sourceObservations.union(Set({use:use,cut:sourceAuthorityCut,session:authority.sourceSession}))).with("sourceImage",sourceAuthorityCut)}
  // Fresh channel-context reference from the adapter, not an identity issuer.
  action reconnectSourceObserver=authority'=authority.with("sourceSession",authority.sourceSession+1)
  // Process recovery preserves durable authority, but never the authority-read
  // capability of the previous observer incarnation. Context freshness is a Host premise.
  action restartSourceObserver=authority'=authority.with("sourceSession",authority.sourceSession+1).with("sourceObservations",Set())
  action restoreSourceObservation(observed:SourceObservation):bool=authority'=authority.with("sourceImage",observed.cut)
  action sourceAvailability(available:bool):bool=authority'=authority.with("sourceReachable",available)
  def joinedSourceObservation(observed:SourceObservation):bool=authority.sourceReachable and authority.sourceObservations.contains(observed) and
    observed.session==authority.sourceSession and observed.cut==sourceAuthorityCut and authority.sourceImage==sourceAuthorityCut
  action registerAtSourceObservation(observed:SourceObservation,r:Review):bool=all {
    joinedSourceObservation(observed),registerUsingSource(observed.use,r)}
  action publishAtSourceObservation(observed:SourceObservation,q:Proposal,r:Review):bool=all {
    joinedSourceObservation(observed),publishUsingSource(observed.use,q,r)}
  action registerReviewBy(actor:int,term:int,r:Review):bool={
    val existing=anchoredReviews(r.command.id)
    if(existing!=Set()) all {existing==Set(r),authority'=authority}
    else all {actor==authority.floor.registrarOwner,term==authority.floor.registrarTerm,
      authority.pending.contains(r.command),r.head==authority.head,r.command.parent==r.head,r.fence==authority.fence,
      r.parentPolicy==authority.policy,r.parentSchema==authority.schema,
      r.cut==authority.floor.cut,r.epoch==authority.floor.epoch,
      val entry={review:r,owner:actor,term:term,index:authority.floor.registry.length()}
      authority'=authority.with("floor",authority.floor.with("registry",authority.floor.registry.append(entry)))}}
  action recoverReviewsBy(actor:int,term:int):bool=all {actor==authority.floor.registrarOwner,term==authority.floor.registrarTerm,
    authority'=authority.with("reviews",ids.mapBy(id=>anchoredReviews(id))).with("reviewProjection",authority.floor.registry)}
  action restoreReviewImage(image:List[ReviewEntry]):bool=authority'=authority.with("reviews",ids.mapBy(id=>projectedReviews(image,id))).with("reviewProjection",image)
  action rotateRegistrar=authority'=authority.with("floor",authority.floor.with("registrarOwner",2).with("registrarTerm",authority.floor.registrarTerm+1))
  action observeRegistration(r:Review):bool=all {anchoredReviews(r.command.id)==Set(r),authority'=authority}
  action registerReview(r:Review):bool=registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,r)
    .then(recoverReviewsBy(authority.floor.registrarOwner,authority.floor.registrarTerm))
  // The exact native SPEC replay/ID/schema check belongs to Rust's upstream
  // adapter. This schedule receives its qualified result, not a second Cedar evaluator.
  action registerReplayChecked(r:Review,checked:bool):bool=all {checked,
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,r)}
  action publishReviewedBy(actor:int,term:int,q:Proposal,r:Review):bool={
    val qualified=authority.reviews.get(q.id)==Set(r) and r.command==q and r.head==authority.head and r.fence==authority.fence and r.parentPolicy==authority.policy and r.parentSchema==authority.schema and
      r.cut==authority.floor.cut and r.epoch==authority.floor.epoch and authority.floor.pending==Set() and not(authority.floor.handoff)
    all {actor==authority.floor.registrarOwner,term==authority.floor.registrarTerm,registryRecovered,
      decidePublication(q.id,q.payload,q.parent,q.fence,Set(r),qualified)}
  }
  action publishReviewed(q:Proposal,r:Review):bool=publishReviewedBy(authority.floor.registrarOwner,authority.floor.registrarTerm,q,r)
  val reviewSafe=safe and authority.floor.registry.indices().forall(i=>{
    val e=authority.floor.registry.nth(i)
    e.index==i and authority.floor.registry.indices().forall(j=>i==j or authority.floor.registry.nth(j).review.command.id!=e.review.command.id)}) and
    authority.commits.indices().forall(i=>{
    val e=authority.commits.nth(i)
    e.decision.review.exists(r=>anchoredReviews(e.id)==Set(r) and
        r.command=={id:e.id,payload:e.decision.payload,parent:e.decision.parent,fence:e.decision.requestedFence} and
        r.head==e.decision.parent and r.fence==e.decision.validatedFence and
        r.cut==e.decision.validatedCut and r.epoch==e.decision.validatedEpoch)})
  action replay(id:int,payload:int,parent:int,fence:int):bool = all {
    authority.records.get(id).outcome!=0,authority.records.get(id).payload==payload,authority.records.get(id).parent==parent,authority.records.get(id).requestedFence==fence,authority'=authority}
  action observe = authority'=authority
  action restart = authority'=authority
  action unsafeHeadOnly = authority'=authority.with("head",authority.head+1)
  action unsafeForget(id:int):bool = all {authority.records.get(id).outcome!=0,authority'=authority.with("records",authority.records.set(id,empty))}
  action unsafeRebind(id:int):bool = all {authority.records.get(id).outcome!=0,authority'=authority.with("records",authority.records.set(id,authority.records.get(id).with("payload",1-authority.records.get(id).payload)))}
  pure def floorPost(c:Cut,q:Intent):Cut={val p={id:q.id,payload:q.payload,key:q.key}
    if(q.kind==0)c.with("publication",c.publication.append(p)) else if(q.kind==1)c.with("consumption",c.consumption.append(p))
    else if(q.kind==2)c.with("account",c.account.append(p)) else c.with("history",c.history.append(p))}
  pure def floorGate(f:Floor,q:Intent):bool=q.scope==7 and q.epoch==f.epoch and q.before==f.cut and Set(0,1,2,3).contains(q.kind) and
    (q.kind!=1 or f.cut.consumption.indices().forall(i=>f.cut.consumption.nth(i).key!=q.key)) and
    (q.kind!=2 or (f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==q.key) and f.cut.account.indices().forall(i=>f.cut.account.nth(i).key!=q.key)))
  pure def floorSafe(f:Floor):bool={val committed=f.outcomes.foldl(List(),(acc,d)=>if(d.committed)acc.append(d) else acc)
    f.cut==(if(committed.length()==0)emptyCut else committed.nth(committed.length()-1).after) and
    f.outcomes.indices().forall(i=>f.outcomes.indices().forall(j=>i==j or f.outcomes.nth(i).intent.id!=f.outcomes.nth(j).intent.id)) and
    committed.indices().forall(i=>{val d=committed.nth(i)
      d.intent.scope==7 and d.intent.epoch==d.epoch and d.intent.before==(if(i==0)emptyCut else committed.nth(i-1).after) and d.after==floorPost(d.intent.before,d.intent)}) and
    f.liveOwners==f.egressOwners and (f.liveOwners==Set() or f.liveOwners==Set(f.owner)) and
    (f.active implies f.haveRead and f.local==f.cut and f.observed==f.cut and f.observedEpoch==f.epoch and f.pending==Set() and not(f.handoff) and f.liveOwners==Set(f.owner)) and
    f.calls==f.external and f.calls==f.admitted.size() and f.admitted.forall(k=>f.burned.contains(k)) and f.burned.forall(k=>f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==k))}
  def f=authority.floor
  pure val consume0={id:10,payload:100,key:1,kind:1,scope:7,epoch:0,before:emptyCut}
  pure val publication0=consume0.with("id",11).with("kind",0).with("payload",101)
  pure val account0=consume0.with("id",12).with("kind",2).with("payload",102).with("before",floorPost(emptyCut,consume0))
  pure val history0=consume0.with("id",13).with("kind",3).with("payload",103).with("before",floorPost(account0.before,account0))
  action floorStage(q:Intent):bool=all {f.pending.forall(p=>p.id!=q.id or p==q),
    authority'=authority.with("floor",f.with("pending",f.pending.union(Set(q))).with("active",false))}
  // Final epoch/cut/domain checks and immutable result are one authority step.
  // qualified is supplied by authenticated domain validation, never client data.
  action floorCommit(q:Intent,qualified:bool):bool=all {f.pending.contains(q),f.outcomes.indices().forall(i=>f.outcomes.nth(i).intent.id!=q.id),
    val ok=floorGate(f,q) and qualified
    val post=if(ok)floorPost(f.cut,q) else f.cut
    authority'=authority.with("floor",f.with("cut",post).with("outcomes",f.outcomes.append({intent:q,committed:ok,after:post,epoch:f.epoch})).with("active",false))}
  action floorReplay(q:Intent):bool=all {f.outcomes.indices().exists(i=>f.outcomes.nth(i).intent==q),authority'=authority}
  action floorResolve(q:Intent):bool=all {f.outcomes.indices().exists(i=>f.outcomes.nth(i).intent==q),authority'=authority.with("floor",f.with("pending",f.pending.exclude(Set(q))))}
  action floorRead=authority'=authority.with("floor",f.with("observed",f.cut).with("observedEpoch",f.epoch).with("haveRead",true))
  action floorAbsent=authority'=authority
  action floorLoseReply=authority'=authority.with("floor",f.with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRotate=authority'=authority.with("floor",f.with("epoch",f.epoch+1).with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRestore(c:Cut):bool=authority'=authority.with("floor",f.with("local",c).with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRepair=all {f.haveRead,f.observed==f.cut,f.observedEpoch==f.epoch,
    authority'=authority.with("floor",f.with("local",f.cut).with("active",false))}
  action floorActivate=all {not(f.handoff),f.liveOwners==Set(f.owner),f.haveRead,f.observed==f.cut,f.observedEpoch==f.epoch,f.local==f.cut,f.pending==Set(),
    authority'=authority.with("floor",f.with("active",true))}
  // Durable burn precedes actual admission; a crash/fence between may omit the
  // call forever. Only this sole transport owner retains a pending burn handle.
  // actor is the authenticated execution incarnation, not a supplied RPC field.
  action floorBurnBy(actor:int,k:int,c:Cut,epoch:int):bool=all {actor==f.owner,f.liveOwners==Set(actor),f.egressOwners==Set(actor),not(f.handoff),f.active,c==f.cut,epoch==f.epoch,f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==k),not(f.burned.contains(k)),
    authority'=authority.with("floor",f.with("burned",f.burned.union(Set(k))).with("handles",f.handles.union(Set(k))).with("tickets",f.tickets.union(Set({key:k,cut:c,epoch:epoch}))))}
  action floorBurn(k:int,c:Cut,epoch:int):bool=floorBurnBy(f.owner,k,c,epoch)
  action floorAdmitBy(actor:int,k:int,c:Cut,epoch:int):bool=all {actor==f.owner,f.liveOwners==Set(actor),f.egressOwners==Set(actor),not(f.handoff),f.active,c==f.cut,epoch==f.epoch,f.burned.contains(k),f.handles.contains(k),f.tickets.contains({key:k,cut:c,epoch:epoch}),not(f.admitted.contains(k)),
    authority'=authority.with("floor",f.with("handles",f.handles.exclude(Set(k))).with("admitted",f.admitted.union(Set(k))).with("calls",f.calls+1).with("external",f.external+1))}
  action floorAdmit(k:int,c:Cut,epoch:int):bool=floorAdmitBy(f.owner,k,c,epoch)
  action floorRequestHandoff=authority'=authority.with("floor",f.with("handoff",true).with("active",false).with("handles",Set()))
  // verifiedStop denotes authentic exact-process/egress quiescence evidence.
  // Kubernetes deletion/lease expiry and a caller Boolean cannot supply it.
  action floorConfirmTransportStopped(verifiedStop:bool):bool=all {verifiedStop,f.handoff,
    authority'=authority.with("floor",f.with("liveOwners",Set()).with("egressOwners",Set()).with("handles",Set()).with("active",false))}
  action floorStartOwner=all {f.handoff,f.liveOwners==Set(),f.egressOwners==Set(),
    authority'=authority.with("floor",f.with("owner",f.owner+1).with("epoch",f.epoch+1).with("liveOwners",Set(f.owner+1)).with("egressOwners",Set(f.owner+1)).with("handoff",false).with("handles",Set()).with("haveRead",false).with("active",false))}
  action floorSend(k:int,c:Cut,epoch:int):bool=floorBurn(k,c,epoch).then(floorAdmit(k,c,epoch))
  action unsafeFloorLocalActivation=authority'=authority.with("floor",f.with("active",true))
  action unsafeFloorForgetBurn=authority'=authority.with("floor",f.with("burned",Set()).with("calls",0))
  action unsafeFloorLeaseOnlyPromotion=authority'=authority.with("floor",f.with("owner",f.owner+1).with("epoch",f.epoch+1).with("liveOwners",f.liveOwners.union(Set(f.owner+1))).with("egressOwners",f.egressOwners.union(Set(f.owner+1))).with("active",false))
  action unsafeFloorEscapedSocketWrite=authority'=authority.with("floor",f.with("external",f.external+1))
  action step = {nondet id=ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    nondet kind=Set(0,1,2,3).oneOf()
    nondet scope=Set(7,8).oneOf()
    val q={id:id+10,payload:payload,key:1,kind:kind,scope:scope,epoch:f.epoch,before:f.cut}
    nondet waiting=f.pending.union(Set(q)).oneOf()
    nondet actor=Set(0,f.owner,f.owner-1).oneOf()
    any {stage({id:id,payload:payload,parent:parent,fence:fence}),publish(id,payload,parent,fence),replay(id,payload,parent,fence),observe,restart,floorStage(q),floorCommit(waiting,true),floorCommit(waiting,false),floorReplay(waiting),floorResolve(waiting),
      floorRead,floorLoseReply,floorRotate,floorRestore(emptyCut),floorRepair,floorActivate,floorBurnBy(actor,1,f.cut,f.epoch),floorAdmitBy(actor,1,f.cut,f.epoch),
      floorRequestHandoff,floorConfirmTransportStopped(true),floorConfirmTransportStopped(false),floorStartOwner}}
  action first = init.then(publish(0,0,-1,1))
  run lostReplyRestartReplayTest = first.then(observe).then(restart).then(replay(0,0,-1,1)).expect(safe and authority.head==0)
  run concurrentParentHasOneWinnerTest = first.then(publish(1,1,-1,2)).expect(safe and authority.records.get(1).outcome==2 and authority.head==0)
  run lateReceiptIsHistoricalTest = first.then(publish(2,1,0,2)).then(observe).expect(safe and authority.records.get(0).resultHead==0 and authority.head==1)
  run changedParentCannotReuseIdTest = first.then(replay(0,0,0,1).fail())
  run changedSchemaCannotReuseIdTest = first.then(replay(0,1,-1,1).fail())
  run rejectedDecisionCannotRebaseTest = first.then(publish(1,1,-1,2)).then(publish(2,1,0,2)).then(replay(1,1,-1,2)).expect(safe and authority.records.get(1).resultHead==0)
  run absenceDoesNotAbortLateCommitTest = init.then(observe).then(publish(0,0,-1,1)).expect(safe)
  run headWithoutOutcomeCounterexampleTest = first.then(unsafeHeadOnly).expect(not(safe))
  run deletedOutcomeCounterexampleTest = first.then(unsafeForget(0)).expect(not(safe))
  run reboundOutcomeCounterexampleTest = first.then(unsafeRebind(0)).expect(not(safe))
  action floorConsumed=init.then(floorStage(consume0)).then(floorCommit(consume0,true))
  action floorReady=floorConsumed.then(floorResolve(consume0)).then(floorRead).then(floorRepair).then(floorActivate)
  run floorDurableCommitBeforeLostReplyTest=floorConsumed.then(floorLoseReply).then(floorRestore(emptyCut)).then(floorReplay(consume0)).expect(safe and f.cut.consumption.length()==1 and authority.held==4)
  run floorMissingOutcomeCannotActivateTest=init.then(floorStage(consume0)).then(floorAbsent).expect(safe).then(floorActivate.fail())
  run floorLateCommitAfterAbsentReadTest=init.then(floorStage(consume0)).then(floorAbsent).then(floorCommit(consume0,true)).expect(safe)
  run floorFencedRejectionStopsLateCommitTest=init.then(floorStage(consume0)).then(floorRotate).then(floorCommit(consume0,true)).then(floorReplay(consume0)).expect(safe and f.cut==emptyCut and not(f.outcomes.nth(0).committed))
  run floorOldEpochCannotSendTest=floorReady.then(floorRotate).expect(safe).then(floorBurn(1,floorPost(emptyCut,consume0),0).fail())
  run floorEqualLengthWrongBodyCannotActivateTest=floorReady.then(floorRestore(floorPost(emptyCut,consume0.with("payload",999)))).then(floorRead).expect(safe).then(floorActivate.fail())
  run floorNewIdCannotRepeatClaimTest=floorReady.then(floorStage(consume0.with("id",20).with("before",floorPost(emptyCut,consume0))))
    .then(floorCommit(consume0.with("id",20).with("before",floorPost(emptyCut,consume0)),true)).expect(safe and f.cut.consumption.length()==1)
  pure val finalPublication=publication0.with("before",floorPost(history0.before,history0))
  run floorFourPrefixesRecoverTogetherTest=floorConsumed.then(floorStage(account0)).then(floorCommit(account0,true)).then(floorStage(history0)).then(floorCommit(history0,true))
    .then(floorStage(finalPublication)).then(floorCommit(finalPublication,true)).then(floorRestore(emptyCut))
    .then(floorResolve(consume0)).then(floorResolve(account0)).then(floorResolve(history0)).then(floorResolve(finalPublication)).then(floorRead).then(floorRepair).then(floorActivate)
    .expect(safe and f.cut.publication.length()==1 and f.cut.account.length()==1 and f.cut.history.length()==1 and f.cut.consumption.length()==1)
  run floorStaleParentCannotBeRebasedTest=init.then(floorStage(publication0)).then(floorStage(consume0)).then(floorCommit(publication0,true)).then(floorCommit(consume0,true))
    .expect(safe and f.cut.publication.length()==1 and f.cut.consumption.length()==0)
  run floorSendCannotRepeatAcrossLocalRestoreTest=floorReady.then(floorSend(1,floorPost(emptyCut,consume0),0)).then(floorRestore(emptyCut)).then(floorRead).then(floorRepair).then(floorActivate)
    .expect(safe and f.external==1).then(floorBurn(1,floorPost(emptyCut,consume0),0).fail())
  run floorLocalOnlyActivationCounterexampleTest=floorConsumed.then(floorRestore(emptyCut)).then(unsafeFloorLocalActivation).expect(not(safe))
  run floorAuthorityRollbackCounterexampleTest=floorReady.then(floorSend(1,floorPost(emptyCut,consume0),0)).then(unsafeFloorForgetBurn).expect(not(safe))
  run floorFenceAfterBurnRetainsUnknownTest=floorReady.then(floorBurn(1,floorPost(emptyCut,consume0),0)).then(floorRotate)
    .expect(safe and f.burned.contains(1) and f.external==0 and authority.held==4).then(floorAdmit(1,floorPost(emptyCut,consume0),0).fail())
  run floorRestartAfterBurnCannotReissueHandleTest=floorReady.then(floorBurn(1,floorPost(emptyCut,consume0),0)).then(floorLoseReply)
    .then(floorRead).then(floorRepair).then(floorActivate).expect(safe and f.external==0 and f.burned.contains(1))
    .then(floorAdmit(1,floorPost(emptyCut,consume0),0).fail())
  pure val wrongScope=consume0.with("scope",8)
  run floorWrongOriginalScopeCannotCommitTest=init.then(floorStage(wrongScope)).then(floorCommit(wrongScope,true))
    .expect(safe and f.cut==emptyCut and not(f.outcomes.nth(0).committed))
  run floorWorkerCannotUseCurrentOwnerLabelTest=floorReady.expect(safe).then(floorBurnBy(0,1,floorPost(emptyCut,consume0),0).fail())
  run floorLeaseExpiryCannotActivateReplacementTest=floorReady.then(floorRequestHandoff).expect(safe).then(floorStartOwner.fail())
  run floorUnprovenStopCannotTransferEgressTest=floorReady.then(floorRequestHandoff).expect(safe).then(floorConfirmTransportStopped(false).fail())
  action floorReplaced=floorReady.then(floorRequestHandoff).then(floorConfirmTransportStopped(true)).then(floorStartOwner).then(floorRead).then(floorRepair).then(floorActivate)
  run floorOldIncarnationCannotBurnAtNewEpochTest=floorReplaced.expect(safe and f.owner==2).then(floorBurnBy(1,1,floorPost(emptyCut,consume0),1).fail())
  run floorNewOwnerUsesOriginalClaimOnceTest=floorReplaced.then(floorSend(1,floorPost(emptyCut,consume0),1)).expect(safe and f.external==1 and authority.held==4)
  run floorPendingBurnNotReconstructedOnOwnerChangeTest=floorReady.then(floorBurn(1,floorPost(emptyCut,consume0),0)).then(floorRequestHandoff)
    .then(floorConfirmTransportStopped(true)).then(floorStartOwner).then(floorRead).then(floorRepair).then(floorActivate)
    .expect(safe and f.external==0 and f.burned.contains(1)).then(floorAdmitBy(2,1,floorPost(emptyCut,consume0),1).fail())
  run floorLeaseOnlyPromotionCounterexampleTest=floorReady.then(unsafeFloorLeaseOnlyPromotion).expect(not(safe))
  run floorEscapedOldSocketCounterexampleTest=floorReady.then(floorRotate).then(unsafeFloorEscapedSocketWrite).expect(not(safe))
  run floorLateOriginalCommitAfterOwnerChangeIsRejectedTest=init.then(floorStage(consume0)).then(floorAbsent).then(floorRequestHandoff)
    .then(floorConfirmTransportStopped(true)).then(floorStartOwner).then(floorCommit(consume0,true))
    .expect(safe and f.cut==emptyCut and not(f.outcomes.nth(0).committed) and f.pending.contains(consume0) and authority.held==4)
  run floorCommittedLostReplySurvivesOwnerChangeTest=floorConsumed.then(floorLoseReply).then(floorRequestHandoff)
    .then(floorConfirmTransportStopped(true)).then(floorStartOwner).then(floorReplay(consume0))
    .expect(safe and f.outcomes.nth(0).committed and f.outcomes.nth(0).intent.epoch==0 and f.epoch==1 and not(f.active))
  pure val staged0={id:0,payload:0,parent:-1,fence:1}
  run stagedPolicyCommitLostReplyAndLateStageTest=init.then(stage(staged0)).then(restart)
    .expect(safe and authority.pending==Set(staged0)).then(publish(0,0,-1,1)).then(restart).then(stage(staged0))
    .expect(safe and authority.pending==Set() and authority.records.get(0).outcome==1)
  run stagedPolicyCannotReplaceOriginalCommandTest=init.then(stage(staged0))
    .then(stage({id:0,payload:1,parent:-1,fence:1}).fail())
  run stagedPolicyCannotFinalizeAReplacedCommandTest=init.then(stage(staged0)).then(publish(0,1,-1,1).fail())
  run stagedPolicyConflictResolvesOnlyItsOriginalKeyTest=init.then(stage(staged0))
    .then(stage({id:1,payload:1,parent:-1,fence:1})).then(publish(0,0,-1,1))
    .expect(safe and authority.pending==Set({id:1,payload:1,parent:-1,fence:1})).then(publish(1,1,-1,1))
    .expect(safe and authority.pending==Set() and authority.records.get(1).outcome==2)
  pure val review0={command:staged0,artifact:70,head:-1,fence:1,parentPolicy:0,parentSchema:0,cut:emptyCut,epoch:0}
  pure val sibling={id:1,payload:1,parent:-1,fence:1}
  pure val siblingReview={command:sibling,artifact:71,head:-1,fence:1,parentPolicy:0,parentSchema:0,cut:emptyCut,epoch:0}
  action reviewedFirst=init.then(stage(staged0)).then(registerReview(review0)).then(publishReviewed(staged0,review0))
  action advanceReviewFence=authority'=authority.with("fence",authority.fence+1)
  run registeredReviewCannotBeReplacedTest=init.then(stage(staged0)).then(registerReview(review0))
    .then(registerReviewBy(1,0,review0.with("artifact",999)).fail())
  run substitutedArtifactGetsOriginalRejectionTest=init.then(stage(staged0)).then(registerReview(review0))
    .then(publishReviewed(staged0,review0.with("artifact",999)))
    .expect(reviewSafe and authority.head== -1 and authority.pending==Set() and authority.records.get(0).outcome==2)
  run oldReviewedParentCannotWinAfterSiblingTest=init.then(stage(staged0)).then(stage(sibling))
    .then(registerReview(review0)).then(registerReview(siblingReview)).then(publishReviewed(staged0,review0))
    .then(publishReviewed(sibling,siblingReview)).expect(reviewSafe and authority.head==0 and authority.records.get(1).outcome==2 and authority.held==4)
  run changedFenceInvalidatesMatchingReviewTest=init.then(stage(staged0)).then(registerReview(review0)).then(advanceReviewFence)
    .then(publishReviewed(staged0,review0)).expect(reviewSafe and authority.head== -1 and authority.records.get(0).outcome==2)
  run pendingReviewSurvivesMissingReplyTest=init.then(stage(staged0)).then(registerReview(review0)).then(restart).then(observe)
    .expect(reviewSafe and authority.pending.contains(staged0) and authority.records.get(0).outcome==0 and authority.held==4)
  run reviewCommitLostReplyRecoveryIsObservationTest=reviewedFirst.then(restart).then(replay(0,0,-1,1))
    .expect(reviewSafe and authority.commits.length()==1 and authority.calls==1 and authority.held==4)
  run reviewedDecisionCannotBeReopenedTest=reviewedFirst.then(restart).then(stage(staged0))
    .expect(reviewSafe and authority.pending==Set()).then(publishReviewed(staged0,review0).fail())
  run reviewCannotBeTransferredToNewIdTest=init.then(stage(sibling)).then(publishReviewed(sibling,review0))
    .expect(reviewSafe and authority.head== -1 and authority.records.get(1).outcome==2)
  run reviewResolvingOneIntentRetainsSiblingTest=init.then(stage(staged0)).then(stage(sibling)).then(registerReview(review0))
    .then(publishReviewed(staged0,review0)).then(restart).expect(reviewSafe and authority.pending==Set(sibling) and authority.held==4)
  pure val successor={id:2,payload:2,parent:0,fence:2}
  pure val successorReview={command:successor,artifact:72,head:0,fence:1,parentPolicy:0,parentSchema:0,cut:emptyCut,epoch:0}
  action reviewedStep=any {stage(staged0),stage(sibling),stage(successor),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,review0),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,siblingReview),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,successorReview),
    recoverReviewsBy(authority.floor.registrarOwner,authority.floor.registrarTerm),restoreReviewImage(List()),rotateRegistrar,
    publishReviewed(staged0,review0),publishReviewed(sibling,siblingReview),publishReviewed(successor,successorReview),
    publishReviewed(staged0,review0.with("artifact",999)),advanceReviewFence,
    floorStage(consume0),floorCommit(consume0,true),floorResolve(consume0),floorRotate,
    replay(0,0,-1,1),replay(1,1,-1,1),replay(2,2,0,2),restart,observe}
  run historicalReviewCannotReplaceCurrentPublicationTest=reviewedFirst.then(stage(successor)).then(registerReview(successorReview))
    .then(publishReviewed(successor,successorReview)).then(restart).then(replay(0,0,-1,1))
    .expect(reviewSafe and authority.head==1 and authority.policy==2)
  run omittedReviewGateCounterexampleTest=first.expect(safe and not(reviewSafe))
  run forcedEvidenceSubstitutionCounterexampleTest=init.then(stage(staged0)).then(registerReview(review0))
    .then(decidePublication(0,0,-1,1,Set(review0.with("artifact",999)),true)).expect(safe and not(reviewSafe))
  action unsafeForgetReview=authority'=authority.with("reviews",authority.reviews.set(0,Set()))
  run crossStoreReviewRollbackCounterexampleTest=reviewedFirst.then(unsafeForgetReview).expect(reviewSafe and not(registryRecovered))
  action unsafeGlobalPendingPublication(q:Proposal,r:Review):bool=all {authority.pending==Set(),publishReviewed(q,r)}
  run globalPendingGateDeadlocksOwnIntentCounterexampleTest=init.then(stage(staged0)).then(registerReview(review0))
    .expect(reviewSafe and authority.pending.contains(staged0)).then(unsafeGlobalPendingPublication(staged0,review0).fail())
  run ownPendingIntentCanFinalizeWithoutGlobalEmptinessTest=reviewedFirst.expect(reviewSafe and authority.pending==Set())
  run unknownFactIntentCannotAuthorizePublicationTest=init.then(stage(staged0)).then(registerReview(review0)).then(floorStage(consume0))
    .then(publishReviewed(staged0,review0)).expect(reviewSafe and authority.head== -1 and authority.floor.pending.contains(consume0) and authority.held==4)
  run changedConsumptionPrefixInvalidatesReviewTest=init.then(stage(staged0)).then(registerReview(review0)).then(floorStage(consume0))
    .then(floorCommit(consume0,true)).then(floorResolve(consume0)).then(publishReviewed(staged0,review0))
    .expect(reviewSafe and authority.head== -1 and authority.floor.cut.consumption.length()==1 and authority.held==4)
  run changedRecoveryEpochInvalidatesReviewTest=init.then(stage(staged0)).then(registerReview(review0)).then(floorRotate)
    .then(publishReviewed(staged0,review0)).expect(reviewSafe and authority.head== -1)
  run cachedReviewIgnoresChangedPrefixCounterexampleTest=init.then(stage(staged0)).then(registerReview(review0)).then(floorStage(consume0))
    .then(floorCommit(consume0,true)).then(floorResolve(consume0)).then(decidePublication(0,0,-1,1,Set(review0),true))
    .expect(safe and not(reviewSafe) and authority.floor.cut.consumption.length()==1 and authority.held==4)
  action registeredWithoutProjection=init.then(stage(staged0)).then(registerReviewBy(1,0,review0))
  run registrationLostReplyCannotPublishUnrecoveredProjectionTest=registeredWithoutProjection.then(restart).then(observeRegistration(review0))
    .expect(reviewSafe and not(registryRecovered) and authority.pending.contains(staged0)).then(publishReviewed(staged0,review0).fail())
  run exactRegistrationRetryDoesNotAppendTwiceTest=registeredWithoutProjection.then(registerReviewBy(1,0,review0)).then(recoverReviewsBy(1,0))
    .then(publishReviewed(staged0,review0)).expect(reviewSafe and authority.floor.registry.length()==1 and authority.commits.length()==1 and authority.held==4)
  run restoredProjectionCannotDiscardAnchoredArtifactTest=reviewedFirst.then(restoreReviewImage(List())).then(restart)
    .expect(reviewSafe and not(registryRecovered)).then(recoverReviewsBy(1,0)).then(observeRegistration(review0))
    .expect(reviewSafe and registryRecovered and authority.commits.length()==1 and authority.held==4)
  run oldRegistrarCannotAppendAfterHandoffTest=init.then(stage(staged0)).then(rotateRegistrar).expect(reviewSafe)
    .then(registerReviewBy(1,0,review0).fail())
  run oldRegistrarCannotPublishAlreadyRegisteredArtifactTest=registeredWithoutProjection.then(recoverReviewsBy(1,0)).then(rotateRegistrar)
    .expect(reviewSafe and authority.pending.contains(staged0)).then(publishReviewedBy(1,0,staged0,review0).fail())
  run oldRegistrarCannotInstallRecoveryImageTest=registeredWithoutProjection.then(rotateRegistrar).then(restoreReviewImage(List()))
    .expect(reviewSafe).then(recoverReviewsBy(1,0).fail())
  run newRegistrarCanContinueExactOriginalRegistrationTest=registeredWithoutProjection.then(rotateRegistrar).then(observeRegistration(review0))
    .then(recoverReviewsBy(2,1)).then(publishReviewedBy(2,1,staged0,review0))
    .expect(reviewSafe and authority.floor.registry.length()==1 and authority.held==4 and authority.calls==1)
  run delayedRegistrationReadCannotReactivateOldRegistrarTest=registeredWithoutProjection.then(rotateRegistrar).then(observeRegistration(review0))
    .then(registerReviewBy(1,0,review0)).expect(reviewSafe and authority.floor.registry.length()==1)
    .then(publishReviewedBy(1,0,staged0,review0).fail())
  run concurrentRegistrationAppendInvalidatesEarlierProjectionTest=init.then(stage(staged0)).then(stage(sibling)).then(registerReview(review0))
    .then(registerReviewBy(1,0,siblingReview)).expect(reviewSafe and not(registryRecovered)).then(publishReviewed(staged0,review0).fail())
  run concurrentRegistryRecoveryRetainsSiblingPendingTest=init.then(stage(staged0)).then(stage(sibling)).then(registerReviewBy(1,0,review0))
    .then(registerReviewBy(1,0,siblingReview)).then(recoverReviewsBy(1,0)).then(publishReviewed(staged0,review0))
    .expect(reviewSafe and authority.pending==Set(sibling) and authority.floor.registry.length()==2 and authority.held==4)
  action unsafeRollbackRegistryAnchor=authority'=authority.with("floor",authority.floor.with("registry",List()))
  run independentRegistrationAnchorRollbackCounterexampleTest=reviewedFirst.then(unsafeRollbackRegistryAnchor).expect(safe and not(reviewSafe))
  // Native local adapter witnesses share this ledger; they do not qualify the
  // stronger independent registry/source-cut/registrar protocol above.
  run latchedReviewCannotUseLegacyPublicationTest=init.then(stageRequiringReview(staged0))
    .then(stage(staged0)).expect(safe and authority.pending==Set(staged0) and authority.records.get(0).outcome==0 and authority.held==4)
    .then(publish(0,0,-1,1).fail())
  run latchedReviewRegistrationAndFinalCASLostRepliesTest=init.then(stageRequiringReview(staged0))
    .then(registerReview(review0)).then(restart).then(observeRegistration(review0)).then(registerReview(review0))
    .then(publish(0,0,-1,1)).then(restart).then(replay(0,0,-1,1)).then(stageRequiringReview(staged0))
    .expect(reviewSafe and authority.head==0 and authority.pending==Set())
  run staleLatchedProposalCanRejectWithoutReviewAndKeepsSiblingTest=init.then(stageRequiringReview(staged0))
    .then(stage(sibling)).then(publish(2,2,-1,1)).then(publish(0,0,-1,1))
    .expect(safe and authority.records.get(0).outcome==2 and authority.pending==Set(sibling) and authority.held==4)
  run unreviewedHistoryCannotBeRelabeledReviewedTest=first.expect(safe and authority.requiredReviews==Set())
    .then(stageRequiringReview(staged0).fail())
  action unsafeMutateParentSchema=authority'=authority.with("schema",authority.schema+1)
  run sameOrdinalDifferentParentBytesBlockLatchedCASTest=init.then(stageRequiringReview(staged0))
    .then(registerReview(review0)).then(unsafeMutateParentSchema)
    .expect(authority.head== -1 and authority.pending==Set(staged0) and authority.held==4).then(publish(0,0,-1,1).fail())
  run omittedNativeLatchCounterexampleTest=init.then(stageRequiringReview(staged0))
    .then(decidePublication(0,0,-1,1,Set(),true)).expect(safe and not(reviewSafe) and authority.requiredReviews==Set(0))
  run localReviewDoesNotEstablishIndependentSourceCurrentnessCounterexampleTest=init.then(stageRequiringReview(staged0))
    .then(registerReview(review0)).then(floorRotate).then(publish(0,0,-1,1))
    .expect(safe and not(reviewSafe))
  val localReviewSafe=safe and authority.commits.indices().forall(i=>{
    val e=authority.commits.nth(i)
    not(authority.requiredReviews.contains(e.id)) or e.decision.review.exists(r=>
      r.command=={id:e.id,payload:e.decision.payload,parent:e.decision.parent,fence:e.decision.requestedFence} and
        r.head==e.decision.parent and r.fence==e.decision.validatedFence and
        r.parentPolicy==(if(e.decision.parent<0)0 else authority.commits.nth(e.decision.parent).decision.payload) and
        r.parentSchema==r.parentPolicy)})
  action localReviewedStep=any {
    stageRequiringReview(staged0),stageRequiringReview(sibling),stageRequiringReview(successor),
    stage(staged0),stage(sibling),stage(successor),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,review0),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,siblingReview),
    registerReviewBy(authority.floor.registrarOwner,authority.floor.registrarTerm,successorReview),
    publish(0,0,-1,1),publish(1,1,-1,1),publish(2,2,0,2),
    replay(0,0,-1,1),replay(1,1,-1,1),replay(2,2,0,2),
    restoreReviewImage(List()),recoverReviewsBy(authority.floor.registrarOwner,authority.floor.registrarTerm),
    advanceReviewFence,floorRotate,restart,observe}
  pure val sourceRegister0={credential:100,epoch:0,owner:1,command:0,purpose:0,artifact:70}
  pure val sourcePublish0=sourceRegister0.with("purpose",1)
  run revocationBetweenValidationAndRegistrationTest=init.then(stage(staged0)).then(captureSourceUse(sourceRegister0))
    .then(revokeSource(100)).expect(reviewSafe and authority.pending.contains(staged0)).then(registerUsingSource(sourceRegister0,review0).fail())
  run revocationBetweenValidationAndFinalCASTest=registeredWithoutProjection.then(recoverReviewsBy(1,0)).then(captureSourceUse(sourcePublish0))
    .then(revokeSource(100)).then(publishUsingSource(sourcePublish0,staged0,review0).fail())
  run reconnectDoesNotRefreshOldSourceValidationTest=init.then(stage(staged0)).then(captureSourceUse(sourceRegister0)).then(rotateRegistrar).then(restart)
    .then(registerUsingSource(sourceRegister0,review0).fail())
  run delayedIssuanceDecisionCannotReactivateOldEpochTest=init.then(rotateRegistrar).then(recordSourceDecision(1,101))
    .then(rotateRegistrar).then(recordSourceDecision(1,101)).expect(reviewSafe).then(captureSourceUse(sourcePublish0.with("credential",101).with("owner",2).with("epoch",1)).fail())
  run lostSourceIssuanceReplyIsIdempotentTest=init.then(rotateRegistrar).then(recordSourceDecision(1,101)).then(restart)
    .then(recordSourceDecision(1,101)).expect(reviewSafe and authority.floor.sourceDecisions.length()==2).then(recordSourceDecision(1,999).fail())
  run exactIssuanceReadDoesNotClearRevocationTest=init.then(revokeSource(100)).then(recordSourceDecision(0,100)).then(restart)
    .expect(reviewSafe and authority.floor.sourceRevoked.contains(100)).then(captureSourceUse(sourceRegister0).fail())
  pure val sourcePublish1={credential:101,epoch:1,owner:2,command:0,purpose:1,artifact:70}
  run newSourceCanContinueExactOriginalArtifactTest=registeredWithoutProjection.then(rotateRegistrar).then(recordSourceDecision(1,101))
    .then(captureSourceUse(sourcePublish1)).then(recoverReviewsBy(2,1)).then(publishUsingSource(sourcePublish1,staged0,review0))
    .expect(reviewSafe and authority.held==4 and authority.calls==1 and authority.floor.registry.length()==1)
  run capturedRegistrationReceiptCannotBeUsedForPublicationTest=registeredWithoutProjection.then(recoverReviewsBy(1,0)).then(captureSourceUse(sourceRegister0))
    .then(publishUsingSource(sourceRegister0,staged0,review0).fail())
  run actorEpochOnlyPathIgnoresRevocationCounterexampleTest=registeredWithoutProjection.then(recoverReviewsBy(1,0)).then(revokeSource(100))
    .then(publishReviewedBy(1,0,staged0,review0)).expect(reviewSafe and authority.floor.sourceRevoked.contains(100) and authority.commits.length()==1)
  val sourceDecisionSafe=reviewSafe and authority.floor.sourceDecisions.indices().forall(i=>
    authority.floor.sourceDecisions.indices().forall(j=>i==j or
      (authority.floor.sourceDecisions.nth(i).slot!=authority.floor.sourceDecisions.nth(j).slot and
       authority.floor.sourceDecisions.nth(i).credential!=authority.floor.sourceDecisions.nth(j).credential)))
  def currentRegisterReference={credential:100+authority.floor.registrarTerm,epoch:authority.floor.registrarTerm,
    owner:authority.floor.registrarOwner,command:0,purpose:0,artifact:70}
  action sourceScheduleStep=any {stage(staged0),stage(sibling),recordSourceDecision(authority.floor.registrarTerm,100+authority.floor.registrarTerm),
    captureSourceUse(currentRegisterReference),captureSourceUse(currentRegisterReference.with("purpose",1)),
    registerUsingSource(currentRegisterReference,review0),publishUsingSource(currentRegisterReference.with("purpose",1),staged0,review0),
    registerUsingSource(sourceRegister0,review0),publishUsingSource(sourcePublish0,staged0,review0),
    revokeSource(100),revokeSource(101),rotateRegistrar,restoreReviewImage(List()),
    recoverReviewsBy(authority.floor.registrarOwner,authority.floor.registrarTerm),restart,observe}
  run failedNativeReplayRetainsOriginalPendingTest=init.then(stageRequiringReview(staged0))
    .expect(safe and authority.pending==Set(staged0) and authority.held==4).then(registerReplayChecked(review0,false).fail())
  run nativeReplayRegistrationLostObservationRecoveryTest=init.then(stageRequiringReview(staged0))
    .then(registerReplayChecked(review0,true)).then(restart).then(observeRegistration(review0))
    .then(recoverReviewsBy(1,0)).then(publish(0,0,-1,1)).expect(reviewSafe and authority.held==4)
  run successfulReplayCannotRegisterAtChangedParentTest=init.then(stageRequiringReview(staged0))
    .then(publish(1,1,-1,1)).expect(safe and authority.pending==Set(staged0)).then(registerReplayChecked(review0,true).fail())
  run failedReplayIsNotTerminalRejectionTest=init.then(stageRequiringReview(staged0))
    .then(restart).expect(safe and authority.records.get(0).outcome==0 and authority.pending==Set(staged0))
    .then(publish(0,0,-1,1).fail())
  pure val observation0={use:sourceRegister0,cut:sourceCut0,session:0}
  run configurationImageCannotLowerAuthorityEpochTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(rotateRegistrar)
    .then(restoreSourceObservation(observation0)).then(restart).expect(sourceDecisionSafe and authority.floor.registrarTerm==1)
    .then(registerAtSourceObservation(observation0,review0).fail())
  run configurationImageCannotErasePersistentRevocationTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(revokeSource(100))
    .then(restoreSourceObservation(observation0)).expect(sourceDecisionSafe and authority.floor.sourceRevoked.contains(100))
    .then(registerAtSourceObservation(observation0,review0).fail())
  run unknownAuthorityReadRetainsPendingTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(sourceAvailability(false))
    .expect(sourceDecisionSafe and authority.pending.contains(staged0) and authority.held==4).then(registerAtSourceObservation(observation0,review0).fail())
  run lostRegistrationReplyRequiresFreshPublicationObservationTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0))
    .then(registerAtSourceObservation(observation0,review0)).then(restart).then(recoverReviewsBy(1,0))
    .expect(sourceDecisionSafe and authority.pending.contains(staged0)).then(publishAtSourceObservation(observation0.with("use",sourcePublish0),staged0,review0).fail())
  run lateReadAfterHandoffDoesNotRefreshEpochTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(rotateRegistrar)
    .then(restoreSourceObservation(observation0)).then(recordSourceDecision(0,100)).expect(sourceDecisionSafe)
    .then(registerAtSourceObservation(observation0,review0).fail())
  action registeredObserved=init.then(stage(staged0)).then(registerReview(review0)).then(readSourceObservation(sourcePublish0))
  pure val registeredCut0=sourceCut0.with("registry",List({review:review0,owner:1,term:0,index:0}))
  pure val publishObservation0={use:sourcePublish0,cut:registeredCut0,session:0}
  run revocationCommitLostReplyCannotUseCachedPublicationReadTest=registeredObserved.then(revokeSource(100)).then(restart)
    .then(restoreSourceObservation(publishObservation0)).expect(sourceDecisionSafe and authority.pending.contains(staged0))
    .then(publishAtSourceObservation(publishObservation0,staged0,review0).fail())
  run registryAppendBetweenReadAndCASRequiresRejoinTest=registeredObserved.then(stage(sibling)).then(registerReviewBy(1,0,siblingReview))
    .then(recoverReviewsBy(1,0)).expect(sourceDecisionSafe).then(publishAtSourceObservation(publishObservation0,staged0,review0).fail())
  run freshObservationStillPermitsOriginalCASTest=registeredObserved.then(publishAtSourceObservation(publishObservation0,staged0,review0))
    .expect(sourceDecisionSafe and authority.commits.length()==1 and authority.held==4 and authority.calls==1)
  run successfulCASReplyLossCannotRepublishFromPriorReadTest=registeredObserved.then(publishAtSourceObservation(publishObservation0,staged0,review0))
    .then(restart).then(restoreSourceObservation(publishObservation0)).then(replay(0,0,-1,1))
    .expect(sourceDecisionSafe and authority.commits.length()==1).then(publishAtSourceObservation(publishObservation0,staged0,review0).fail())
  run cachedRevocationViewOnlyCounterexampleTest=registeredObserved.then(revokeSource(100)).then(restoreSourceObservation(publishObservation0))
    .then(publishReviewedBy(1,0,staged0,review0)).expect(sourceDecisionSafe and not(joinedSourceObservation(publishObservation0)) and authority.commits.length()==1)
  run sameEpochReconnectNeedsFreshObservationTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(reconnectSourceObserver)
    .then(restoreSourceObservation(observation0)).expect(sourceDecisionSafe and authority.floor.registrarTerm==0)
    .then(registerAtSourceObservation(observation0,review0).fail())
  run freshReadAfterSameEpochReconnectCanProgressTest=init.then(stage(staged0)).then(readSourceObservation(sourceRegister0)).then(reconnectSourceObserver)
    .then(readSourceObservation(sourceRegister0)).then(registerAtSourceObservation(observation0.with("session",1),review0))
    .expect(sourceDecisionSafe and authority.floor.registry.length()==1 and authority.held==4)
  run observerRestartCannotRestoreReadCapabilityTest=registeredObserved.then(restartSourceObserver)
    .then(restoreSourceObservation(publishObservation0)).expect(sourceDecisionSafe and authority.floor.registrarTerm==0)
    .then(publishAtSourceObservation(publishObservation0,staged0,review0).fail())
  run freshReadAfterObserverRestartPreservesExactRegistryTest=registeredObserved.then(restartSourceObserver)
    .then(restoreReviewImage(List())).then(recoverReviewsBy(1,0)).then(readSourceObservation(sourcePublish0))
    .then(publishAtSourceObservation(publishObservation0.with("session",1),staged0,review0))
    .expect(sourceDecisionSafe and authority.commits.length()==1 and anchoredReviews(0)==Set(review0) and authority.held==4)
  run exactCutCannotHideMissingRegistryProjectionTest=registeredObserved.then(restoreReviewImage(List()))
    .expect(joinedSourceObservation(publishObservation0) and not(registryRecovered))
    .then(publishAtSourceObservation(publishObservation0,staged0,review0).fail())
  run exactRegistryRecoveryAllowsOriginalCASProgressTest=registeredObserved.then(restoreReviewImage(List())).then(recoverReviewsBy(1,0))
    .then(readSourceObservation(sourcePublish0)).then(publishAtSourceObservation(publishObservation0,staged0,review0))
    .expect(sourceDecisionSafe and authority.held==4)
  pure val nextSourcePublish=sourcePublish0.with("credential",101).with("owner",2).with("epoch",1)
  run lateRegistryReceiptAfterHandoffIsHistoricalTest=registeredObserved.then(rotateRegistrar).then(recordSourceDecision(1,101))
    .then(restartSourceObserver).then(observeRegistration(review0)).then(restoreSourceObservation(publishObservation0))
    .expect(not(joinedSourceObservation(publishObservation0))).then(recoverReviewsBy(2,1))
    .then(readSourceObservation(nextSourcePublish))
    .then(publishAtSourceObservation({use:nextSourcePublish,cut:sourceAuthorityCut,session:1},staged0,review0))
    .expect(sourceDecisionSafe and anchoredReviews(0)==Set(review0) and authority.commits.length()==1)
  run committedPublicationBeforeRevocationRemainsHistoricalTest=registeredObserved.then(publishAtSourceObservation(publishObservation0,staged0,review0))
    .then(revokeSource(100)).then(restartSourceObserver).then(replay(0,0,-1,1))
    .expect(sourceDecisionSafe and authority.commits.length()==1 and authority.held==4)
    .then(readSourceObservation(sourcePublish0).fail())
  // Deliberately outside the independent-prefix retention premise. A consistent
  // rollback can pass local integrity checks and resurrect a revoked credential.
  action unsafeRestoreIndependentSourceSnapshot=authority'=authority.with("floor",authority.floor
    .with("registrarOwner",1).with("registrarTerm",0).with("sourceRevoked",Set())
    .with("sourceDecisions",floor0.sourceDecisions).with("registry",List()))
  run independentSnapshotRollbackResurrectsCredentialCounterexampleTest=init.then(stage(staged0))
    .then(readSourceObservation(sourceRegister0)).then(revokeSource(100)).then(rotateRegistrar)
    .then(unsafeRestoreIndependentSourceSnapshot).then(restoreSourceObservation(observation0))
    .then(registerAtSourceObservation(observation0,review0))
    .expect(sourceUseCurrent(sourceRegister0) and anchoredReviews(0)==Set(review0) and authority.held==4)
  action sourceRecoverySchedule=any {stage(staged0),stage(sibling),
    recordSourceDecision(authority.floor.registrarTerm,100+authority.floor.registrarTerm),revokeSource(100),revokeSource(101),rotateRegistrar,
    recoverReviewsBy(authority.floor.registrarOwner,authority.floor.registrarTerm),restoreReviewImage(List()),restart,reconnectSourceObserver,restartSourceObserver,observe,
    readSourceObservation(currentRegisterReference),readSourceObservation(currentRegisterReference.with("purpose",1)),
    restoreSourceObservation(observation0),restoreSourceObservation(publishObservation0),sourceAvailability(false),sourceAvailability(true),
    registerAtSourceObservation(observation0,review0),publishAtSourceObservation(publishObservation0,staged0,review0),
    registerAtSourceObservation({use:currentRegisterReference,cut:sourceAuthorityCut,session:authority.sourceSession},review0),
    publishAtSourceObservation({use:currentRegisterReference.with("purpose",1),cut:sourceAuthorityCut,session:authority.sourceSession},staged0,review0)}
}

module LlmAccountCommit {
  import LlmExecutionReconciliation as R
  type Key={root:int,claim:int,profile:int,budget:int,history:int,reservation:int}
  type Transaction={id:int,key:Key,bound:int,usage:int,resolution:int,source:int,meter:int}
  type Balance={available:int,held:int,charged:int}
  type Image={revision:int,balance:Balance,applications:Set[Transaction],used:Set[int],holds:int->int}
  type Proposal={transaction:Transaction,before:Image,worker:int,sourceGeneration:int}
  type Record={proposal:Proposal,after:Image,epoch:int}
  type Account={anchor:Image,local:Image,journal:List[Record],epoch:int,qualified:bool,prepared:Set[Proposal],observed:Set[int],
    everReleased:int,everCharged:int,otherEvidence:bool,sourceGeneration:int}
  var a:Account
  pure val key={root:10,claim:11,profile:30,budget:5,history:9,reservation:11}
  pure val otherKey=key.with("root",20).with("claim",12).with("reservation",12)
  pure val tx0={id:100,key:key,bound:3,usage:2,resolution:1,source:1,meter:1}
  pure val tx1={id:101,key:otherKey,bound:2,usage:1,resolution:2,source:2,meter:2}
  pure val txFull=tx0.with("usage",3)
  pure val genesis={revision:0,balance:{available:5,held:5,charged:0},applications:Set(),used:Set(),holds:Set(11,12).mapBy(k=>if (k==11) 3 else 2)}
  pure def post(image,tx)=image.with("revision",image.revision+1)
    .with("balance",{available:image.balance.available+tx.bound-tx.usage,held:image.balance.held-tx.bound,charged:image.balance.charged+tx.usage})
    .with("applications",image.applications.union(Set(tx))).with("used",image.used.union(Set(tx.key.reservation))).with("holds",image.holds.set(tx.key.reservation,0))
  pure val p0={transaction:tx0,before:genesis,worker:0,sourceGeneration:0}
  pure val p1={transaction:tx1,before:genesis,worker:0,sourceGeneration:0}
  pure val after0=post(genesis,tx0)
  pure val initial={anchor:genesis,local:genesis,journal:List(),epoch:0,qualified:true,prepared:Set(),observed:Set(),everReleased:0,everCharged:0,otherEvidence:true,sourceGeneration:0}
  def originalEvidence(tx)=if (tx.key==key) R::e.decisions==List(R::executed) and R::e.source.length()==1 and R::e.usage==tx.usage and tx.bound==3 and tx.resolution==1 and tx.source==1 and tx.meter==1
    else tx==tx1 and a.otherEvidence
  def gate(p)=not(R::e.conflict) and R::e.qualified and p.sourceGeneration==a.sourceGeneration and a.qualified and a.local==a.anchor and p.worker==a.epoch and p.before==a.anchor and
    originalEvidence(p.transaction) and p.transaction.usage>=0 and p.transaction.usage<=p.transaction.bound and
    a.anchor.balance.held>=p.transaction.bound and a.anchor.holds.get(p.transaction.key.reservation)==p.transaction.bound and a.anchor.applications.forall(t=>t.id!=p.transaction.id) and
    not(a.anchor.used.contains(p.transaction.key.reservation))
  action init=all {R::usageApplied,a'=initial}
  action hold=R::inert
  action prepare(p)=all {gate(p),hold,a'=a.with("prepared",a.prepared.union(Set(p)))}
  action commit(p,policy,durable)=all {a.prepared.contains(p),gate(p),policy,durable,hold,
    val image=post(a.anchor,p.transaction)
    a'=a.with("anchor",image).with("journal",a.journal.append({proposal:p,after:image,epoch:a.epoch})).with("qualified",false)
      .with("everReleased",a.everReleased+p.transaction.bound-p.transaction.usage).with("everCharged",a.everCharged+p.transaction.usage)}
  action rotate=all {hold,a'=a.with("epoch",a.epoch+1).with("qualified",false)}
  action restore(image)=all {not(a.qualified),hold,a'=a.with("local",image)}
  action recover(authentic)=all {not(a.qualified),authentic,a.local==a.anchor,hold,a'=a.with("qualified",true)}
  action query(tx,authentic)=all {authentic,a.anchor.applications.contains(tx),hold,a'=a.with("observed",a.observed.union(Set(tx.id)))}
  action loseReply=all {hold,a'=a.with("observed",Set())}
  action lateFull=all {R::lateFull,a'=a}
  action conflictUsage=all {R::conflict,a'=a.with("sourceGeneration",a.sourceGeneration+1)}
  action prepared=init.then(prepare(p0))
  action committed=prepared.then(commit(p0,true,true))
  action projected=committed.then(restore(after0)).then(recover(true))
  action restarted=committed.then(rotate)
  action twoPrepared=prepared.then(prepare(p1))
  action fullyCharged=all {R::sourceApplied.then(R::finalUsageReceipt(true)).then(R::usageCAS(R::executed,3,0,true)),a'=initial}
  val conservation=a.anchor.balance.available+a.anchor.balance.held+a.anchor.balance.charged==10 and
    a.anchor.balance.available==5+a.everReleased and a.anchor.balance.charged==a.everCharged and a.anchor.balance.held>=0
  val joined=a.qualified implies a.local==a.anchor
  val unique=a.anchor.applications.forall(x=>a.anchor.applications.forall(y=>x==y or (x.id!=y.id and x.key.reservation!=y.key.reservation))) and
    a.journal.indices().forall(i=>a.journal.indices().forall(j=>i==j or a.journal.nth(i).proposal.transaction.key.reservation!=a.journal.nth(j).proposal.transaction.key.reservation))
  val originalHolds=Set(11,12).forall(k=>a.anchor.holds.get(k)==(if (a.anchor.used.contains(k)) 0 else if (k==11) 3 else 2))
  val paired=a.anchor.applications.forall(t=>a.anchor.used.contains(t.key.reservation)) and
    a.anchor.used.forall(k=>a.anchor.applications.exists(t=>t.key.reservation==k))
  val chain=a.anchor.revision==a.journal.length() and a.journal.indices().forall(i=>{val r=a.journal.nth(i)
    r.proposal.worker==r.epoch and r.proposal.before==(if (i==0) genesis else a.journal.nth(i-1).after) and r.after==post(r.proposal.before,r.proposal.transaction)}) and
    a.anchor==(if (a.journal.length()==0) genesis else a.journal.nth(a.journal.length()-1).after)
  val evidence=a.journal.indices().forall(i=>originalEvidence(a.journal.nth(i).proposal.transaction))
  val safety=originalHolds and evidence and R::safety and conservation and joined and unique and paired and chain
  action step={nondet tx=Set(tx0,tx1,txFull).oneOf()
    nondet p=a.prepared.union(Set(p0,p1,{transaction:tx,before:a.anchor,worker:a.epoch,sourceGeneration:a.sourceGeneration})).oneOf()
    nondet image=a.journal.indices().map(i=>a.journal.nth(i).after).union(Set(genesis,a.anchor)).oneOf()
    any {prepare(p),commit(p,true,true),rotate,restore(image),recover(true),query(tx,true),loseReply,lateFull,conflictUsage}}
                                                                                                                                                                              
                                                                                                          
                                                                                                          
                                                                                                                                                             
                                                                                                    
                                                                                                                                                            
                                                                                                                                                         
                                                                                                                                                            
                                                                                   
                                                                                   
                                                                                                                                                                
                                                                                                                                         
                                                                                                                                                            
                                                                                          
                                                                                      
                                                                                                                                                 
                                                                                                      
                                                                                                                                                                                  
                                                                                                  
                                                                                                                                 
                                                                                                                                 
                                                                                                                  
                                                                                               
                                                                                                                                                                          
                                                                                                                                                                                
                                                                                                                            
                                                                                                                                           
                                                                                                                                                                                     
                                                                                        
                                                                                                            
                                                                                                                                
                                                                                                                                    
                                                                                                                    
                                                                                                                  
                                                                                                                                 
                                                                                                                               
                                                                                                    
                                                                                                               
  action unsafeIdOnly=all {hold,a'=a.with("anchor",a.anchor.with("applications",Set(tx0)).with("used",Set(11)))}
  action unsafeDeltaOnly=all {hold,a'=a.with("anchor",after0.with("applications",Set()).with("used",Set()))
    .with("everReleased",1).with("everCharged",2)}
  action unsafeApply(p)=all {hold,a'=a.with("anchor",post(a.anchor,p.transaction)).with("journal",a.journal.append({proposal:p,after:post(a.anchor,p.transaction),epoch:a.epoch}))
    .with("qualified",false).with("everReleased",a.everReleased+p.transaction.bound-p.transaction.usage).with("everCharged",a.everCharged+p.transaction.usage)}
  action unsafeRecover=all {hold,a'=a.with("qualified",true)}
  action unsafeRollback=all {hold,a'=a.with("anchor",genesis).with("local",genesis).with("journal",List()).with("qualified",true)}
  action unsafeResetUsed=all {hold,a'=a.with("anchor",a.anchor.with("used",Set()))}
                                                                                        
                                                                                           
                                                                                                                      
                                                                                                                                                                               
                                                                                                                                 
                                                                                                                                                                                              
                                                                                                                                                     
                                                                                                      
                                                                                                                    
                                                                                                
}

module LlmAdmissionFloor {
  import LlmAppendHandoff as H
  type Image={root:H::Manifest,closed:List[H::Segment],live:List[H::Segment],allocated:Set[H::Segment],rootGeneration:int,appendGeneration:int,frontier:int,sequence:int,
    cut:H::Cut,haveCut:bool,candidate:H::Manifest,haveCandidate:bool,worker:int,sourceGeneration:int}
  type Proposal={id:int,intent:int,parent:int,before:Image,after:Image,worker:int}
  type Record={proposal:Proposal}
  type Receipt={revision:int,record:Record}
  type Floor={log:List[Record],pending:Set[Proposal],local:Image,haveLocal:bool,objects:Set[H::Segment],bodies:Set[H::Manifest],observed:Receipt,haveReceipt:bool,active:bool,
    resolved:Record,haveResolved:bool,attemptedWorker:int}
  var f:Floor
  pure def capture(h,worker)={root:h.root,closed:h.closed,live:h.live,allocated:h.allocated,rootGeneration:h.rootGeneration,appendGeneration:h.appendGeneration,frontier:h.frontier,sequence:h.sequence,
    cut:h.cut,haveCut:h.haveCut,candidate:h.candidate,haveCandidate:h.haveCandidate,worker:worker,sourceGeneration:0}
  pure val i0=capture(H::initial,0)
  pure val seed={proposal:{id:0,intent:0,parent:0,before:i0,after:i0,worker:0}}
  pure val initial={log:List(seed),pending:Set(),local:i0,haveLocal:false,objects:Set(),bodies:Set(),observed:{revision:1,record:seed},haveReceipt:false,active:false,
    resolved:seed,haveResolved:false,attemptedWorker:0}
  def image=capture(H::h,H::view.worker)
  def current={revision:f.log.length(),record:f.log.nth(f.log.length()-1)}
  def confirmed=f.haveReceipt and f.observed==current
  def complete=H::refs.indices().forall(i=>f.objects.contains(H::refs.nth(i))) and
    f.bodies.exists(m=>m.checkpoint==H::h.root.checkpoint) and (not(H::h.haveCandidate) or f.bodies.exists(m=>m.checkpoint==H::h.candidate.checkpoint))
  def qualified=confirmed and f.haveLocal and f.local==image and complete
  val floorAligned=f.log.nth(f.log.length()-1).proposal.after==image
  val unique=f.log.indices().forall(i=>f.log.indices().forall(j=>f.log.nth(i).proposal.id!=f.log.nth(j).proposal.id or f.log.nth(i)==f.log.nth(j)))
  val chain=f.log.indices().forall(i=>f.log.nth(i).proposal.parent==i and f.log.nth(i).proposal.worker==f.log.nth(i).proposal.before.worker and
    (i==0 or f.log.nth(i).proposal.before==f.log.nth(i-1).proposal.after))
  val safety=floorAligned and chain and unique and (f.active implies qualified and f.attemptedWorker==H::view.worker) and H::safety
  action idle=all {H::idle,H::h'=H::h}
  action init=all {H::prepared,f'=initial}
  action propose(p,durable)=all {durable,f.pending.forall(old=>old.id!=p.id or old.intent==p.intent),idle,f'=f.with("pending",f.pending.union(Set(p))).with("active",false)}
  def gate(p)=qualified and f.pending.contains(p) and p.parent==f.log.length() and p.before==image and p.worker==H::view.worker and f.log.indices().forall(i=>f.log.nth(i).proposal.id!=p.id)
  pure def appendedImage(i)=i.with("live",i.live.append(H::tailSegment)).with("allocated",i.allocated.union(Set(H::tailSegment))).with("frontier",i.frontier+1)
  pure def cutImage(i)=i.with("closed",i.closed.concat(i.live)).with("live",List()).with("appendGeneration",i.appendGeneration+1).with("sequence",i.sequence+1)
    .with("haveCut",true).with("cut",{id:i.sequence+1,parent:i.root.id,rootGeneration:i.rootGeneration,appendGeneration:i.appendGeneration+1,
      records:H::manifestReplay(i.root).concat(H::flat(i.closed)).concat(H::flat(i.live))})
  pure val pAppend={id:1,intent:12,parent:1,before:i0,after:appendedImage(i0),worker:0}
  pure val i1=pAppend.after
  pure val pCut={id:2,intent:20,parent:2,before:i1,after:cutImage(i1),worker:0}
  pure val i2=pCut.after
  pure val pEarlyCut=pCut.with("parent",1).with("before",i0).with("after",cutImage(i0))
  pure val pFence={id:3,intent:90,parent:3,before:i2,after:i2.with("worker",1),worker:0}
  pure val pOldFence={id:4,intent:90,parent:4,before:pFence.after,after:pFence.after.with("worker",2),worker:0}
  action commitAppend(p,bodyDurable,durable,policy)=all {gate(p),p.intent==12,p.after==appendedImage(image),bodyDurable,durable,policy,
    H::appendFrame(p.worker,p.before.appendGeneration,p.before.frontier,true,true),
    f'=f.with("log",f.log.append({proposal:p})).with("haveReceipt",false).with("active",false)}
  action commitCut(p,bodyDurable,durable,policy)=all {gate(p),p.intent==20,p.after==cutImage(image),bodyDurable,durable,policy,
    H::sealCut(p.worker,p.before.appendGeneration,p.before.frontier,true,true),
    f'=f.with("log",f.log.append({proposal:p})).with("haveReceipt",false).with("active",false)}
  action commitFence(p,bodyDurable,durable,policy)=all {gate(p),p.intent==90,p.after==image.with("worker",H::view.worker+1),bodyDurable,durable,policy,H::rotate,
    f'=f.with("log",f.log.append({proposal:p})).with("haveReceipt",false).with("active",false)}
  action query(worker,authentic)=all {authentic,worker==H::view.worker,H::observe(worker,true),f'=f.with("observed",current).with("haveReceipt",true).with("active",false)}
  action resolve(id)={nondet r=f.log.indices().map(i=>f.log.nth(i)).filter(r=>r.proposal.id==id).oneOf()
    all {idle,f'=f.with("resolved",r).with("haveResolved",true).with("active",false)}}
  action restore(snapshot,objects,bodies)=all {idle,f'=f.with("local",snapshot).with("haveLocal",true).with("objects",objects).with("bodies",bodies).with("haveReceipt",false).with("active",false)}
  action project(worker,authentic)=all {confirmed,complete,authentic,worker==H::view.worker,idle,f'=f.with("local",image).with("haveLocal",true).with("active",false)}
  action activate(worker)=all {qualified,worker==H::view.worker,idle,f'=f.with("active",true).with("attemptedWorker",worker)}
  action loseReply=all {idle,f'=f.with("haveReceipt",false).with("active",false)}
  action installCopies(authentic)=all {authentic,idle,f'=f.with("objects",H::refs.indices().map(i=>H::refs.nth(i))).with("bodies",Set(H::h.root,H::h.candidate)).with("active",false)}
  action submit=all {H::submit,f'=f.with("active",false)}
  action financialCommit=all {H::commit,f'=f.with("active",false)}
  action qualifiedInit=init.then(query(0,true)).then(installCopies(true)).then(project(0,true)).then(activate(0))
  action proposed=qualifiedInit.then(propose(pAppend,true))
  action published=proposed.then(commitAppend(pAppend,true,true,true))
  action recovered=published.then(query(0,true)).then(installCopies(true)).then(project(0,true)).then(activate(0))
  action pending=recovered.then(submit)
  action sealed=pending.then(propose(pCut,true)).then(commitCut(pCut,true,true,true))
  action sealedRecovered=sealed.then(query(0,true)).then(installCopies(true)).then(project(0,true)).then(activate(0))
  action rotated=sealedRecovered.then(propose(pFence,true)).then(commitFence(pFence,true,true,true))
  action rolledBack=rotated.then(restore(i0,Set(H::old),Set(H::root0)))
  action ownerRecovered=rolledBack.then(query(1,true)).then(installCopies(true)).then(project(1,true)).then(activate(1))
  action lateCommitted=sealedRecovered.then(financialCommit)
  action step={nondet p=Set(pAppend,pCut,pEarlyCut,pFence).oneOf() nondet snapshot=Set(i0,i1,i2,image).oneOf()
    any {propose(p,true),commitAppend(p,true,true,true),commitCut(p,true,true,true),commitFence(p,true,true,true),
      query(H::view.worker,true),resolve(p.id),restore(snapshot,Set(),Set()),restore(snapshot,f.objects,f.bodies),installCopies(true),project(H::view.worker,true),
      activate(H::view.worker),loseReply,submit,financialCommit}}
                                                                                                                                
                                                                                                      
                                                                                                          
                                                                                                                                                                   
                                                                                                           
                                                                                         
                                                                                                       
                                                                                             
                                                                        
                                                                                                           
                                                                                                                                                          
                                                                                                                                                    
                                                                                                                                                                         
                                                                                                                                              
                                                                   
                                                                                                                   
                                                                         
                                                                                                 
                                                                                                                                                             
                                                                                                                         
                                                                                                                                                                     
                                                                                                                                      
                                                                                                                        
                                                                                                   
                                                                                                                                                      
                                                                                                                                                  
                                                                           
                                                                                                        
  action unsafeOldFence=all {H::rotate,f'=f.with("log",f.log.append({proposal:pOldFence})).with("haveReceipt",false).with("active",false).with("attemptedWorker",0)}
  action unsafeActivate(worker)=all {idle,f'=f.with("active",true).with("attemptedWorker",worker)}
  action unsafeUseResult=all {f.haveResolved,idle,f'=f.with("observed",{revision:f.resolved.proposal.parent+1,record:f.resolved}).with("haveReceipt",true).with("active",true)}
  action unsafeRollbackLog=all {idle,f'=f.with("log",List(seed))}
  action unsafeDuplicate=all {idle,f'=f.with("log",f.log.append({proposal:pAppend.with("after",pAppend.after.with("appendGeneration",1))}))}
                                                                                                                                                             
                                                                                                                                                                               
                                                                                                                                                       
                                                                                                                                     
                                                                                                                     
                                                                                                             
                                                                                                   
                                                                                                   
}

module LlmAppendHandoff {
  import LlmCheckpointTruncation as C
  type Segment={id:int,records:List[C::Record]}
  type Manifest={id:int,parent:int,checkpoint:C::Checkpoint,haveCheckpoint:bool,segments:List[Segment]}
  type Cut={id:int,parent:int,rootGeneration:int,appendGeneration:int,records:List[C::Record]}
  type Receipt={root:int,rootGeneration:int,appendGeneration:int,frontier:int,worker:int}
  type Storage={root:Manifest,closed:List[Segment],live:List[Segment],objects:Set[Segment],allocated:Set[Segment],
    rootGeneration:int,appendGeneration:int,frontier:int,sequence:int,cut:Cut,haveCut:bool,candidate:Manifest,haveCandidate:bool,
    observed:Receipt,haveObservation:bool,lastAuthorized:bool,attempted:Receipt}
  var h:Storage
  pure val old={id:10,records:C::cp1.basis.journal}
  pure val tailSegment={id:11,records:List(C::fOther)}
  pure val root0={id:0,parent:0,checkpoint:C::cp1,haveCheckpoint:true,segments:List()}
  pure val replacement=root0.with("id",1)
  pure val withPending=replacement.with("segments",List(tailSegment))
  pure val emptyCut={id:0,parent:0,rootGeneration:0,appendGeneration:0,records:List()}
  pure val initial={root:root0,closed:List(),live:List(),objects:Set(old),allocated:Set(old),rootGeneration:0,appendGeneration:0,frontier:0,sequence:0,
    cut:emptyCut,haveCut:false,candidate:root0,haveCandidate:false,
    observed:{root:0,rootGeneration:0,appendGeneration:0,frontier:0,worker:0},haveObservation:true,lastAuthorized:true,attempted:{root:0,rootGeneration:0,appendGeneration:0,frontier:0,worker:0}}
  pure def flat(xs)=xs.foldl(List(),(rs,seg)=>rs.concat(seg.records))
  pure def manifestReplay(r)=r.checkpoint.basis.journal.concat(flat(r.segments))
  def snapshot=manifestReplay(h.root).concat(flat(h.closed))
  def replay=snapshot.concat(flat(h.live))
  def refs=h.root.segments.concat(h.closed).concat(h.live).concat(if(h.haveCandidate) h.candidate.segments else List())
  def view={root:h.root.id,rootGeneration:h.rootGeneration,appendGeneration:h.appendGeneration,frontier:h.frontier,worker:C::pubView.epoch}
  def confirmed=h.haveObservation and h.observed==view
  def descriptor(worker,generation,frontier)=confirmed and worker==C::pubView.epoch and generation==h.appendGeneration and frontier==h.frontier
  val available=C::c.blobs.contains(h.root.checkpoint) and (not(h.haveCandidate) or C::c.blobs.contains(h.candidate.checkpoint)) and refs.indices().forall(i=>h.objects.contains(refs.nth(i)))
  val represented=replay==C::expanded and h.root.checkpoint==C::c.local and C::c.haveLocal and flat(h.root.segments).concat(flat(h.closed)).concat(flat(h.live))==C::c.suffix
  val aligned=not(h.haveCut) or (h.cut.records==snapshot and h.cut.parent==h.root.id and h.cut.rootGeneration==h.rootGeneration and h.cut.appendGeneration==h.appendGeneration)
  val candidateAligned=not(h.haveCandidate) or (h.haveCut and manifestReplay(h.candidate)==h.cut.records)
  val safety=available and represented and aligned and candidateAligned and h.lastAuthorized and C::safety
  action idle=C::observeFinancial
  action init=all {C::recovered,h'=initial}
  action observe(worker,authentic)=all {authentic,available,worker==C::pubView.epoch,idle,h'=h.with("observed",view).with("haveObservation",true)}
  action prepare=all {C::prepareOther,h'=h}
  action appendFrame(worker,generation,frontier,durable,policy)=all {descriptor(worker,generation,frontier),durable,policy,h.allocated.forall(seg=>seg.id!=tailSegment.id),
    C::flushOther,h'=h.with("live",h.live.append(tailSegment)).with("objects",h.objects.union(Set(tailSegment))).with("allocated",h.allocated.union(Set(tailSegment)))
      .with("frontier",h.frontier+1).with("haveObservation",false)}
  action sealCut(worker,generation,frontier,durable,policy)=all {policy,not(h.haveCut),not(h.haveCandidate),descriptor(worker,generation,frontier),durable,idle,
    h'=h.with("cut",{id:h.sequence+1,parent:h.root.id,rootGeneration:h.rootGeneration,appendGeneration:h.appendGeneration+1,records:replay})
      .with("haveCut",true).with("sequence",h.sequence+1).with("closed",h.closed.concat(h.live)).with("live",List())
      .with("appendGeneration",h.appendGeneration+1).with("haveObservation",false)}
  action stage(r,durable)=all {h.haveCut,manifestReplay(r)==h.cut.records,r.parent==h.cut.parent,durable,
    C::c.blobs.contains(r.checkpoint),r.segments.indices().forall(i=>h.objects.contains(r.segments.nth(i))),idle,h'=h.with("candidate",r).with("haveCandidate",true)}
  action switchRoot(worker,generation,frontier,durable,policy)=all {h.haveCut,h.haveCandidate,aligned,candidateAligned,descriptor(worker,generation,frontier),durable,policy,
    h.candidate.parent==h.root.id,available,C::trim(h.candidate.checkpoint,flat(h.candidate.segments).concat(flat(h.live)),worker,true),
    h'=h.with("root",h.candidate).with("closed",List()).with("rootGeneration",h.rootGeneration+1).with("haveCut",false).with("haveCandidate",false).with("haveObservation",false)}
  action erase(id,worker,generation,frontier,policy)=all {policy,descriptor(worker,generation,frontier),refs.indices().forall(i=>refs.nth(i).id!=id),idle,
    h'=h.with("objects",h.objects.filter(seg=>seg.id!=id))}
  action submit=all {C::submitOther,h'=h}
  action commit=all {C::commitOther,h'=h}
  action rotate=all {C::rotate,h'=h}
  action crash=all {C::loseReply,h'=h.with("haveObservation",false)}
  action refresh=all {C::observe(true),h'=h}
  action install=all {C::install,h'=h}
  action activate=all {confirmed,safety,C::activate(C::pubView.epoch,true),h'=h}
  action prepared=init.then(prepare)
  action cutFirst=prepared.then(sealCut(0,0,0,true,true)).then(observe(0,true)).then(stage(replacement,true))
  action appended=cutFirst.then(appendFrame(0,1,0,true,true))
  action pending=appended.then(submit)
  action switched=pending.then(observe(0,true)).then(switchRoot(0,1,1,true,true))
  action lateCommitted=switched.then(commit)
  action preCutPending=prepared.then(appendFrame(0,0,0,true,true)).then(submit).then(observe(0,true)).then(sealCut(0,0,1,true,true)).then(stage(withPending,true))
  action recovered=lateCommitted.then(crash).then(observe(0,true)).then(refresh).then(install).then(activate)
  action oldOwner=pending.then(crash).then(rotate).then(observe(1,true)).then(refresh)
  action step={nondet r=Set(replacement,withPending).oneOf() nondet id=Set(10,11,99).oneOf()
    any {prepare,appendFrame(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),sealCut(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),
      stage(r,true),switchRoot(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),observe(C::pubView.epoch,true),
      erase(id,C::pubView.epoch,h.appendGeneration,h.frontier,true),submit,commit,rotate,crash,refresh,install,activate}}
                                                                                                                           
                                                                                                                                     
                                                                                                                                                                  
                                                                                                                             
                                                                                                      
                                                                                                                                          
                                                                                                                                       
                                                                                        
                                                                                                          
                                                                                         
                                                                                                                       
                                                              
                                                                                   
                                                                            
                                                                                               
                                                                                                      
                                                                                         
                                                                               
                                                                                   
                                                                                      
                                                                                                          
                                                                                                            
                                                                                                                                                    
                                                                                                                                                 
                                                                                                                                                                                           
                                                                                                                                                               
                                                                        
                                                                                 
                                                                                        
                                                                                                      
  action unsafeDropLive=all {idle,h'=h.with("live",List())}
  action unsafeDropClosed=all {idle,h'=h.with("closed",List()).with("cut",h.cut.with("records",manifestReplay(h.root)))}
  action unsafeEraseTail=all {idle,h'=h.with("objects",h.objects.filter(seg=>seg.id!=11))}
  action unsafeAppend(worker,generation,frontier)=all {C::flushOther,
    h'=h.with("live",h.live.append(tailSegment)).with("objects",h.objects.union(Set(tailSegment))).with("allocated",h.allocated.union(Set(tailSegment)))
      .with("frontier",h.frontier+1).with("lastAuthorized",descriptor(worker,generation,frontier)).with("attempted",view.with("worker",worker).with("appendGeneration",generation).with("frontier",frontier))}
  action unsafeSwitchDescriptor(worker,generation,frontier)=all {idle,h'=h.with("lastAuthorized",descriptor(worker,generation,frontier)).with("attempted",view.with("worker",worker).with("appendGeneration",generation).with("frontier",frontier))}
  action unsafePendingCheckpoint=all {C::unsafePublish(C::cp2),h'=h}
                                                                                                
                                                                                                         
                                                                                                
                                                                                                                            
                                                                                                                                         
                                                                                                                 
                                                                                                                    
                                                                                                                                
}

module LlmBootstrapInvitation {
  import LlmIncarnationIssuance as B
  import LlmCallerCustody.auth
  import LlmAdmissionFloor.f
  import LlmAccountCommit.a
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
                                                                                                                   
                                                                                   
                                                                                                                     
                                                                                                              
                                                                                                    
                                                                                                 
                                                                                                 
                                                                                           
                                                                                                              
                                                                                                         
                                                                                                                                                                                                                          
                                                                                                                 
                                                                                                                                                                                                          
                                                                                
                                                                                     
                                                                                                                          
                                                                                                             
                                                                                                                                                 
                                                                                                                                                                                 
  // Deliberately unsafe mutations, excluded from step. They expose broken contracts.
  action unsafeIssue:bool=all {B::issue(9,B::ticket,true,true,false),invitations'=invitations}
  action eraseResult:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set())}
  action consumeWithoutIssue:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set(0)).with("results",invitations.results.replaceAt(0,B::ticket2))}
  action replaceBinding:bool=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("bindings",invitations.bindings.replaceAt(0,B::ticket2))}
                                                                                                                                                                                                
                                                                                                                                                                                   
                                                                                                                                                                         
                                                                                                                                                                     
}

module LlmCallerCustody {
  import LlmCustodyPublication as P
  import LlmSourceCustody.custody
  import LlmSourceCustody.restart
  import LlmAdmissionFloor.f
  type Grant={serial:int,domain:int,workload:int,inc:int,key:int,holder:int,fence:int,expires:int,purpose:bool}
  type Peer={workload:int,inc:int,key:int,recovery:bool}
  type Auth={grant:Grant,used:Set[int],caps:List[Grant],now:int,checked:bool}
  var auth:Auth
  pure val first={serial:0,domain:7,workload:9,inc:0,key:100,holder:0,fence:0,expires:10,purpose:true}
  pure val initialAuth={grant:first,used:Set(0),caps:List(first),now:0,checked:true}
  // Channels are authenticated native contexts. A payload cannot choose or rewrite them.
  pure def peer(ch:int):Peer = if(ch==0 or ch==2) {workload:9,inc:0,key:100,recovery:false}
    else if(ch==1) {workload:9,inc:1,key:200,recovery:false}
    else if(ch==3) {workload:9,inc:0,key:101,recovery:false}
    else {workload:9,inc:99,key:900,recovery:ch==9}
  def bound(ch:int,g:Grant):bool={val c=peer(ch)
    Set(0,1,2,3).contains(ch) and g==auth.grant and not(c.recovery) and c.workload==g.workload and c.inc==g.inc and c.key==g.key and auth.now<g.expires and g.purpose and g.holder==custody.holder and g.fence==custody.fence}
  def aligned=auth.caps.length()==P::pub.log.length() and auth.caps.nth(auth.caps.length()-1)==auth.grant and auth.grant.fence==custody.fence and auth.grant.holder==custody.holder
  val invariant=P::invariant and aligned and auth.checked and auth.used.contains(auth.grant.inc) and auth.grant.domain==7 and auth.grant.expires==10 and custody.original==P::initialEntry.original
  action idle=all {P::noEffect,P::pub'=P::pub}
  action boot=all {P::boot,auth'=initialAuth}
  action read=all {P::readAuthority(true),auth'=auth}
  action stage(slot,kind,holder,fence)=all {P::stage(slot,kind,holder,fence),auth'=auth}
  def note(g:Grant):Auth=auth.with("grant",g).with("caps",auth.caps.append(g)).with("used",auth.used.union(Set(g.inc)))
  action publish(ch,g,slot,deliver)=all {bound(ch,g),P::pub.commands.nth(slot).kind!=1,P::commit(slot,deliver),auth'=note(auth.grant)}
  // Recovery authorization and fresh key enrollment are native owner premises.
  action handoff(ch,allowed,enrolled,inc,key,holder,slot,deliver)={val g=auth.grant.with("serial",auth.grant.serial+1).with("inc",inc).with("key",key).with("holder",holder).with("fence",auth.grant.fence+1)
    all {peer(ch).recovery,allowed,enrolled,not(auth.used.contains(inc)),P::pub.commands.nth(slot).kind==1,P::pub.commands.nth(slot).holder==holder,P::commit(slot,deliver),auth'=note(g)}}
  action redeliver(ch,g)=all {bound(ch,g),idle,auth'=auth}
  // One protected C.restart publication, not a resolving read or a new floor attempt.
  action rotate(ch,g,enrolled,newKey,parent,deliver)={val replacement=g.with("serial",g.serial+1).with("key",newKey)
    all {bound(ch,g),enrolled,newKey!=g.key,P::ready,parent==P::pub.log.length(),restart,P::pub'=P::noted(P::image,deliver),auth'=note(replacement)}}
  action tick=all {idle,auth'=auth.with("now",auth.now+1)}
  action crash=all {P::crash,auth'=auth}
  action ack=all {P::acknowledge(0),auth'=auth}
  action staged=boot.then(read).then(stage(0,0,0,0))
  action committed=staged.then(publish(0,first,0,false))
  action handed=staged.then(stage(1,1,1,0)).then(handoff(9,true,true,1,200,1,1,false))
  action recovered=handed.then(read).then(stage(1,2,1,1)).then(publish(1,auth.grant,1,true)).then(read).then(stage(1,3,1,1)).then(publish(1,auth.grant,1,true)).then(read).then(stage(1,4,1,1)).then(publish(1,auth.grant,1,true))
  action rotated=staged.then(rotate(0,first,true,101,1,false))
  action restarted=committed.then(crash)
  action expired=staged.then(all {idle,auth'=auth.with("now",10)})
  action step={nondet ch=Set(0,1,2,3,9).oneOf()
    nondet slot=Set(0,1).oneOf()
    nondet kind=Set(0,1,2,3,4,5).oneOf()
    nondet holder=Set(0,1).oneOf()
    any {read,stage(slot,kind,holder,custody.fence),publish(ch,auth.grant,slot,true),publish(ch,auth.grant,slot,false),handoff(ch,true,true,1,200,holder,slot,false),redeliver(ch,auth.grant),rotate(ch,auth.grant,true,101,P::pub.log.length(),false),tick,crash,ack}}
                                                                       
                                                                                     
                                                                                                                            
                                                                                                                                                                   
                                                                                                                              
                                                                                                                                  
                                                                            
                                                                                                                    
                                                                                                                     
                                                                                                          
                                                                                                                          
                                                                                                                                                                
                                                                                                                                    
                                                                                          
                                                                                  
                                                                                
                                                                                                                                                                                         
                                                                                               
                                                                                                 
                                                                                                                            
  // Fault-injected boundaries: these are deliberately outside the guarded relation.
  action bypassCaller(slot)=all {P::commit(slot,false),auth'=note(auth.grant).with("checked",false)}
  action splitGrant=all {P::commit(1,false),auth'=auth}
  action mintFromWorkload=all {idle,auth'=auth.with("grant",auth.grant.with("inc",0).with("key",100))}
  action renewOnRedelivery=all {idle,auth'=auth.with("grant",auth.grant.with("expires",20))}
  action forgetIncarnations=all {idle,auth'=auth.with("used",Set())}
                                                                                                                                                         
                                                                                                               
                                                                                                                                                         
                                                                                               
                                                                                                                            
                                                                                                 
                                                                                                                                                         
}

module LlmCheckpointTruncation {
  import LlmWalActivation as W
  // Structural types match the imported account records; all financial actions stay imported.
  type Key={root:int,claim:int,profile:int,budget:int,history:int,reservation:int}
  type Transaction={id:int,key:Key,bound:int,usage:int,resolution:int,source:int,meter:int}
  type Balance={available:int,held:int,charged:int}
  type Image={revision:int,balance:Balance,applications:Set[Transaction],used:Set[int],holds:int->int}
  type Proposal={transaction:Transaction,before:Image,worker:int,sourceGeneration:int}
  type Record={proposal:Proposal,after:Image,epoch:int}
  type Checkpoint={id:int,parent:int,position:int,basis:W::Receipt}
  type PubReceipt={checkpoint:Checkpoint,hasCheckpoint:bool,generation:int,epoch:int,sourceGeneration:int}
  type Storage={published:List[Checkpoint],blobs:Set[Checkpoint],local:Checkpoint,haveLocal:bool,suffix:List[Record],observed:PubReceipt,haveObservation:bool,floorSeen:int}
  var c:Storage
  pure val empty={id:0,parent:0,position:0,basis:W::zero}
  pure val cp1={id:1,parent:0,position:1,basis:{head:W::f0.after,journal:List(W::f0),epoch:0,sourceGeneration:0}}
  pure val initial={published:List(),blobs:Set(),local:empty,haveLocal:false,suffix:List(W::f0),
    observed:{checkpoint:empty,hasCheckpoint:false,generation:0,epoch:0,sourceGeneration:0},haveObservation:true,floorSeen:0}
  pure def prefixOf(xs,ys)=xs.length()<=ys.length() and xs.indices().forall(i=>xs.nth(i)==ys.nth(i))
  pure def tip(xs)=if (xs.length()==0) W::zero.head else xs.nth(xs.length()-1).after
  def latest=if (c.published.length()==0) empty else c.published.nth(c.published.length()-1)
  def floor=latest.position
  def expanded=(if (c.haveLocal) c.local.basis.journal else List()).concat(c.suffix)
  def represented=expanded==W::w.records
  def floorSupported=if (c.published.length()==0) not(c.haveLocal) else c.haveLocal and c.local==latest
  def valid(cp)=cp.position==cp.basis.journal.length() and cp.basis.head==tip(cp.basis.journal) and prefixOf(cp.basis.journal,W::view.journal)
  def pubView={checkpoint:latest,hasCheckpoint:c.published.length()>0,generation:c.published.length(),epoch:W::view.epoch,sourceGeneration:W::view.sourceGeneration}
  def publicationCurrent=c.haveObservation and c.observed==pubView
  action init=all {W::activated,c'=initial}
  action persist(cp,durable)=all {valid(cp),durable,W::observe(true),c'=c.with("blobs",c.blobs.union(Set(cp)))}
  action publish(cp,worker,durable,policy)=all {c.blobs.contains(cp),valid(cp),cp.parent==c.published.length(),
    c.published.indices().forall(i=>c.published.nth(i).id!=cp.id),cp.position>floor,worker==W::view.epoch,
    cp.basis.epoch==worker,cp.basis.sourceGeneration==W::view.sourceGeneration,durable,policy,W::loseReply,
    c'=c.with("published",c.published.append(cp)).with("floorSeen",cp.position)}
  action observe(authentic)=all {authentic,W::observe(authentic),c'=c.with("observed",pubView).with("haveObservation",true)}
  action trim(cp,frames,worker,durable)=all {c.published.length()>0,cp==latest,publicationCurrent,worker==W::view.epoch,c.blobs.contains(cp),durable,
    cp.basis.journal.concat(frames)==W::w.records,W::loseReply,c'=c.with("local",cp).with("haveLocal",true).with("suffix",frames)}
  action restore(cp,have,frames)=all {W::restoreWal((if (have) cp.basis.journal else List()).concat(frames)),
    c'=c.with("local",cp).with("haveLocal",have).with("suffix",frames)}
  action repair(cp,frames,authentic)=all {authentic,cp==latest,if (c.published.length()>0) c.blobs.contains(cp) else true,
    (if (c.published.length()>0) cp.basis.journal else List()).concat(frames)==W::view.journal,W::repair(true),
    c'=c.with("local",cp).with("haveLocal",c.published.length()>0).with("suffix",frames)}
  action activate(worker,authentic)=all {represented,floorSupported,publicationCurrent,worker==W::view.epoch,W::activate(authentic),c'=c}
  action observeFinancial=all {W::observe(true),c'=c}
  action install=all {W::install,c'=c}
  action rotate=all {W::rotate,c'=c}
  action loseReply=all {W::loseReply,c'=c.with("haveObservation",false)}
  action loseBlob(cp)=all {W::loseReply,c'=c.with("blobs",c.blobs.exclude(Set(cp)))}
  action restoreAccount(image)=all {W::restoreImage(image),c'=c}
  action built=init.then(persist(cp1,true))
  action published=built.then(publish(cp1,0,true,true))
  action confirmed=published.then(observe(true))
  action truncated=confirmed.then(trim(cp1,List(),0,true))
  action recovered=truncated.then(observe(true)).then(observeFinancial).then(activate(0,true))
  action rolledBack=recovered.then(rotate).then(restore(empty,false,List())).then(restoreAccount(W::zero.head))
  pure val txOther=W::f0.proposal.transaction.with("id",101).with("key",W::f0.proposal.transaction.key.with("root",20).with("claim",12).with("reservation",12))
    .with("bound",2).with("usage",1).with("resolution",2).with("source",2).with("meter",2)
  pure val pOther={transaction:txOther,before:W::f0.after,worker:0,sourceGeneration:0}
  pure val fOther=W::frame(pOther)
  pure val cp2={id:2,parent:1,position:2,basis:{head:fOther.after,journal:List(W::f0,fOther),epoch:0,sourceGeneration:0}}
  action prepareOther=all {W::prepareNext(pOther),c'=c}
  action flushOther=all {W::flush(pOther,true),c'=c.with("suffix",c.suffix.append(fOther))}
  action submitOther=all {W::submit(pOther,true),c'=c}
  action commitOther=all {W::anchor(pOther,true,true),c'=c}
  action appendOther=prepareOther.then(flushOther).then(submitOther).then(commitOther)
  action twoRecords=recovered.then(appendOther)
  action secondPublished=twoRecords.then(persist(cp2,true)).then(publish(cp2,0,true,true))
  val publishedSafe=c.published.indices().forall(i=>valid(c.published.nth(i)) and c.published.nth(i).parent==i and
    (if (i==0) c.published.nth(i).position>0 else c.published.nth(i).position>c.published.nth(i-1).position))
  val live=W::w.active implies represented and floorSupported and publicationCurrent
  val floorMonotone=floor>=c.floorSeen
  val safety=floorMonotone and W::safety and publishedSafe and live
  action step={nondet cp=Set(cp1,cp2).oneOf() nondet frames=Set(List(),List(W::f0),List(fOther),W::w.records).oneOf()
    any {persist(cp,true),publish(cp,W::view.epoch,true,true),observe(true),trim(cp,frames,W::view.epoch,true),
      restore(empty,false,frames),restore(cp,true,frames),repair(latest,frames,true),activate(W::view.epoch,true),observeFinancial,install,rotate,loseReply,loseBlob(cp)}}
                                                                                                                                            
                                                                                        
                                                                               
                                                                                       
                                                                                
                                                                                                       
                                                                                                                                                                 
                                                                                                                                                                                                            
                                                                                                                                                     
                                                                                                                                                                  
                                                                                                                                                                    
                                                                                                                                                                                    
                                                                                                                                                                                                
                                                                                                                                                                             
                                                                                                                                                                                          
                                                                                                                                                                                    
                                                                                                                                
                                                                                                          
                                                                                                                                                                         
                                                                                                                                                                               
                                                                                                   
                                                                                                                                                                      
                                                                                                      
                                                                                                                                                       
                                                                             
                                                                                        
                                                                                                                                                  
  action retryOriginal=all {W::anchor(W::f0.proposal,true,true),c'=c}
                                                                                           
                                                                                                                                                                   
                                                                                                                                                                            
                                                                                                                                          
                                                                                                                               
                                                                                                                                                                                    
                                                                                                             
  action unsafeBypassPublicationGate=all {W::activate(true),c'=c}
  action unsafePublish(cp)=all {W::loseReply,c'=c.with("published",c.published.append(cp))}
  action unsafeActivate=all {W::unsafeActivate,c'=c}
  action unsafeFloorRollback=all {W::loseReply,c'=c.with("published",List())}
                                                                                                                                                                                            
                                                                                                                                                                                    
                                                                                                                                                                                                       
                                                                                                                                                                           
                                                                                                                                                                  
                                                                                                                                                                               
                                                                                                                                                                                                                                                           
                                                                                                                                          
                                                                                                                                                                              
                                                                                                                                                                                                 
}

module LlmCustodyPublication {
  import LlmSourceCustody as C
  import LlmAdmissionFloor.Proposal
  import LlmAdmissionFloor.Record
  import LlmAdmissionFloor.f
  import LlmAdmissionFloor.pAppend
  import LlmAdmissionFloor.seed
  type Entry={fence:int,holder:int,original:Proposal,haveIntent:bool,outcome:Record,haveOutcome:bool,floor:List[Record]}
  type Command={kind:int,holder:int,fence:int}
  type Publication={log:List[Entry],commands:List[Command],parents:List[int],staged:Set[int],copy:Entry,seen:int,qualified:bool,haveCopy:bool,reply:int,haveReply:bool,lastChecked:bool}
  var pub:Publication
  pure val emptyCommand={kind:0,holder:0,fence:0}
  pure val initialEntry={fence:0,holder:0,original:pAppend,haveIntent:true,outcome:seed,haveOutcome:false,floor:List(seed)}
  pure val initialPublication={log:List(initialEntry),commands:List(emptyCommand,emptyCommand),parents:List(0,0),staged:Set(),copy:initialEntry,seen:0,qualified:false,haveCopy:false,reply:0,haveReply:false,lastChecked:true}
  def image={fence:C::custody.fence,holder:C::custody.holder,original:C::custody.original,haveIntent:C::custody.haveIntent,outcome:C::custody.outcome,haveOutcome:C::custody.haveOutcome,floor:f.log}
  def aligned=pub.log.nth(pub.log.length()-1)==image
  def ready=pub.qualified and pub.haveCopy and pub.seen==pub.log.length() and pub.copy==image
  def gate(slot)=pub.staged.contains(slot) and ready and pub.parents.nth(slot)==pub.log.length()
  val invariant=C::safety and aligned and pub.lastChecked
  action noEffect=all {C::idle,C::custody'=C::custody}
  action boot=all {C::armed,pub'=initialPublication}
  def noted(entry,deliver)=pub.with("log",pub.log.append(entry)).with("qualified",false).with("reply",pub.log.length()+1).with("haveReply",deliver)
  action readAuthority(authentic)=all {authentic,aligned,noEffect,pub'=pub.with("copy",image).with("seen",pub.log.length()).with("haveCopy",true).with("qualified",true)}
  action stage(slot,kind,holder,fence)=all {Set(0,1).contains(slot),0<=kind,kind<=5,ready,noEffect,pub'=pub.with("commands",pub.commands.replaceAt(slot,{kind:kind,holder:holder,fence:fence})).with("parents",pub.parents.replaceAt(slot,pub.log.length())).with("staged",pub.staged.union(Set(slot)))}
  action commit(slot,deliver)={val cmd=pub.commands.nth(slot)
    all {gate(slot),any {
      all {cmd.kind==0,C::publish(cmd.holder,cmd.fence),pub'=noted(image.with("outcome",{proposal:C::custody.attempt}).with("haveOutcome",true).with("floor",f.log.append({proposal:C::custody.attempt})),deliver)},
      all {cmd.kind==1,C::transfer(cmd.holder,true),pub'=noted(image.with("fence",C::custody.fence+1).with("holder",cmd.holder),deliver)},
      all {cmd.kind==2,C::resolve(cmd.holder,cmd.fence,true),pub'=noted(image,deliver)},
      all {cmd.kind==3,C::validate,pub'=noted(image,deliver)},
      all {cmd.kind==4,C::arm(cmd.holder,cmd.fence,true),pub'=noted(image,deliver)},
      all {cmd.kind==5,C::close(cmd.holder,cmd.fence),pub'=noted(image,deliver)}
    }}
  }
  action restore(copy,seen)=all {noEffect,pub'=pub.with("copy",copy).with("seen",seen).with("haveCopy",true).with("qualified",false)}
  action crash=all {noEffect,pub'=pub.with("haveCopy",false).with("qualified",false).with("haveReply",false)}
  action acknowledge(index)=all {0<=index,index<pub.log.length(),noEffect,pub'=pub.with("reply",index+1).with("haveReply",true)}
  action loseReply=all {noEffect,pub'=pub.with("haveReply",false)}
  action applyCommand(slot,kind,holder,fence)=readAuthority(true).then(stage(slot,kind,holder,fence)).then(commit(slot,true))
  action armed=boot
  action stagedFloor=armed.then(readAuthority(true)).then(stage(0,0,0,0))
  action committed=stagedFloor.then(commit(0,false))
  action handed=stagedFloor.then(applyCommand(1,1,1,0))
  action recovered=handed.then(applyCommand(1,2,1,1)).then(applyCommand(1,3,1,1)).then(applyCommand(1,4,1,1))
  action transferredCommit=committed.then(applyCommand(1,1,1,0))
  action resolvedCommit=transferredCommit.then(applyCommand(1,2,1,1))
  action restored=committed.then(restore(initialEntry,1))
  action exactCopyRestored=committed.then(restore(image,pub.log.length()))
  action restarted=committed.then(crash)
  action finished=resolvedCommit.then(applyCommand(1,5,1,1))
  action step={nondet slot=Set(0,1).oneOf()
    nondet kind=Set(0,1,2,3,4,5).oneOf()
    nondet holder=Set(0,1).oneOf()
    nondet fence=Set(0,1,2,C::custody.fence).oneOf()
    any {readAuthority(true),stage(slot,kind,holder,fence),commit(slot,true),commit(slot,false),restore(initialEntry,1),restore(image,pub.log.length()),crash,acknowledge(0),loseReply}}
                                                                                                                          
                                                                                                                                          
                                                                                                                                                
                                                                                                     
                                                                                                                             
                                                                                                               
                                                                                                                              
                                                                        
                                                                                       
                                                                                                                                      
                                                                                                                    
                                                                                                                          
                                                                                         
                                                                                                                              
                                                                                                                   
                                                                                                                                                                                                                                     
                                                                                                                                                      
                                                                                                              
  action splitFence=all {C::transfer(1,true),pub'=pub.with("reply",pub.log.length()+1).with("haveReply",true)}
  action splitOutcome=all {C::publish(0,0),pub'=pub.with("reply",pub.log.length()+1).with("haveReply",true)}
  action dropOutcome=all {C::idle,C::custody'=C::custody.with("haveOutcome",false).with("outcome",seed),pub'=pub}
  action dropOriginal=all {C::idle,C::custody'=C::custody.with("haveIntent",false),pub'=pub}
  action trustUnqualifiedCopy=all {noEffect,pub'=pub.with("qualified",true).with("lastChecked",pub.qualified)}
  action ackAsFreshness=all {noEffect,pub'=pub.with("reply",1).with("haveReply",true).with("qualified",true).with("seen",pub.log.length()).with("lastChecked",false)}
  action oldWorkerPublication=all {C::unsafeOldPublish,pub'=noted(image.with("outcome",{proposal:C::custody.attempt}).with("haveOutcome",true).with("floor",f.log.append({proposal:C::custody.attempt})),true)}
                                                                                           
                                                                                                     
                                                                                                 
                                                                                                      
                                                                                                                              
                                                                                                                  
                                                                                                                              
}

module LlmExecutionReconciliation {
  import LlmExecutorOffer as X
  type Key={root:int,claim:int,profile:int,budget:int,history:int,slot:int,lo:int,hi:int}
  type Decision={key:Key,kind:int,cut:int,burns:int,calls:int,submitted:bool}
  type Application={decision:Decision,worker:int,epoch:int}
  type Payment={decision:Decision,amount:int,released:int,worker:int,epoch:int}
  type Reconciliation={epoch:int,qualified:bool,sealed:bool,decisions:List[Decision],source:List[Application],usage:int,
    payments:List[Payment],released:int,terminalEvidence:bool,usageEvidence:bool,conflict:bool,dispatchView:int,sourceView:int,accountView:int}
  var e:Reconciliation
  pure val key={root:10,claim:11,profile:30,budget:5,history:9,slot:11,lo:0,hi:4}
  pure val initial={epoch:0,qualified:true,sealed:false,decisions:List(),source:List(),usage:-1,payments:List(),released:0,
    terminalEvidence:false,usageEvidence:false,conflict:false,dispatchView:0,sourceView:0,accountView:0}
  def current(kind)={key:key,kind:kind,cut:e.epoch,burns:X::s.burns.size(),calls:X::s.laneCalls,submitted:X::s.submitted}
  pure val absent={key:key,kind:1,cut:0,burns:0,calls:0,submitted:false}
  pure val executed={key:key,kind:2,cut:0,burns:1,calls:1,submitted:true}
  action init=all {X::enqueued,e'=initial}
  action inert=all {X::timeout,e'=e}
  action seal(worker,complete)=all {worker==e.epoch,e.qualified,not(e.conflict),complete,X::timeout,e'=e.with("sealed",true)}
  action decide(kind,worker,complete)=all {e.sealed,e.qualified,not(e.conflict),worker==e.epoch,complete,e.decisions.length()==0,
    if (kind==1) X::s.burns.size()==0 and not(X::s.submitted) and X::s.laneCalls==0
      else kind==2 and X::s.submitted and X::s.laneCalls==1 and e.terminalEvidence,
    X::timeout,e'=e.with("decisions",List(current(kind))).with("dispatchView",1)}
  action sourceCAS(d,worker)=all {e.qualified,not(e.conflict),worker==e.epoch,e.decisions==List(d),e.source.length()==0,
    X::timeout,e'=e.with("source",List({decision:d,worker:worker,epoch:e.epoch})).with("sourceView",1)}
  action usageCAS(d,amount,worker,authentic)=all {worker==e.epoch,e.qualified,not(e.conflict),e.decisions==List(d),e.source.length()==1,e.usage<0,
    amount>=0,amount<=3,authentic,if (d.kind==1) amount==0 else e.usageEvidence,
    X::timeout,e'=e.with("usage",amount)}
  action accountCAS(d,worker,authentic)=all {e.qualified,not(e.conflict),worker==e.epoch,e.decisions==List(d),e.source.length()==1,
    e.source.nth(0).decision==d,e.usage>=0,e.payments.length()==0,authentic,X::timeout,
    e'=e.with("payments",List({decision:d,amount:e.usage,released:3-e.usage,worker:worker,epoch:e.epoch})).with("released",3-e.usage).with("accountView",1)}
  action terminalReceipt(authentic)=all {authentic,X::s.submitted,X::s.laneCalls==1,X::timeout,e'=e.with("terminalEvidence",true)}
  action finalUsageReceipt(authentic)=all {authentic,e.terminalEvidence,X::timeout,e'=e.with("usageEvidence",true)}
  action lateFull=all {X::fullReceipt(X::t0,4,true),e'=e}
  action latePartial=all {X::partial(X::t0,2),e'=e}
  action conflict=all {X::timeout,e'=e.with("qualified",false).with("conflict",true)}
  action restart=all {X::restart,e'=e.with("epoch",e.epoch+1).with("qualified",false).with("dispatchView",-1).with("sourceView",-1).with("accountView",-1)}
  action recover(dispatchExact,sourceExact,accountExact)=all {not(e.qualified),not(e.conflict),dispatchExact,sourceExact,accountExact,e.dispatchView==e.decisions.length(),e.sourceView==e.source.length(),e.accountView==e.payments.length(),
    X::timeout,e'=e.with("qualified",true)}
  action restoreDispatch(pos)=all {not(e.qualified),pos>=0,pos<=e.decisions.length(),X::timeout,e'=e.with("dispatchView",pos)}
  action restoreSource(pos)=all {not(e.qualified),pos>=0,pos<=e.source.length(),X::timeout,e'=e.with("sourceView",pos)}
  action restoreAccount(pos)=all {not(e.qualified),pos>=0,pos<=e.payments.length(),X::timeout,e'=e.with("accountView",pos)}
  action restoreAll=restoreDispatch(e.decisions.length()).then(restoreSource(e.source.length())).then(restoreAccount(e.payments.length()))
  action drive=all {not(e.sealed),X::step,e'=e}
  action burned=all {X::burned,e'=initial}
  action offered=all {X::offered,e'=initial}
  action negativeDecision=init.then(seal(0,true)).then(decide(1,0,true))
  action terminalDecision=offered.then(seal(0,true)).then(terminalReceipt(true)).then(decide(2,0,true))
  action sourceApplied=terminalDecision.then(sourceCAS(executed,0))
  action usageApplied=sourceApplied.then(finalUsageReceipt(true)).then(usageCAS(executed,2,0,true))
  action paid=usageApplied.then(accountCAS(executed,0,true))
  val unique=e.decisions.length()<=1 and e.source.length()<=1 and e.payments.length()<=1
  val negativeSound=e.decisions.indices().forall(i=>{val d=e.decisions.nth(i)
    d.kind!=1 or (d.burns==0 and d.calls==0 and not(d.submitted) and X::s.burns.size()==0 and X::s.laneCalls==0)})
  val positiveSound=e.decisions.indices().forall(i=>{val d=e.decisions.nth(i)
    d.kind!=2 or (d.calls==1 and d.submitted and e.terminalEvidence)})
  val original=e.decisions.indices().forall(i=>e.decisions.nth(i).key==key) and
    e.source.indices().forall(i=>e.decisions==List(e.source.nth(i).decision)) and
    e.payments.indices().forall(i=>e.decisions==List(e.payments.nth(i).decision))
  val evidence=e.usage<0 or (e.source.length()==1 and e.decisions.length()==1 and
    (if (e.decisions.nth(0).kind==1) e.usage==0 else e.usageEvidence))
  val held=e.payments.length()==0 implies e.released==0
  val settled=e.payments.indices().forall(i=>{val p=e.payments.nth(i)
    p.worker==p.epoch and e.source.length()==1 and e.usage>=0 and p.amount==e.usage and p.released+e.usage==3 and e.released==p.released})
  val qualifiedViews=e.qualified implies e.dispatchView==e.decisions.length() and e.sourceView==e.source.length() and e.accountView==e.payments.length()
  val safety=qualifiedViews and X::safety and unique and negativeSound and positiveSound and original and evidence and held and settled
  action step={nondet kind=Set(1,2).oneOf() nondet amount=Set(0,2,3).oneOf()
    nondet d=e.decisions.indices().map(i=>e.decisions.nth(i)).union(Set(absent,executed)).oneOf()
    any {drive,seal(e.epoch,true),decide(kind,e.epoch,true),sourceCAS(d,e.epoch),usageCAS(d,amount,e.epoch,true),accountCAS(d,e.epoch,true),
      terminalReceipt(true),finalUsageReceipt(true),lateFull,latePartial,restart,restoreDispatch(e.decisions.length()),restoreSource(e.source.length()),restoreAccount(e.payments.length()),recover(true,true,true),conflict,inert}}
                                                                                                                                               
                                                                                                   
                                                                                                                                                                                              
                                                                         
                                                                 
                                                                                            
                                                               
                                                                                                        
                                                                                                         
                                                                                        
                                                                                                  
                                                                                      
                                                                                           
                                                                                                                               
                                                                                              
                                                                                                                                  
                                                                                                                                                              
                                                                                                                             
                                                                                                                   
                                                                                                      
                                                                                                    
                                                                                                            
                                                                                                                    
                                                                                                                                
                                                                                                                                                     
                                                                                                                                                                       
                                                                                                                          
                                                                                                                        
                                                                                                                
                                                                                                         
                                                                                                                                       
                                                                                                                                                                                
                                                                                                                                                                        
                                                                                                                                                                                  
                                                                                                                                                  
                                                                                                                                                                                     
  action unsafeNegative=all {X::timeout,e'=e.with("sealed",true).with("decisions",List(current(1)))}
  action unsafeTerminal=all {X::timeout,e'=e.with("decisions",List(current(2)))}
  action unsafeRefund=all {X::timeout,e'=e.with("released",3)}
  action unsafeSource(d)=all {X::timeout,e'=e.with("source",e.source.append({decision:d,worker:0,epoch:e.epoch}))}
  action unsafeUsage=all {X::timeout,e'=e.with("usage",0)}
  action unsafePay=all {X::timeout,e'=e.with("payments",e.payments.append({decision:executed,amount:0,released:3,worker:0,epoch:e.epoch})).with("released",3)}
                                                                                                        
                                                                                                     
                                                                                                                           
                                                                                                
                                                                                                                    
                                                                                                                                                       
                                                                                                     
                                                                                           
                                                                                                               
                                                                                               
}

module LlmExecutorOffer {
  type Image={spent:Set[int],exposure:int,version:int,root:int,profile:int,budget:int,history:int}
  type Request={id:int,nonce:int,amount:int,parent:int,epoch:int}
  type Result={request:Request,position:int,before:Image,after:Image}
  type Projection={position:int,body:Image}
  type Application={result:Result,before:Projection,worker:int,epoch:int}
  type Operation={key:int,slot:int,source:int,nonce:int,payload:int,route:int,profile:int,lo:int,hi:int}
  type Permit={operation:Operation,position:int,body:Image,epoch:int,policy:int,queueRevision:int}
  type Admission={permit:Permit,position:int,body:Image,epoch:int,policy:int,revision:int,joined:bool,beforeCalls:int,afterCalls:int}
  type Ticket={view:Permit,rangeEpoch:int,revision:int,activation:int}
  type Offer={ticket:Ticket,actual:Permit,rangeEpoch:int,revision:int,activation:int,worker:int,owner:int,laneOwner:int,allowed:bool}
  type Receipt={call:Ticket,bytes:int,full:bool}
  type State={authority:Image,log:List[Result],pending:Set[Request],sourceStore:Projection,accountStore:Projection,
    epoch:int,qualified:bool,open:bool,observed:Set[int],applications:List[Application],activations:List[bool],queued:Set[int],calls:int,everExposure:int,denied:bool,policyVersion:int,queueRevision:int,permits:Set[Permit],entries:Set[Operation],admissions:List[Admission],offers:Set[int],sourceCalls:int,dequeued:bool,laneOwner:int,rangeEpoch:int,revision:int,fenced:bool,rangeAllowed:bool,activation:int,seen:int,jobs:Set[int],tickets:Set[Ticket],burns:Set[Ticket],submitted:bool,laneCalls:int,unknown:bool,full:bool,executions:List[Offer],receipts:List[Receipt],executionQualified:bool}
  var s:State
  pure val genesis={spent:Set(),exposure:0,version:0,root:10,profile:30,budget:5,history:9}
  pure val zero={position:0,body:genesis}
  pure val r0={id:1,nonce:11,amount:3,parent:0,epoch:0}
  pure val r1={id:2,nonce:12,amount:2,parent:1,epoch:0}
  pure val i1=genesis.with("spent",Set(11)).with("exposure",3).with("version",1)
  pure val i2=i1.with("spent",Set(11,12)).with("exposure",5).with("version",2)
  pure val d0={request:r0,position:1,before:genesis,after:i1}
  pure val d1={request:r1,position:2,before:i1,after:i2}
  pure val initial={authority:genesis,log:List(),pending:Set(),sourceStore:zero,accountStore:zero,epoch:0,qualified:true,open:true,
    observed:Set(),applications:List(),activations:List(),queued:Set(),calls:0,everExposure:0,denied:false,policyVersion:0,queueRevision:0,permits:Set(),entries:Set(),admissions:List(),offers:Set(),sourceCalls:0,dequeued:false,laneOwner:0,rangeEpoch:0,revision:0,fenced:false,rangeAllowed:true,activation:-1,seen:-1,jobs:Set(),tickets:Set(),burns:Set(),submitted:false,laneCalls:0,unknown:false,full:false,executions:List(),receipts:List(),executionQualified:true}
  pure def validPrefix(log,p)=(p.position==0 and p.body==genesis) or
    log.indices().exists(i=>log.nth(i).position==p.position and log.nth(i).after==p.body)
  def joined=s.sourceStore.position==s.log.length() and s.accountStore.position==s.log.length() and
    s.sourceStore.body==s.authority and s.accountStore.body==s.authority
  def applyGate(p,d,worker)=s.qualified and worker==s.epoch and p.position<s.log.length() and s.log.nth(p.position)==d and
    d.position==p.position+1 and p.body==d.before
  action init=s'=initial
  action stage(r,worker)=all {worker==s.epoch,s.qualified,s.pending.forall(old=>old.id!=r.id or old==r),s'=s.with("pending",s.pending.union(Set(r)))}
  action commit(r,policy)=all {s.open,s.qualified,s.pending.contains(r),r.epoch==s.epoch,r.parent==s.log.length(),
    s.log.indices().forall(i=>s.log.nth(i).request.id!=r.id),not(s.authority.spent.contains(r.nonce)),policy,not(s.denied),
    Set(11,12).contains(r.nonce),r.amount>=0,s.authority.exposure+r.amount<=5,
    val after=s.authority.with("spent",s.authority.spent.union(Set(r.nonce))).with("exposure",s.authority.exposure+r.amount).with("version",s.authority.version+1)
    s'=s.with("authority",after).with("everExposure",after.exposure)
      .with("log",s.log.append({request:r,position:s.log.length()+1,before:s.authority,after:after}))}
  action applySource(d,worker)=all {applyGate(s.sourceStore,d,worker),s'=s.with("sourceStore",{position:d.position,body:d.after})
    .with("applications",s.applications.append({result:d,before:s.sourceStore,worker:worker,epoch:s.epoch}))}
  action applyAccount(d,worker)=all {applyGate(s.accountStore,d,worker),s'=s.with("accountStore",{position:d.position,body:d.after})
    .with("applications",s.applications.append({result:d,before:s.accountStore,worker:worker,epoch:s.epoch}))}
  action query(r)=all {s.qualified,s.log.indices().exists(i=>s.log.nth(i).request==r),s'=s.with("observed",s.observed.union(Set(r.id)))}
  action loseReply=s'=s.with("observed",Set())
  action restart=s'=s.with("executionQualified",false).with("epoch",s.epoch+1).with("qualified",false).with("open",false)
  action recover(exactPrefix)=all {not(s.qualified),not(s.open),exactPrefix,s'=s.with("qualified",true).with("open",false)}
  action restoreSource(p,worker)=all {s.qualified,not(s.open),worker==s.epoch,validPrefix(s.log,p),s'=s.with("sourceStore",p)}
  action restoreAccount(p,worker)=all {s.qualified,not(s.open),worker==s.epoch,validPrefix(s.log,p),s'=s.with("accountStore",p)}
  action activate=all {s.qualified,joined,s'=s.with("open",true).with("activations",s.activations.append(joined))}
  action denyHistory=s'=s.with("denied",true).with("policyVersion",s.policyVersion+1)
  val logBound=s.log.indices().forall(i=>{val d=s.log.nth(i)
    d.position==i+1 and d.before==(if (i==0) genesis else s.log.nth(i-1).after) and
    d.after==d.before.with("spent",d.before.spent.union(Set(d.request.nonce))).with("exposure",d.before.exposure+d.request.amount).with("version",d.before.version+1) and
    not(d.before.spent.contains(d.request.nonce)) and s.pending.contains(d.request)}) and
    s.authority==(if (s.log.length()==0) genesis else s.log.nth(s.log.length()-1).after)
  val projections=validPrefix(s.log,s.sourceStore) and validPrefix(s.log,s.accountStore)
  val applications=s.applications.indices().forall(i=>{val a=s.applications.nth(i)
    a.worker==a.epoch and a.before.body==a.result.before and a.result.position==a.before.position+1})
  val accounting=s.authority.exposure==s.everExposure and s.authority.exposure<=5
  val projectionSafety=logBound and projections and applications and accounting and s.activations.indices().forall(i=>s.activations.nth(i))
  action committed=init.then(stage(r0,0)).then(commit(r0,true))
  action sourceOnly=committed.then(applySource(d0,0))
  action complete=sourceOnly.then(applyAccount(d0,0))
  action pair=committed.then(stage(r1,0)).then(commit(r1,true))
  action restarted=sourceOnly.then(restart)
  pure val op0={key:1,slot:11,source:1,nonce:11,payload:30,route:100,profile:30,lo:0,hi:4}
  pure val op1={key:2,slot:12,source:2,nonce:12,payload:30,route:100,profile:30,lo:0,hi:4}
  pure val p0={operation:op0,position:1,body:i1,epoch:0,policy:0,queueRevision:0}
  pure val p1={operation:op1,position:2,body:i2,epoch:0,policy:0,queueRevision:0}
  def authentic(op)=s.log.indices().exists(i=>{val r=s.log.nth(i).request
    r.id==op.source and r.nonce==op.nonce and op.slot==r.nonce}) and op.payload==30 and op.route==100 and op.profile==30 and op.lo==0 and op.hi==4
  def imagePermit(op)={operation:op,position:s.log.length(),body:s.authority,epoch:s.epoch,policy:s.policyVersion,queueRevision:s.queueRevision}
  def gate(p)=s.permits.contains(p) and joined and s.open and s.qualified and p.position==s.log.length() and p.body==s.authority and
    p.epoch==s.epoch and p.policy==s.policyVersion and p.queueRevision==s.queueRevision
  def admission(p,afterCalls)={permit:p,position:s.log.length(),body:s.authority,epoch:s.epoch,policy:s.policyVersion,
    revision:s.queueRevision,joined:joined,beforeCalls:s.calls,afterCalls:afterCalls}
  action resolve(op)=all {joined,s.open,s.qualified,authentic(op),s'=s.with("permits",s.permits.union(Set(imagePermit(op))))}
  action enqueue(p,worker,policy,durable)=all {gate(p),worker==s.epoch,policy,not(s.denied),durable,authentic(p.operation),
    s.entries.forall(old=>old.key!=p.operation.key and old.slot!=p.operation.slot),
    s'=s.with("entries",s.entries.union(Set(p.operation))).with("queued",s.queued.union(Set(p.operation.key)))
      .with("queueRevision",s.queueRevision+1).with("admissions",s.admissions.append(admission(p,s.calls)))}
  action queryQueue(op)=all {s.qualified,s.entries.contains(op),s'=s.with("observed",s.observed.union(Set(op.key)))}
  val admissionCurrent=s.admissions.indices().forall(i=>{val a=s.admissions.nth(i) val p=a.permit
    a.joined and p.position==a.position and p.body==a.body and p.epoch==a.epoch and p.policy==a.policy and p.queueRevision==a.revision and a.beforeCalls==a.afterCalls})
  val slotUnique=s.admissions.indices().forall(i=>s.admissions.indices().forall(j=>i==j or s.admissions.nth(i).permit.operation.slot!=s.admissions.nth(j).permit.operation.slot))
  val immutableEntries=s.admissions.indices().forall(i=>s.entries.contains(s.admissions.nth(i).permit.operation))
  val boundEntries=s.entries.forall(op=>authentic(op))
  val sendOnce=s.calls==s.offers.size() and s.offers.forall(slot=>s.entries.exists(op=>op.slot==slot))
  val noCommitSend=s.sourceCalls==0
  val queueSafety=projectionSafety and admissionCurrent and slotUnique and immutableEntries and boundEntries and sendOnce and noCommitSend
  action resolved=complete.then(resolve(op0))
  action enqueued=resolved.then(enqueue(p0,0,true,true))
  action newCommit=resolved.then(stage(r1,0)).then(commit(r1,true))
  action newJoined=newCommit.then(applySource(d1,0)).then(applyAccount(d1,0))
  action newOwner=resolved.then(restart).then(recover(true)).then(activate)
  def registered=s.entries.contains(op0)
  action recoverExecution(exact)=all {not(s.executionQualified),s.qualified,exact,s'=s.with("executionQualified",true)}
  action dequeue(op,worker)=all {op==op0,registered,not(s.dequeued),s.qualified,worker==s.epoch,
    s'=s.with("dequeued",true)}
  action fenceLane=all {registered,s'=s.with("rangeEpoch",s.rangeEpoch+1).with("revision",s.revision+1).with("fenced",true).with("activation",-1).with("seen",-1)}
  action alignOwner(worker)=all {registered,s.qualified,s.executionQualified,worker==s.epoch,s.laneOwner!=s.epoch,
    s'=s.with("laneOwner",s.epoch).with("rangeEpoch",s.rangeEpoch+1).with("revision",s.revision+1).with("fenced",true).with("activation",-1).with("seen",-1)}
  action certify(exact)=all {s.fenced,exact,s'=s.with("seen",s.revision)}
  action prepareRange=all {s.fenced,s.seen==s.revision,s.laneCalls==0,s'=s.with("jobs",s.jobs.union(Set(s.revision)))}
  action activateRange(policy)=all {s.fenced,s.jobs.contains(s.revision),s.laneCalls==0,s.rangeAllowed,policy,
    s'=s.with("revision",s.revision+1).with("activation",s.revision+1).with("fenced",false).with("seen",-1)}
  def currentTicket={view:imagePermit(op0),rangeEpoch:s.rangeEpoch,revision:s.revision,activation:s.activation}
  def executionGate(t,worker)=registered and s.dequeued and s.qualified and s.open and joined and s.tickets.contains(t) and
    s.executionQualified and t==currentTicket and worker==s.epoch and s.laneOwner==s.epoch and s.activation>=0
  action observeOffer(worker)=all {registered,s.dequeued,s.qualified,s.executionQualified,s.open,joined,worker==s.epoch,s.laneOwner==s.epoch,s.activation>=0,
    s'=s.with("tickets",s.tickets.union(Set(currentTicket)))}
  action burn(t,worker,policy,durable)=all {executionGate(t,worker),policy,not(s.denied),s.burns.size()==0,s.laneCalls==0,durable,
    s'=s.with("burns",Set(t))}
  def offerRecord(t,worker)={ticket:t,actual:imagePermit(op0),rangeEpoch:s.rangeEpoch,revision:s.revision,activation:s.activation,
    worker:worker,owner:s.epoch,laneOwner:s.laneOwner,allowed:not(s.denied)}
  action submit(t,worker,policy,durable)=all {executionGate(t,worker),policy,not(s.denied),s.burns==Set(t),not(s.submitted),
    not(s.fenced),s.rangeAllowed,s.laneCalls==0,t.activation==s.activation,durable,
    s'=s.with("submitted",true).with("laneCalls",1).with("unknown",true).with("revision",s.revision+1).with("activation",-1)
      .with("executions",s.executions.append(offerRecord(t,worker))).with("calls",s.calls+1).with("offers",s.offers.union(Set(op0.slot)))}
  action partial(t,bytes)=all {s.executions.indices().exists(i=>s.executions.nth(i).ticket==t),bytes>0,bytes<4,
    s'=s.with("receipts",s.receipts.append({call:t,bytes:bytes,full:false}))}
  action fullReceipt(t,bytes,authentic)=all {s.executions.indices().exists(i=>s.executions.nth(i).ticket==t),bytes==4,authentic,
    s'=s.with("unknown",false).with("full",true).with("receipts",s.receipts.append({call:t,bytes:bytes,full:true}))}
  action timeout=s'=s
  action allowHistory=s'=s.with("denied",false).with("policyVersion",s.policyVersion+1)
  val offersCurrent=s.executions.indices().forall(i=>{val a=s.executions.nth(i) val t=a.ticket
    t.view==a.actual and t.rangeEpoch==a.rangeEpoch and t.revision==a.revision and t.activation==a.activation and
    a.worker==a.owner and a.laneOwner==a.owner and a.allowed and t.view.operation==op0})
  val once=s.laneCalls<=1 and s.laneCalls==s.executions.length() and (s.submitted iff s.laneCalls==1)
  val held=(s.unknown implies s.submitted and s.laneCalls==1 and not(s.full) and s.authority.exposure>=3) and
    (s.burns.size()>0 implies s.authority.exposure>=3)
  val receiptBound=s.receipts.indices().forall(i=>{val r=s.receipts.nth(i)
    (r.full implies r.bytes==4) and s.executions.indices().exists(j=>s.executions.nth(j).ticket==r.call)})
  val burnRetained=s.executions.indices().forall(i=>s.burns.contains(s.executions.nth(i).ticket)) and s.burns.size()<=1
  val safety=queueSafety and offersCurrent and once and held and receiptBound and burnRetained
  action dequeued=enqueued.then(dequeue(op0,0))
  action rangeReady=dequeued.then(fenceLane).then(certify(true)).then(prepareRange).then(activateRange(true))
  action observed=rangeReady.then(observeOffer(0))
  pure val t0={view:p0.with("queueRevision",1),rangeEpoch:1,revision:2,activation:2}
  action burned=observed.then(burn(t0,0,true,true))
  action offered=burned.then(submit(t0,0,true,true))
  action partialWrite=offered.then(partial(t0,2))
  action switched=observed.then(restart).then(recover(true)).then(activate)
  action realigned=switched.then(recoverExecution(true)).then(alignOwner(1)).then(certify(true)).then(prepareRange).then(activateRange(true)).then(observeOffer(1))
  pure val t1={view:p0.with("queueRevision",1).with("epoch",1),rangeEpoch:2,revision:4,activation:4}
  action step={nondet t=s.tickets.union(Set(t0)).oneOf() nondet r=Set(r0,r1).oneOf()
    nondet d=s.log.indices().map(i=>s.log.nth(i)).union(Set(d0)).oneOf()
    any {recoverExecution(true),stage(r,s.epoch),commit(r,true),applySource(d,s.epoch),applyAccount(d,s.epoch),resolve(op0),enqueue(p0,s.epoch,true,true),queryQueue(op0),
      dequeue(op0,s.epoch),fenceLane,alignOwner(s.epoch),certify(true),prepareRange,activateRange(true),observeOffer(s.epoch),burn(t,s.epoch,true,true),submit(t,s.epoch,true,true),
      partial(t,2),fullReceipt(t,4,true),timeout,denyHistory,allowHistory,restart,recover(true),activate}}
                                                                                          
                                                                             
                                                                                         
                                                                                                                         
                                                                                 
                                                                                 
                                                                                 
                                                                                                
                                                                                                
                                                                                   
                                                                            
                                                                                             
                                                                                                                   
                                                                                                                     
                                                                                                                              
                                                                                                                                                  
                                                     
                                                                                       
                                                                                  
                                                                                                
                                                                                  
                                                                                                                                                      
                                                                                                                    
                                                                                                                                                                                                                       
                                                            
                                                                                           
                                                                                                                 
                                                                                                                                            
                                                                                                  
                                                                                         
                                                                                                                           
                                                                                                
                                                                                                                         
                                                                                                                                               
                                                                                                                                              
                                                                                                                       
                                                                                                                  
                                                                                                                                    
  action unsafeSubmit(t,worker)=s'=s.with("submitted",true).with("laneCalls",s.laneCalls+1).with("unknown",true)
    .with("executions",s.executions.append(offerRecord(t,worker))).with("calls",s.calls+1).with("offers",s.offers.union(Set(op0.slot)))
  action unsafeReset=s'=s.with("submitted",false).with("laneCalls",0).with("unknown",false)
  action unsafeRefund=s'=s.with("authority",s.authority.with("exposure",0))
  action unsafePartialFull=s'=s.with("full",true).with("unknown",false).with("receipts",s.receipts.append({call:t0,bytes:2,full:true}))
  action unsafeDequeueInvoke=s'=s.with("dequeued",true).with("laneCalls",1)
  action unsafeLaneOffer=s'=s.with("submitted",true).with("laneCalls",1).with("unknown",true)
    .with("executions",s.executions.append(offerRecord(currentTicket,1))).with("calls",1).with("offers",Set(11)).with("burns",Set(currentTicket))
                                                                                                                        
                                                                                                                                                    
                                                                                                       
                                                                                                                                           
                                                        
                                                                                                    
                                                                                                            
                                                                                               
                                                                                                               
                                                                                                                                                              
                                                                                                
}

module LlmIncarnationIssuance {
  import LlmCallerCustody as C
  import LlmCustodyPublication.pub
  import LlmSourceCustody.custody
  import LlmAdmissionFloor.f
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
                                                                                                                                            
                                                                                    
                                                                                             
                                                                               
                                                                                                                                                                
                                                                                                                                                
                                                                                                                                                 
                                                                                                                                                                                                              
                                                                                   
                                                                                   
                                                                             
                                                                            
                                                                                                               
                                                                                                       
                                                                                                                     
                                                                                                   
                                                                                                                     
                                                                                                                       
                                                                                                                                                         
                                                                                                               
                                                                                 
                                                                                                                                                                    
                                                                                                          
                                                                                                                            
                                                                                                                                                                                             
  // Faults below are outside the guarded transition relation.
  action unsafeActivate(ch,t)=all {not(canActivate(ch,t)),C::handoff(9,true,true,t.target.inc,t.target.key,t.target.holder,1,false),registry'=registry.with("outcomes",registry.outcomes.union(Set(t.id))).with("checked",false)}
  action replaceTicket=all {idle,registry'=registry.with("tickets",registry.tickets.replaceAt(0,ticket.with("target",target.with("key",100)))).with("checked",false)}
  action eraseIssue=all {idle,registry'=registry.with("issued",Set()).with("launches",Set()).with("reserved",Set(0))}
  action eraseOutcome=all {idle,registry'=registry.with("outcomes",Set()).with("checked",false)}
                                                                                                                                                         
                                                                                                                                                                                                            
                                                                                                                                                                    
                                                                                                                                             
                                                                                                                                                                 
                                                                                                                                                                         
}

module LlmSourceCustody {
  import LlmSourceJoin as J
  import LlmAdmissionFloor.Proposal
  import LlmAdmissionFloor.Record
  import LlmAdmissionFloor.f
  import LlmAdmissionFloor.pAppend
  import LlmAdmissionFloor.pEarlyCut
  import LlmAdmissionFloor.seed
  type Custody={phase:int,fence:int,holder:int,original:Proposal,attempt:Proposal,haveIntent:bool,outcome:Record,haveOutcome:bool,resolved:bool,lastChecked:bool}
  var custody:Custody
  pure val initial={phase:0,fence:0,holder:0,original:pAppend,attempt:pAppend,haveIntent:false,outcome:seed,haveOutcome:false,resolved:true,lastChecked:true}
  def current(holder,fence)=holder==custody.holder and fence==custody.fence
  val safety=J::safety and custody.lastChecked and (custody.phase==0 or custody.haveIntent) and
    (not(custody.haveOutcome) or (f.log.indices().exists(i=>f.log.nth(i)==custody.outcome) and custody.outcome.proposal.id==custody.original.id)) and
    (custody.phase!=4 or custody.haveOutcome)
  action idle=all {J::idle,J::j'=J::j}
  action init=all {J::appendInit,custody'=initial}
  action begin(p)=all {custody.phase==0,idle,custody'=custody.with("phase",1).with("original",p).with("attempt",p).with("haveIntent",true)}
  action validate=all {custody.phase==1,custody.resolved,J::validate(custody.attempt,true),custody'=custody}
  action propose=all {custody.phase==1,J::propose(custody.attempt),custody'=custody}
  action arm(holder,fence,durable)=all {custody.phase==1,custody.resolved,current(holder,fence),durable,J::joined(custody.attempt),J::j.allows,idle,custody'=custody.with("phase",2).with("resolved",false)}
  action publish(holder,fence)=all {custody.phase==2,current(holder,fence),not(custody.haveOutcome),J::publishAppend(custody.attempt),custody'=custody.with("phase",3).with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("resolved",false)}
  action transfer(holder,durable)=all {custody.phase>0,custody.phase<4,durable,J::restart,custody'=custody.with("fence",custody.fence+1).with("holder",holder).with("phase",if(custody.haveOutcome) 3 else 1).with("resolved",false)}
  action resolve(holder,fence,authentic)=all {current(holder,fence),authentic,idle,custody'=custody.with("resolved",true)}
  action restart=all {J::restart,custody'=custody.with("resolved",false)}
  action close(holder,fence)=all {custody.phase==3,custody.haveOutcome,custody.resolved,current(holder,fence),idle,custody'=custody.with("phase",4)}
  action sourceChange=all {custody.phase!=2,J::sourceChange(true),custody'=custody}
  action armed=init.then(begin(pAppend)).then(propose).then(validate).then(arm(0,0,true))
  action handed=armed.then(transfer(1,true))
  action recovered=handed.then(resolve(1,1,true)).then(validate).then(arm(1,1,true))
  action committed=armed.then(publish(0,0))
  action transferredCommit=committed.then(transfer(1,true))
  action resolvedCommit=transferredCommit.then(resolve(1,1,true))
  action restarted=armed.then(restart)
  action closed=resolvedCommit.then(close(1,1))
  action step=any {begin(pAppend),propose,validate,arm(custody.holder,custody.fence,true),publish(custody.holder,custody.fence),transfer(1-custody.holder,true),resolve(custody.holder,custody.fence,true),restart,sourceChange,close(custody.holder,custody.fence)}
                                                        
                                                                 
                                                                              
                                                                     
                                                                       
                                                                          
                                                                                                                   
                                                                       
                                                                    
                                                              
                                                                                                             
                                                                      
                                                                                 
                                                                                
                                                                       
                                                                                                                           
  action unsafeOldPublish=all {J::publishAppend(custody.attempt),custody'=custody.with("phase",3).with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("lastChecked",current(0,0))}
  action unsafeClose=all {idle,custody'=custody.with("phase",4).with("lastChecked",custody.phase==3 and custody.haveOutcome and custody.resolved)}
  action unsafeDrop=all {J::restart,custody'=custody.with("haveIntent",false).with("haveOutcome",false)}
  action unsafeWrongResult=all {idle,custody'=custody.with("outcome",{proposal:pEarlyCut}).with("haveOutcome",true)}
  action unsafeSourceChange=all {J::sourceChange(true),custody'=custody.with("lastChecked",custody.phase!=2)}
  action unsafeRestoreFence=all {idle,custody'=custody.with("fence",0).with("lastChecked",false)}
                                                                                             
                                                                                           
                                                                                              
                                                                                        
                                                                                             
                                                                                               
                                                                                                  
}

module LlmSourceJoin {
  import LlmAdmissionFloor as F
  import LlmAccountCommit as A
  type Ticket={proposal:F::Proposal,operation:int,intent:int,floor:F::Receipt,account:A::Image,journal:List[A::Record],worker:int,sourceGeneration:int,qualified:bool,sourceRevision:int}
  type Join={revision:int,allows:bool,ticket:Ticket,haveTicket:bool,lastChecked:bool,attempted:Ticket}
  var j:Join
  pure val empty={proposal:F::pAppend,operation:0,intent:0,floor:{revision:1,record:F::seed},account:A::after0,journal:List(),worker:0,sourceGeneration:0,qualified:true,sourceRevision:0}
  pure val initial={revision:0,allows:true,ticket:empty,haveTicket:false,lastChecked:true,attempted:empty}
  def current(p)={proposal:p,operation:p.id,intent:p.intent,floor:F::current,account:A::a.anchor,journal:A::a.journal,worker:A::a.epoch,sourceGeneration:A::a.sourceGeneration,qualified:A::a.qualified,sourceRevision:j.revision}
  def joined(p)=j.haveTicket and j.ticket==current(p)
  val safety=j.lastChecked and F::safety
  action idle=all {F::idle,F::f'=F::f}
  action init=all {F::sealedRecovered,j'=initial}
  action appendInit=all {F::qualifiedInit,j'=initial}
  action validate(p,authentic)=all {authentic,F::qualified,j.allows,idle,j'=j.with("ticket",current(p)).with("haveTicket",true)}
  action sourceChange(allow)=all {idle,j'=j.with("revision",j.revision+1).with("allows",allow)}
  action publishCut(p)=all {joined(p),j.allows,F::commitCut(p,true,true,true),j'=j.with("haveTicket",false)}
  action publishAppend(p)=all {joined(p),j.allows,F::commitAppend(p,true,true,true),j'=j.with("haveTicket",false)}
  action publishFence(p)=all {joined(p),j.allows,F::commitFence(p,true,true,true),j'=j.with("haveTicket",false)}
  action propose(p)=all {F::propose(p,true),j'=j}
  action financialCommit=all {F::financialCommit,j'=j}
  action query=all {F::query(A::a.epoch,true),j'=j}
  action copies=all {F::installCopies(true),j'=j}
  action project=all {F::project(A::a.epoch,true),j'=j}
  action resolve(id)=all {F::resolve(id),j'=j}
  action loseReply=all {F::loseReply,j'=j}
  action restart=all {idle,j'=j.with("haveTicket",false)}
  action restore=all {F::restore(F::i0,Set(),Set()),j'=j}
  action staged=init.then(propose(F::pFence)).then(validate(F::pFence,true))
  action accountChanged=staged.then(financialCommit)
  action sourceChanged=staged.then(sourceChange(false))
  action sourceReallowed=sourceChanged.then(sourceChange(true))
  action fenced=staged.then(publishFence(F::pFence))
  action appendStaged=appendInit.then(propose(F::pAppend)).then(validate(F::pAppend,true))
  action appendPublished=appendStaged.then(publishAppend(F::pAppend))
  action earlyCutStaged=appendInit.then(propose(F::pEarlyCut)).then(validate(F::pEarlyCut,true))
  action step={nondet p=Set(F::pAppend,F::pCut,F::pEarlyCut,F::pFence).oneOf()
    any {validate(p,true),sourceChange(true),sourceChange(false),publishCut(p),publishAppend(p),publishFence(p),propose(p),financialCommit,
      query,copies,project,resolve(p.id),loseReply,restart,restore}}
                                                                                       
                                                                                                                                                                         
                                                                                          
                                                                                                                                                                  
                                                                                                                                     
                                                                                       
                                                                                                   
                                                                                                                                           
                                                                                            
                                                                                       
                                                                                                    
                                                                                                                                                                          
                                                                                                                                                                                                        
                                                                                     
                                                                                                                                                                                              
                                                                                                   
                                                                                                                                                     
                                                                                                                                          
                                                                                                                                  
                                                                                                                                                 
  action unsafeFence(p)=all {F::commitFence(p,true,true,true),j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
  action unsafeCut(p)=all {F::commitCut(p,true,true,true),j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
  action unsafeDescriptor(p)=all {idle,j'=j.with("lastChecked",joined(p) and j.allows).with("attempted",current(p))}
                                                                                                                   
                                                                                                              
                                                                                                             
                                                                                                                                             
                                                                                                                                                    
                                                                                                                
                                                                                                              
}

module LlmWalActivation {
  import LlmAccountCommit as A
  type Receipt={head:A::Image,journal:List[A::Record],epoch:int,sourceGeneration:int}
  type Wal={records:List[A::Record],candidates:Set[A::Record],receipt:Receipt,haveReceipt:bool,active:bool,sourceQualified:bool}
  var w:Wal
  pure val zero={head:A::genesis,journal:List(),epoch:0,sourceGeneration:0}
  pure val initial={records:List(),candidates:Set(),receipt:zero,haveReceipt:true,active:true,sourceQualified:true}
  pure def frame(p)={proposal:p,after:A::post(p.before,p.transaction),epoch:p.worker}
  pure val f0=frame(A::p0)
  def view={head:A::a.anchor,journal:A::a.journal,epoch:A::a.epoch,sourceGeneration:A::a.sourceGeneration}
  def current=w.haveReceipt and w.receipt==view
  def complete=w.records.length()>=A::a.journal.length() and A::a.journal.indices().forall(i=>w.records.nth(i)==A::a.journal.nth(i))
  action init=all {A::init,w'=initial}
  action prepared=all {A::prepared,w'=initial}
  action flush(p,durable)=all {A::a.prepared.contains(p),A::gate(p),w.records==A::a.journal,durable,A::loseReply,
    w'=w.with("records",w.records.append(frame(p)))}
  action submit(p,durable)=all {w.records.indices().exists(i=>w.records.nth(i)==frame(p)),A::a.prepared.contains(p),A::gate(p),durable,A::loseReply,
    w'=w.with("candidates",w.candidates.union(Set(frame(p)))).with("active",false)}
  action anchor(p,policy,durable)=all {w.candidates.contains(frame(p)),A::commit(p,policy,durable),w'=w.with("active",false)}
  action rotate=all {A::rotate,w'=w.with("active",false)}
  action conflict=all {A::conflictUsage,w'=w.with("active",false).with("sourceQualified",false)}
  action restoreWal(records)=all {A::loseReply,w'=w.with("records",records).with("active",false)}
  action repair(authentic)=all {authentic,A::loseReply,w'=w.with("records",A::a.journal).with("active",false)}
  action observe(authentic)=all {authentic,A::loseReply,w'=w.with("receipt",view).with("haveReceipt",true)}
  action install=all {current,complete,not(A::a.qualified),A::restore(A::a.anchor),w'=w.with("active",false)}
  action restoreImage(image)=all {A::restore(image),w'=w.with("active",false)}
  action activate(authentic)=all {current,complete,authentic,w.sourceQualified,A::a.local==A::a.anchor,
    if (A::a.qualified) A::loseReply else A::recover(true),w'=w.with("active",true)}
  action prepareNext(p)=all {w.active,A::prepare(p),w'=w}
  action loseReply=all {A::loseReply,w'=w.with("haveReceipt",false).with("active",false)}
  action lateFull=all {A::lateFull,w'=w}
  action flushed=prepared.then(flush(A::p0,true))
  action submitted=flushed.then(submit(A::p0,true))
  action anchored=submitted.then(anchor(A::p0,true,true))
  action replayed=anchored.then(observe(true)).then(repair(true)).then(install)
  action activated=replayed.then(activate(true))
  action truncated=anchored.then(restoreWal(List()))
  val live=w.active implies w.sourceQualified and A::a.qualified and A::a.local==A::a.anchor and current and complete
  val candidateSound=w.candidates.forall(r=>r.after==A::post(r.proposal.before,r.proposal.transaction))
  val anchoredOnly=A::a.journal.indices().forall(i=>w.candidates.contains(A::a.journal.nth(i)))
  val safety=anchoredOnly and A::safety and live and candidateSound
  action step={nondet p=A::a.prepared.union(Set(A::p0,A::p1)).oneOf()
    any {prepareNext(p),flush(p,true),submit(p,true),anchor(p,true,true),rotate,conflict,restoreWal(List()),
      repair(true),observe(true),install,restoreImage(A::genesis),restoreImage(A::a.anchor),activate(true),loseReply,lateFull}}
                                                                                                                    
                                                                                                                                                 
                                                                                
                                                                                   
                                                                                     
                                                                                         
                                                                                     
                                                                              
                                                                                                                                                                                      
                                                                                                           
                                                                                                  
                                                                                                                                                   
                                                                         
                                                                                                                                                                                 
                                                                                                       
                                                                                                                                                                        
                                                                                                                                  
                                                                                                                                                 
                                             
                                                                                   
                                                                                        
                                                                                                                 
                                                                                                                                                
                                                                                           
                                                                                                                                                    
                                                                                               
                                                                                                                                                                      
                                                                                                                                        
                                                                                                                            
                                                                                                                 
                                                                                                                                                      
                                                                                                                                 
                                                                                                                        
                                                                                                                                     
                                                                                               
                                                                                                                     
                                                       
  action unsafeCandidateConfirmation=all {A::loseReply,
    w'=w.with("receipt",{head:f0.after,journal:List(f0),epoch:A::a.epoch,sourceGeneration:A::a.sourceGeneration})
      .with("haveReceipt",true).with("active",true)}
  action unsafeRequalifyActivate=all {A::unsafeRecover,w'=w.with("active",true)}
  action unsafeActivate=all {A::loseReply,w'=w.with("active",true)}
  action unsafeWalCredit=all {A::unsafeApply(A::p0),w'=w}
  action unsafeDropAnchor=all {A::unsafeRollback,w'=w}
  action unsafeRetry=all {A::unsafeApply(A::p0),w'=w.with("active",false)}
                                                                                     
                                                                                                                 
                                                                                                                 
                                                                                                                                   
                                                                                                                                      
                                                                                                            
                                                                                                       
                                                                                                                                               
                                           
                                                                                                            
                                                                                                                        
}

module LlmBeneficiaryRegistration {
  import LlmBootstrapInvitation as P
  import LlmIncarnationIssuance as I
  import LlmCallerCustody.auth
  import LlmCustodyPublication.pub
  import LlmAccountCommit.a
  import LlmAdmissionFloor.f
  import LlmSourceCustody.custody
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
  action read:bool=all {invariant,idle,enrollment'=enrollment.with("seen",enrollment.revision)}
  def canBind(ch:int,t:I::Ticket,entitlement:bool,possession:bool):bool={val r=enrollment.rootRows.nth(t.id)
    enrollment.roots.contains(t.id) and not(enrollment.bindings.contains(t.id)) and erase(t)==r.template and r.epoch==enrollment.epoch and credential(ch,r,t,entitlement,possession) and blueprint(t) and enrollment.seen==enrollment.revision and invariant}
  action bindKey(ch:int,t:I::Ticket,entitlement:bool,possession:bool,deliver:bool):bool=all {canBind(ch,t,entitlement,possession),idle,enrollment'=enrollment.with("bindings",enrollment.bindings.union(Set(t.id))).with("claims",enrollment.claims.replaceAt(t.id,{root:enrollment.rootRows.nth(t.id),ticket:t,peer:peer(ch)})).with("revision",enrollment.revision+1).with("seen",-1).with("reply",deliver)}
  def canPublish(t:I::Ticket,approved:bool):bool=enrollment.bindings.contains(t.id) and enrollment.claims.nth(t.id).ticket==t and enrollment.claims.nth(t.id).root==enrollment.rootRows.nth(t.id) and enrollment.rootRows.nth(t.id).epoch==enrollment.epoch and not(enrollment.published.contains(t.id)) and blueprint(t) and enrollment.seen==enrollment.revision and approved and invariant
  action publish(t:I::Ticket,approved:bool,deliver:bool):bool=all {canPublish(t,approved),P::register(t,true),enrollment'=enrollment.with("published",enrollment.published.union(Set(t.id))).with("results",enrollment.results.replaceAt(t.id,t)).with("revision",enrollment.revision+1).with("seen",-1).with("reply",deliver)}
  // Coordinator recovery can read a result after a new transport session; it cannot rebind.
  action recover(ch:int,id:int,allowed:bool):bool=all {ch==9,allowed,enrollment.roots.contains(id),idle,enrollment'=enrollment.with("reply",true)}
  action crash:bool=all {P::crash,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1).with("reply",false)}
  action revoke:bool=all {P::revoke,enrollment'=enrollment.with("epoch",enrollment.epoch+1).with("revision",enrollment.revision+1).with("seen",-1)}
  action readInvitation:bool=all {invariant,P::read,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action consume:bool=all {invariant,P::consume(1,I::ticket,true,false),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action prove:bool=all {invariant,P::prove(1,I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action readCustody:bool=all {invariant,P::readCustody,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action stage:bool=all {invariant,P::stage(I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action readActivation:bool=all {invariant,P::readActivation,enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action activate:bool=all {invariant,P::activate(1,I::ticket),enrollment'=enrollment.with("revision",enrollment.revision+1).with("seen",-1)}
  action rooted:bool=boot.then(registerRoot(9,root,true,false))
  action ready:bool=rooted.then(read)
  action bound:bool=ready.then(bindKey(1,I::ticket,true,true,false))
  action published:bool=bound.then(read).then(publish(I::ticket,true,false))
  action consumed:bool=published.then(readInvitation).then(consume)
  action activated:bool=consumed.then(prove).then(readCustody).then(stage).then(readActivation).then(activate)
  action step:bool=any {registerRoot(9,root,true,false),read,bindKey(1,I::ticket,true,true,false),publish(I::ticket,true,false),recover(9,0,true),crash,revoke,readInvitation,consume,prove,readCustody,stage,readActivation,activate}


























  // Unsafe mutations below are excluded from step and expose missing native contracts.
  action unsafeBind:bool=all {idle,enrollment'=enrollment.with("bindings",Set(0)).with("claims",enrollment.claims.replaceAt(0,{root:root,ticket:I::ticket,peer:peer(0)}))}
  action replaceFirstKey:bool=all {idle,enrollment'=enrollment.with("claims",enrollment.claims.replaceAt(0,enrollment.claims.nth(0).with("ticket",I::ticket.with("target",I::target.with("key",201)))))}
  action publishWithoutOutcome:bool=all {P::register(I::ticket,true),enrollment'=enrollment}
  action outcomeWithoutPublication:bool=all {idle,enrollment'=enrollment.with("published",Set(0))}
  action eraseFirstBinding:bool=all {idle,enrollment'=enrollment.with("bindings",Set())}







}

module LlmEnrollmentCredential {
  import LlmBeneficiaryRegistration as B
  import LlmIncarnationIssuance as I
  import LlmCallerCustody.auth
  import LlmAccountCommit.a
  import LlmAdmissionFloor.f
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

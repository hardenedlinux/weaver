module LlmAdmissionFloor {
  import LlmAppendHandoff as H from "./LlmAppendHandoff"
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

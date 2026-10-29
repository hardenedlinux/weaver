module LlmCheckpointTruncation {
  import LlmWalActivation as W from "./LlmWalActivation"
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

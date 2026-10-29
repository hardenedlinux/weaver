module LlmWalActivation {
  import LlmAccountCommit as A from "./LlmAccountCommit"
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

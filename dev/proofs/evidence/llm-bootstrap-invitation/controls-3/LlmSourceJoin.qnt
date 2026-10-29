module LlmSourceJoin {
  import LlmAdmissionFloor as F from "./LlmAdmissionFloor"
  import LlmAccountCommit as A from "./LlmAccountCommit"
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

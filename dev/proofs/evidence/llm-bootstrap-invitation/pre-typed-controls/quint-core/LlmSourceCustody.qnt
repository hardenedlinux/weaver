module LlmSourceCustody {
  import LlmSourceJoin as J from "./LlmSourceJoin"
  import LlmAdmissionFloor.Proposal from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.Record from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.pAppend from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.pEarlyCut from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.seed from "./LlmAdmissionFloor"
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

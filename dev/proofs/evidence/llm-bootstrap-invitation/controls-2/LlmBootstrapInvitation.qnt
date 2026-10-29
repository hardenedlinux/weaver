module LlmBootstrapInvitation {
  import LlmIncarnationIssuance as B from "./LlmIncarnationIssuance"
  import LlmCallerCustody.auth from "./LlmCallerCustody"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  type Invitations={registered:Set[int],spent:Set[int],bindings:List[B::Ticket],results:List[B::Ticket],revision:int,seen:int,reply:bool,checked:bool}
  var invitations:Invitations
  pure val initial={registered:Set(),spent:Set(),bindings:List(B::ticket,B::ticket2),results:List(B::ticket,B::ticket2),revision:0,seen:-1,reply:false,checked:true}
  val covered=B::registry.issued.forall(id=>invitations.spent.contains(id) and invitations.results.nth(id)==B::registry.tickets.nth(id))
  val bound=invitations.spent.forall(id=>invitations.registered.contains(id) and invitations.results.nth(id)==invitations.bindings.nth(id))
  val invariant=B::invariant and invitations.checked and covered and bound and invitations.registered.forall(id=>B::assignment(invitations.bindings.nth(id)))
  action boot=all {B::boot,invitations'=initial}
  action register(t,approved)=all {Set(0,1).contains(t.id),approved,B::assignment(t),not(invitations.registered.contains(t.id)),invitations.registered.forall(id=>invitations.bindings.nth(id).launch!=t.launch),B::idle,B::registry'=B::registry,invitations'=invitations.with("registered",invitations.registered.union(Set(t.id))).with("bindings",invitations.bindings.replaceAt(t.id,t)).with("revision",invitations.revision+1).with("seen",-1)}
  action read=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("seen",invitations.revision)}
  def ready(ch,t,verified)=invitations.registered.contains(t.id) and invitations.bindings.nth(t.id)==t and not(invitations.spent.contains(t.id)) and invitations.seen==invitations.revision and B::possession(ch,t,verified)
  // One authority event consumes the invitation and commits the exact pending issuance.
  action consume(ch,t,verified,deliver)=all {ready(ch,t,verified),B::issue(9,t,true,true,false),invitations'=invitations.with("spent",invitations.spent.union(Set(t.id))).with("results",invitations.results.replaceAt(t.id,t)).with("revision",invitations.revision+1).with("seen",-1).with("reply",deliver)}
  // Recovery returns the old result; it does not create an issuance or grant freshness.
  action recover(ch,t,allowed)=all {invitations.spent.contains(t.id),invitations.results.nth(t.id)==t,allowed,B::possession(ch,t,true),B::idle,B::registry'=B::registry,invitations'=invitations.with("reply",true)}
  action prove(ch,t)=all {B::prove(ch,t,true),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action readCustody=all {B::readCustody,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action stage(t)=all {B::stage(t),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action prepare(t)=readCustody.then(stage(t))
  action readActivation=all {B::read,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action activate(ch,t)=all {B::activate(ch,t,false),invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action revoke=all {B::revoke,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1)}
  action crash=all {B::crash,invitations'=invitations.with("revision",invitations.revision+1).with("seen",-1).with("reply",false)}
  action registered=boot.then(register(B::ticket,true))
  action readyState=registered.then(read)
  action consumed=readyState.then(consume(1,B::ticket,true,false))
  action activated=consumed.then(prove(1,B::ticket)).then(prepare(B::ticket)).then(readActivation).then(activate(1,B::ticket))
  action competing=registered.then(register(B::ticket2,true)).then(read)
  action step={nondet ch=Set(0,1,4,9).oneOf()
    nondet t=Set(B::ticket,B::ticket2).oneOf()
    any {register(t,true),read,consume(ch,t,true,false),recover(ch,t,true),prove(ch,t),readCustody,stage(t),readActivation,activate(ch,t),revoke,crash}}
                                                                                                                   
                                                                                   
                                                                                                                     
                                                                                                              
                                                                                                    
                                                                                                 
                                                                                                 
  run invalidPossessionRejectedTest=readyState.then(consume(1,B::ticket,false,true).fail())
  run substitutedSessionRejectedTest=readyState.then(consume(1,B::ticket.with("session",50),true,true).fail())
  run exactBindingRequiredTest=readyState.then(consume(1,B::ticket.with("challenge",1),true,true).fail())
                                                                                                                                                                                                                          
                                                                                                                 
                                                                                                                                                                                                          
                                                                                
                                                                                     
  run concurrentReadInvalidatedTest=readyState.then(register(B::ticket2,true)).then(consume(1,B::ticket,true,true).fail())
                                                                                                             
                                                                                                                                                 
                                                                                                               
  // Deliberately unsafe mutations, excluded from step. They expose broken contracts.
  action unsafeIssue=all {B::issue(9,B::ticket,true,true,false),invitations'=invitations}
  action eraseResult=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set())}
  action consumeWithoutIssue=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("spent",Set(0)).with("results",invitations.results.replaceAt(0,B::ticket2))}
  action replaceBinding=all {B::idle,B::registry'=B::registry,invitations'=invitations.with("bindings",invitations.bindings.replaceAt(0,B::ticket2))}
                                                                                                                                                                                                
                                                                                                                                                                                   
                                                                                                                                                                         
                                                                                                                                                                     
}

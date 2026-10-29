module LlmCallerCustody {
  import LlmCustodyPublication as P from "./LlmCustodyPublication"
  import LlmSourceCustody.custody from "./LlmSourceCustody"
  import LlmSourceCustody.restart from "./LlmSourceCustody"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
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
  run unknownChannelRejectedTest=staged.then(redeliver(4,first).fail())
  run sharedWorkloadCannotUseNewGrantTest=handed.then(redeliver(0,auth.grant).fail())
  run claimedFenceCannotAuthenticateTest=recovered.then(read).then(stage(0,0,1,1)).then(publish(0,auth.grant,0,true).fail())
  run currentIncarnationCanFinishOriginalTest=recovered.then(read).then(stage(0,0,1,1)).then(publish(1,auth.grant,0,false)).expect(invariant and f.log.length()==2)
  run reconnectPreservesOriginalGrantTest=staged.then(redeliver(2,first)).expect(invariant and P::ready and auth.grant==first)
  run redeliveryCannotRefreshReadTest=committed.then(redeliver(0,first)).expect(invariant and not(P::ready) and f.log.length()==2)
  run oldGrantCannotBeRedeliveredTest=handed.then(redeliver(1,first).fail())
  run workerCannotMintRecoveryGrantTest=staged.then(stage(1,1,1,0)).then(handoff(0,true,true,1,200,1,1,true).fail())
  run recoveryAuthorizationRequiredTest=staged.then(stage(1,1,1,0)).then(handoff(9,false,true,1,200,1,1,true).fail())
  run enrollmentRequiredTest=staged.then(stage(1,1,1,0)).then(handoff(9,true,false,1,200,1,1,true).fail())
  run incarnationReuseRejectedTest=handed.then(read).then(stage(1,1,0,1)).then(handoff(9,true,true,0,100,0,1,true).fail())
  run lostHandoffReplyRetainsGrantTest=handed.then(crash).then(read).expect(invariant and auth.grant.inc==1 and auth.used.contains(0) and not(P::pub.haveReply))
  run oldWorkerAfterRestartRejectedTest=handed.then(crash).then(read).then(stage(0,2,1,1)).then(publish(0,auth.grant,0,true).fail())
  run expiryBetweenStageAndCommitRejectedTest=expired.then(publish(0,first,0,true).fail())
  run oldKeyAfterRotationRejectedTest=rotated.then(redeliver(0,auth.grant).fail())
  run oldSerialAfterRotationRejectedTest=rotated.then(redeliver(3,first).fail())
  run newKeyGetsSameScopeTest=rotated.then(redeliver(3,auth.grant)).expect(invariant and auth.grant.serial==1 and auth.grant.expires==10 and not(custody.resolved) and f.log.length()==1)
  run rotationRequiresNewKeyEnrollmentTest=staged.then(rotate(0,first,false,101,1,true).fail())
  run lateAckDoesNotRestorePublishRightTest=handed.then(ack).then(redeliver(0,auth.grant).fail())
  run originalCannotReadmitAfterLostReplyTest=restarted.then(read).then(stage(0,0,0,0)).then(publish(0,first,0,true).fail())
  // Fault-injected boundaries: these are deliberately outside the guarded relation.
  action bypassCaller(slot)=all {P::commit(slot,false),auth'=note(auth.grant).with("checked",false)}
  action splitGrant=all {P::commit(1,false),auth'=auth}
  action mintFromWorkload=all {idle,auth'=auth.with("grant",auth.grant.with("inc",0).with("key",100))}
  action renewOnRedelivery=all {idle,auth'=auth.with("grant",auth.grant.with("expires",20))}
  action forgetIncarnations=all {idle,auth'=auth.with("used",Set())}
  run sharedIdentityCallerCounterexampleTest=recovered.then(read).then(stage(0,0,1,1)).then(bypassCaller(0)).expect(not(invariant) and f.log.length()==2)
  run expiryCallerCounterexampleTest=expired.then(bypassCaller(0)).expect(not(invariant) and f.log.length()==2)
  run splitGrantCallerCounterexampleTest=staged.then(stage(1,1,1,0)).then(splitGrant).expect(not(invariant) and custody.fence==1 and auth.grant.fence==0)
  run workloadMintCallerCounterexampleTest=handed.then(mintFromWorkload).expect(not(invariant))
  run redeliveryRenewCallerCounterexampleTest=committed.then(renewOnRedelivery).expect(not(invariant) and f.log.length()==2)
  run restartReuseCallerCounterexampleTest=handed.then(forgetIncarnations).expect(not(invariant))
  run rotationOldKeyCallerCounterexampleTest=rotated.then(read).then(stage(0,2,0,0)).then(bypassCaller(0)).expect(not(invariant) and auth.grant.key==101)
}

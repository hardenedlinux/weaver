module LlmCustodyPublication {
  import LlmSourceCustody.Custody from "./LlmSourceCustody"
  import LlmSourceCustody.custody from "./LlmSourceCustody"
  import LlmSourceCustody.safety from "./LlmSourceCustody"
  import LlmSourceCustody.init from "./LlmSourceCustody"
  import LlmSourceCustody.idle from "./LlmSourceCustody"
  import LlmSourceCustody.begin from "./LlmSourceCustody"
  import LlmSourceCustody.propose from "./LlmSourceCustody"
  import LlmSourceCustody.validate from "./LlmSourceCustody"
  import LlmSourceCustody.arm from "./LlmSourceCustody"
  import LlmSourceCustody.publish from "./LlmSourceCustody"
  import LlmSourceCustody.transfer from "./LlmSourceCustody"
  import LlmSourceCustody.resolve from "./LlmSourceCustody"
  import LlmSourceCustody.restart from "./LlmSourceCustody"
  import LlmSourceCustody.close from "./LlmSourceCustody"
  import LlmSourceCustody.sourceChange from "./LlmSourceCustody"
  import LlmSourceCustody.unsafeOldPublish from "./LlmSourceCustody"
  import LlmAdmissionFloor.Proposal from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.Record from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.f from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.pAppend from "./LlmAdmissionFloor"
  import LlmAdmissionFloor.seed from "./LlmAdmissionFloor"
  type Entry={fence:int,holder:int,original:Proposal,haveIntent:bool,outcome:Record,haveOutcome:bool,floor:List[Record]}
  type Command={kind:int,holder:int,fence:int}
  type Publication={log:List[Entry],commands:List[Command],parents:List[int],staged:Set[int],copy:Entry,seen:int,qualified:bool,haveCopy:bool,reply:int,haveReply:bool,lastChecked:bool}
  var pub:Publication
  pure val emptyCommand={kind:0,holder:0,fence:0}
  pure val initialEntry={fence:0,holder:0,original:pAppend,haveIntent:false,outcome:seed,haveOutcome:false,floor:List(seed)}
  pure val initialPublication={log:List(initialEntry),commands:List(emptyCommand,emptyCommand),parents:List(0,0),staged:Set(),copy:initialEntry,seen:0,qualified:false,haveCopy:false,reply:0,haveReply:false,lastChecked:true}
  def image={fence:custody.fence,holder:custody.holder,original:custody.original,haveIntent:custody.haveIntent,outcome:custody.outcome,haveOutcome:custody.haveOutcome,floor:f.log}
  def aligned=pub.log.nth(pub.log.length()-1)==image
  def ready=pub.qualified and pub.haveCopy and pub.seen==pub.log.length() and pub.copy==image
  def gate(slot)=pub.staged.contains(slot) and ready and pub.parents.nth(slot)==pub.log.length()
  val invariant=safety and aligned and pub.lastChecked
  action noEffect=all {idle,custody'=custody}
  action boot=all {init,pub'=initialPublication}
  def noted(entry,deliver)=pub.with("log",pub.log.append(entry)).with("qualified",false).with("reply",pub.log.length()+1).with("haveReply",deliver)
  action readAuthority(authentic)=all {authentic,aligned,noEffect,pub'=pub.with("copy",image).with("seen",pub.log.length()).with("haveCopy",true).with("qualified",true)}
  action stage(slot,kind,holder,fence)=all {Set(0,1).contains(slot),0<=kind,kind<=9,ready,noEffect,pub'=pub.with("commands",pub.commands.replaceAt(slot,{kind:kind,holder:holder,fence:fence})).with("parents",pub.parents.replaceAt(slot,pub.log.length())).with("staged",pub.staged.union(Set(slot)))}
  action commit(slot,deliver)={val cmd=pub.commands.nth(slot)
    all {gate(slot),any {
      all {cmd.kind==0,begin(pAppend),pub'=noted(image.with("original",pAppend).with("haveIntent",true),deliver)},
      all {cmd.kind==1,propose,pub'=noted(image,deliver)},
      all {cmd.kind==2,validate,pub'=noted(image,deliver)},
      all {cmd.kind==3,arm(cmd.holder,cmd.fence,true),pub'=noted(image,deliver)},
      all {cmd.kind==4,publish(cmd.holder,cmd.fence),pub'=noted(image.with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("floor",f.log.append({proposal:custody.attempt})),deliver)},
      all {cmd.kind==5,transfer(cmd.holder,true),pub'=noted(image.with("fence",custody.fence+1).with("holder",cmd.holder),deliver)},
      all {cmd.kind==6,resolve(cmd.holder,cmd.fence,true),pub'=noted(image,deliver)},
      all {cmd.kind==7,close(cmd.holder,cmd.fence),pub'=noted(image,deliver)},
      all {cmd.kind==8,restart,pub'=noted(image,deliver)},
      all {cmd.kind==9,sourceChange,pub'=noted(image,deliver)}
    }}
  }
  action restore(copy,seen)=all {noEffect,pub'=pub.with("copy",copy).with("seen",seen).with("haveCopy",true).with("qualified",false)}
  action crash=all {noEffect,pub'=pub.with("haveCopy",false).with("qualified",false).with("haveReply",false)}
  action acknowledge(index)=all {0<=index,index<pub.log.length(),noEffect,pub'=pub.with("reply",index+1).with("haveReply",true)}
  action loseReply=all {noEffect,pub'=pub.with("haveReply",false)}
  action applyCommand(slot,kind,holder,fence)=readAuthority(true).then(stage(slot,kind,holder,fence)).then(commit(slot,true))
  action armed=boot.then(applyCommand(0,0,0,0)).then(applyCommand(0,1,0,0)).then(applyCommand(0,2,0,0)).then(applyCommand(0,3,0,0))
  action stagedFloor=armed.then(readAuthority(true)).then(stage(0,4,0,0))
  action committed=stagedFloor.then(commit(0,false))
  action handed=stagedFloor.then(applyCommand(1,5,1,0))
  action recovered=handed.then(applyCommand(1,6,1,1)).then(applyCommand(1,2,1,1)).then(applyCommand(1,3,1,1))
  action transferredCommit=committed.then(applyCommand(1,5,1,0))
  action resolvedCommit=transferredCommit.then(applyCommand(1,6,1,1))
  action restored=committed.then(restore(initialEntry,1))
  action exactCopyRestored=committed.then(restore(image,pub.log.length()))
  action restarted=committed.then(crash)
  action finished=resolvedCommit.then(applyCommand(1,7,1,1))
  action step={nondet slot=Set(0,1).oneOf()
    nondet kind=Set(0,1,2,3,4,5,6,7,8,9).oneOf()
    nondet holder=Set(0,1).oneOf()
    nondet fence=Set(0,1,2,custody.fence).oneOf()
    any {readAuthority(true),stage(slot,kind,holder,fence),commit(slot,true),commit(slot,false),restore(initialEntry,1),restore(image,pub.log.length()),crash,acknowledge(0),loseReply}}
  run stagedIntentHasNoFloorEffectTest=stagedFloor.expect(invariant and f.log.length()==1 and not(custody.haveOutcome))
  run lostFloorReplyRetainsOutcomeTest=committed.expect(invariant and custody.haveOutcome and not(pub.haveReply) and f.log.length()==2)
  run transferPreservesCommittedOutcomeTest=transferredCommit.expect(invariant and custody.fence==1 and custody.outcome.proposal==pAppend)
  run oldParentRejectedAfterTransferTest=handed.then(readAuthority(true)).then(commit(0,true).fail())
  run oldWorkerRejectedAtFreshParentTest=recovered.then(readAuthority(true)).then(stage(0,4,0,0)).then(commit(0,true).fail())
  run newWorkerOriginalAppendTest=recovered.then(applyCommand(0,4,1,1)).expect(invariant and f.log.length()==2)
  run restoreCannotEraseOutcomeTest=restored.expect(invariant and not(ready) and custody.haveOutcome and f.log.length()==2)
  run restoredCopyCannotPublishTest=restored.then(commit(0,true).fail())
  run exactUntrustedCopyCannotPublishTest=exactCopyRestored.then(commit(0,true).fail())
  run restartRetainsOriginalOutcomeTest=restarted.then(readAuthority(true)).expect(invariant and custody.outcome.proposal==pAppend)
  run lateAckCannotRefreshOldCopyTest=restored.then(acknowledge(0)).expect(invariant and not(ready) and pub.seen==1)
  run lateAckPreservesCurrentReadTest=committed.then(readAuthority(true)).then(acknowledge(0)).expect(invariant and ready)
  run unauthenticatedAuthorityReadRejectedTest=restored.then(readAuthority(false).fail())
  run committedOperationCannotReadmitTest=committed.then(readAuthority(true)).then(stage(0,4,0,0)).then(commit(0,true).fail())
  run committedOperationCannotResetIntentTest=committed.then(readAuthority(true)).then(stage(0,0,0,0)).then(commit(0,true).fail())
  run lostTransferReplyRecoveredTest=stagedFloor.then(readAuthority(true)).then(stage(1,5,1,0)).then(commit(1,false)).then(crash).then(readAuthority(true)).expect(invariant and custody.fence==1 and not(custody.haveOutcome))
  run concurrentTransferLosesToCommitTest=stagedFloor.then(stage(1,5,1,0)).then(commit(0,false)).then(readAuthority(true)).then(commit(1,true).fail())
  run closeAfterOutcomeResolutionTest=finished.expect(invariant and custody.phase==4 and f.log.length()==2)
  action splitFence=all {transfer(1,true),pub'=pub.with("reply",pub.log.length()+1).with("haveReply",true)}
  action splitOutcome=all {publish(0,0),pub'=pub.with("reply",pub.log.length()+1).with("haveReply",true)}
  action dropOutcome=all {idle,custody'=custody.with("haveOutcome",false).with("outcome",seed),pub'=pub}
  action dropOriginal=all {idle,custody'=custody.with("haveIntent",false),pub'=pub}
  action trustUnqualifiedCopy=all {noEffect,pub'=pub.with("qualified",true).with("lastChecked",pub.qualified)}
  action ackAsFreshness=all {noEffect,pub'=pub.with("qualified",true).with("seen",pub.log.length()).with("lastChecked",false)}
  action oldWorkerPublication=all {unsafeOldPublish,pub'=noted(image.with("outcome",{proposal:custody.attempt}).with("haveOutcome",true).with("floor",f.log.append({proposal:custody.attempt})),true)}
  run splitFencePublicationCounterexampleTest=armed.then(splitFence).expect(not(invariant))
  run splitOutcomePublicationCounterexampleTest=stagedFloor.then(splitOutcome).expect(not(invariant))
  run lostOutcomePublicationCounterexampleTest=committed.then(dropOutcome).expect(not(invariant))
  run droppedOriginalPublicationCounterexampleTest=committed.then(dropOriginal).expect(not(invariant))
  run untrustedCopyPublicationCounterexampleTest=exactCopyRestored.then(trustUnqualifiedCopy).expect(not(invariant) and ready)
  run lateAckPublicationCounterexampleTest=exactCopyRestored.then(ackAsFreshness).expect(not(invariant) and ready)
  run oldWorkerPublicationCounterexampleTest=recovered.then(oldWorkerPublication).expect(not(invariant) and f.log.length()==2)
}

module DynamicPairedEvidence {
  type Receipt={id:int,elapsed:int,natural:bool,cleaned:bool,checks:bool,objects:int,compiler:int,fresh:bool,hostControlled:bool}
  var records:List[Receipt]
  pure def sample(id:int,elapsed:int,cleaned:bool):Receipt={id:id,elapsed:elapsed,natural:true,cleaned:cleaned,checks:true,objects:1,compiler:1,fresh:true,hostControlled:false}
  pure def eligible(r:Receipt):bool=r.elapsed<=15 and r.natural and r.cleaned and r.checks
  pure def matched(a:Receipt,b:Receipt):bool=a.objects==b.objects and a.compiler==b.compiler
  pure def hostCold(r:Receipt):bool=r.fresh and r.hostControlled
  action boot:bool=records'=List()
  action append(r:Receipt):bool=all {records.forall(old=>old.id!=r.id),records'=records.append(r)}
  action failedThenWarm:bool=boot.then(append(sample(0,16,true))).then(append(sample(1,4,true)))
  run failedFirstIsRetainedTest=failedThenWarm.expect(records.length()==2 and not(eligible(records.nth(0))) and eligible(records.nth(1)))
  run originalDeadlineTest=boot.then(append(sample(0,16,true))).expect(not(eligible(records.nth(0))))
  run exactlyAtDeadlineTest=boot.then(append(sample(0,15,true))).expect(eligible(records.nth(0)))
  run liveResourceBlocksPassTest=boot.then(append(sample(0,4,false))).expect(not(eligible(records.nth(0))))
  run markerAloneBlocksPassTest=boot.then(append(sample(0,4,true).with("natural",false))).expect(not(eligible(records.nth(0))))
  run duplicateSampleRejectedTest=boot.then(append(sample(0,16,true))).then(append(sample(0,4,true)).fail())
  run freshInodeIsNotHostColdTest=boot.then(append(sample(0,4,true))).expect(not(hostCold(records.nth(0))))
  run changedObjectsRejectPairTest=boot.then(append(sample(0,4,true))).then(append(sample(1,5,true).with("objects",2))).expect(not(matched(records.nth(0),records.nth(1))))
  run changedCompilerRejectPairTest=boot.then(append(sample(0,4,true))).then(append(sample(1,5,true).with("compiler",2))).expect(not(matched(records.nth(0),records.nth(1))))
  action unsafeReplace:bool=records'=List(sample(0,4,true))
  run overwriteFailureCounterexampleTest=boot.then(append(sample(0,16,true))).then(unsafeReplace).expect(eligible(records.nth(0)))
  action unsafeForget:bool=records'=List(sample(1,4,true))
  run discardColdFailureCounterexampleTest=failedThenWarm.then(unsafeForget).expect(records.forall(r=>eligible(r)))
  run fewerImagesCanStillBeLateTest=boot.then(append(sample(0,16,true))).then(append(sample(1,8,true))).expect(not(eligible(records.nth(0))) and eligible(records.nth(1)))
}

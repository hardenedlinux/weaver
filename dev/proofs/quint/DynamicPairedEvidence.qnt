module DynamicPairedEvidence {
  type Receipt={id:int,elapsed:int,natural:bool,cleaned:bool,checks:bool,complete:bool,objects:int,compiler:int,fresh:bool,hostControlled:bool}
  var records:List[Receipt]
  pure def sample(id:int,elapsed:int,cleaned:bool):Receipt={id:id,elapsed:elapsed,natural:true,cleaned:cleaned,checks:true,complete:true,objects:1,compiler:1,fresh:true,hostControlled:false}
  pure def eligible(r:Receipt):bool=r.elapsed<=15 and r.natural and r.cleaned and r.checks and r.complete
  pure def matched(a:Receipt,b:Receipt):bool=a.objects==b.objects and a.compiler==b.compiler
  pure def hostCold(r:Receipt):bool=r.fresh and r.hostControlled
  action boot:bool=records'=List()
  action appendReceipt(r:Receipt):bool=all {records.foldl(true,(ok,old)=>ok and old.id!=r.id),records'=records.append(r)}
  action failedThenWarm:bool=boot.then(appendReceipt(sample(0,16,true))).then(appendReceipt(sample(1,4,true)))
  run failedFirstIsRetainedTest=failedThenWarm.expect(records.length()==2 and not(eligible(records.nth(0))) and eligible(records.nth(1)))
  run failedSeriesBlocksAdmissionTest=failedThenWarm.expect(not(records.foldl(true,(ok,r)=>ok and eligible(r))))
  run originalDeadlineTest=boot.then(appendReceipt(sample(0,16,true))).expect(not(eligible(records.nth(0))))
  run exactlyAtDeadlineTest=boot.then(appendReceipt(sample(0,15,true))).expect(eligible(records.nth(0)))
  run liveResourceBlocksPassTest=boot.then(appendReceipt(sample(0,4,false))).expect(not(eligible(records.nth(0))))
  run markerAloneBlocksPassTest=boot.then(appendReceipt(sample(0,4,true).with("natural",false))).expect(not(eligible(records.nth(0))))
  run duplicateSampleRejectedTest=boot.then(appendReceipt(sample(0,16,true))).then(appendReceipt(sample(0,4,true)).fail())
  run freshInodeIsNotHostColdTest=boot.then(appendReceipt(sample(0,4,true))).expect(not(hostCold(records.nth(0))))
  run changedObjectsRejectPairTest=boot.then(appendReceipt(sample(0,4,true))).then(appendReceipt(sample(1,5,true).with("objects",2))).expect(not(matched(records.nth(0),records.nth(1))))
  run changedCompilerRejectPairTest=boot.then(appendReceipt(sample(0,4,true))).then(appendReceipt(sample(1,5,true).with("compiler",2))).expect(not(matched(records.nth(0),records.nth(1))))
  action unsafeReplace:bool=records'=List(sample(0,4,true))
  run overwriteFailureCounterexampleTest=boot.then(appendReceipt(sample(0,16,true))).then(unsafeReplace).expect(eligible(records.nth(0)))
  action unsafeForget:bool=records'=List(sample(1,4,true))
  run discardColdFailureCounterexampleTest=failedThenWarm.then(unsafeForget).expect(records.foldl(true,(ok,r)=>ok and eligible(r)))
  run partialProducerRejectedTest=boot.then(appendReceipt(sample(0,4,true).with("complete",false))).expect(not(eligible(records.nth(0))))
  run fewerImagesCanStillBeLateTest=boot.then(appendReceipt(sample(0,16,true))).then(appendReceipt(sample(1,8,true))).expect(not(eligible(records.nth(0))) and eligible(records.nth(1)))
}

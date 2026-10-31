// Local Scheme program lifecycle. Rust authenticates the installed graph and
// binds the original; neither a closure nor a local result is a send permit.
module GatewayProgram {
  type State={phase:int,selected:int,original:int,inFlight:int,busy:bool,slot:bool,joined:bool,deliveries:List[bool],hold:int,sends:int}
  var p:State
  pure val initial={phase:0,selected:0,original:0,inFlight:0,busy:false,slot:false,joined:false,deliveries:List(),hold:6,sends:0}
  action init=p'=initial
  def safe=(p.busy==p.slot) and (p.busy==(p.inFlight>0)) and
    (p.phase==1 implies (p.selected>0 and p.selected==p.original)) and
    (p.phase==2 implies p.selected==0) and
    (p.joined implies (p.phase==2 and not(p.busy))) and
    p.deliveries.indices().forall(i=>p.deliveries.nth(i)) and p.hold==6 and p.sends==0
  action install(id)=all {p.phase==0,id>0,p'=p.with("phase",1).with("selected",id).with("original",id)}
  // Existing Function normalization rejects invalid arguments before entry.
  action rejectArgument=p'=p
  action rejectInstall=all {p.phase!=0,p'=p}
  action installationFailure=all {p.phase==0,p'=p.with("phase",2)}
  action begin=all {p.phase==1,not(p.busy),p'=p.with("busy",true).with("slot",true).with("inFlight",p.selected)}
  action close=p'=p.with("phase",2).with("selected",0)
  action reenter=all {p.phase==1,p.busy,p'=p.with("phase",2).with("selected",0)}
  action finish=all {p.busy,
    val delivered=if(p.phase==1) p.deliveries.append(p.inFlight==p.original and p.selected==p.original) else p.deliveries
    p'=p.with("busy",false).with("slot",false).with("inFlight",0).with("deliveries",delivered)}
  action failReturn=all {p.busy,p'=p.with("busy",false).with("slot",false).with("inFlight",0)}
  action join=all {p.phase==2,not(p.busy),p'=p.with("joined",true)}
  action step=any {install(1),install(2),rejectArgument,rejectInstall,installationFailure,begin,close,reenter,finish,failReturn,join}
  action ready=init.then(install(1)).then(begin)
  run noImplicitProducerTest=init.then(begin.fail())
  run invalidArgumentDoesNotEnterInstallationTest=init.then(rejectArgument).then(install(1)).expect(safe and p.selected==1)
  run duplicateInstallGuardRefusesTest=init.then(install(1)).then(install(2).fail())
  run closedInstallGuardRefusesTest=init.then(close).then(install(1).fail())
  run duplicateCannotReplaceOrRetireProgramTest=init.then(install(1)).then(rejectInstall).then(begin).then(finish).expect(safe and p.selected==1)
  run internalInstallationFailureIsTerminalTest=init.then(installationFailure).then(rejectInstall).expect(safe)
  run closeRetainsRunningSourceSlotTest=ready.then(close).expect(safe and p.busy and p.slot).then(join.fail())
  run lateCallbackCannotDeliverTest=ready.then(close).then(finish).then(join).expect(safe and p.deliveries.length()==0)
  run caughtReentryPoisonsOuterDeliveryTest=ready.then(reenter).then(finish).expect(safe and p.deliveries.length()==0)
  run failedCaptureCannotResetProducerTest=ready.then(failReturn).then(rejectInstall).then(begin).then(finish).expect(safe)
  run closeCannotReopenTest=init.then(close).then(rejectInstall).expect(safe)
  action unsafeJoin=p'=p.with("joined",true)
  action unsafeLateDelivery=p'=p.with("deliveries",p.deliveries.append(p.phase==1))
  action unsafeReplacement=p'=p.with("selected",2)
  run prematureCleanupCounterexampleTest=ready.then(close).then(unsafeJoin).expect(not(safe))
  run lateDeliveryCounterexampleTest=ready.then(close).then(unsafeLateDelivery).expect(not(safe))
  run duplicateReplacementCounterexampleTest=init.then(install(1)).then(unsafeReplacement).expect(not(safe))
}

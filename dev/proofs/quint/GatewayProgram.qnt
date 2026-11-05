// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Local Scheme program lifecycle. Rust authenticates the installed graph and
// binds the original; neither a closure nor a local result is a send permit.
module GatewayProgram {
  type State={phase:int,selected:int,original:int,inFlight:int,busy:bool,slot:bool,joined:bool,deliveries:List[bool],hold:int,sends:int,graphMember:bool,rootMatches:bool,catalogBound:bool,runtimeActive:bool,caller:int,image:int,validated:bool}
  var p:State
  pure val initial={phase:0,selected:0,original:0,inFlight:0,busy:false,slot:false,joined:false,deliveries:List(),hold:6,sends:0,graphMember:false,rootMatches:false,catalogBound:false,runtimeActive:false,caller:0,image:0,validated:false}
  action init=p'=initial
  def safe=(p.validated implies p.image==p.original) and (p.busy==p.slot) and (p.busy==(p.inFlight>0)) and
    (p.phase==1 implies (p.selected>0 and p.selected==p.original)) and
    (p.phase==2 implies p.selected==0) and
    (p.joined implies (p.phase==2 and not(p.busy))) and
    p.deliveries.indices().forall(i=>p.deliveries.nth(i)) and p.hold==6 and p.sends==0 and
    (p.runtimeActive implies (p.phase==1 and p.graphMember and p.rootMatches and p.catalogBound))
  pure def applicationModeAllowed(qualification:bool,moduleProvided:bool,sourceProvided:bool,fixtureRoot:bool,debugBuild:bool):bool=
    if(qualification) debugBuild and not(moduleProvided) and not(sourceProvided) else moduleProvided and sourceProvided and not(fixtureRoot)
  action observeGraphMember=p'=p.with("graphMember",true)
  action matchRoot=all {p.graphMember,p'=p.with("rootMatches",true)}
  action bindCatalog=all {p.phase==1,p.graphMember,p.rootMatches,not(p.catalogBound),p'=p.with("catalogBound",true)}
  action activateRuntime=all {p.phase==1,p.graphMember,p.rootMatches,p.catalogBound,p'=p.with("runtimeActive",true)}
  action install(id)=all {p.phase==0,id>0,p'=p.with("phase",1).with("selected",id).with("original",id).with("caller",id)}
  // Existing Function normalization rejects invalid arguments before entry.
  action rejectArgument=p'=p
  action rejectInstall=all {p.phase!=0,p'=p}
  action installationFailure=all {p.phase==0,p'=p.with("phase",2)}
  action begin=all {p.phase==1,not(p.busy),p'=p.with("busy",true).with("slot",true).with("inFlight",p.selected)}
  action close=p'=p.with("phase",2).with("selected",0).with("runtimeActive",false)
  action reenter=all {p.phase==1,p.busy,p'=p.with("phase",2).with("selected",0).with("runtimeActive",false)}
  action finish=all {p.busy,
    val delivered=if(p.phase==1) p.deliveries.append(p.inFlight==p.original and p.selected==p.original) else p.deliveries
    p'=p.with("busy",false).with("slot",false).with("inFlight",0).with("deliveries",delivered)}
  action failReturn=all {p.busy,p'=p.with("busy",false).with("slot",false).with("inFlight",0)}
  action join=all {p.phase==2,not(p.busy),p'=p.with("joined",true)}
  action freezeImage=all {p.phase==1,not(p.validated),p'=p.with("image",p.caller)}
  action validateImage=all {p.image>0,p.image==p.original,p'=p.with("validated",true)}
  action callerChange=p'=p.with("caller",2)
  action step=any {freezeImage,validateImage,callerChange,observeGraphMember,matchRoot,bindCatalog,activateRuntime,install(1),install(2),rejectArgument,rejectInstall,installationFailure,begin,close,reenter,finish,failReturn,join}
  run graphMembershipDoesNotInitializeProducerTest=init.then(observeGraphMember).then(activateRuntime.fail())
  run readyWithoutCatalogCannotServeProducerTest=init.then(observeGraphMember).then(install(1)).then(activateRuntime.fail())
  run initializedCatalogCanActivateWithoutSpendingTest=init.then(observeGraphMember).then(matchRoot).then(install(1)).then(bindCatalog).then(activateRuntime).expect(safe and p.hold==6 and p.sends==0)
  run dependencyPresenceDoesNotMatchRootTest=init.then(observeGraphMember).then(install(1)).then(bindCatalog.fail())
  run productionCannotSelectImplicitFixtureTest=init.expect(not(applicationModeAllowed(false,false,false,true,false)) and not(applicationModeAllowed(false,true,true,true,false)))
  run ambiguousApplicationModeRefusesTest=init.expect(not(applicationModeAllowed(true,true,false,true,true)) and not(applicationModeAllowed(true,false,true,true,true)))
  run releaseCannotSelectQualificationRootTest=init.expect(not(applicationModeAllowed(true,false,false,true,false)))
  action unsafeMetadataActivation=p'=p.with("runtimeActive",true)
  action unsafeCatalogBinding=p'=p.with("catalogBound",true)
  run dependencyAsExpectedRootCounterexampleTest=init.then(observeGraphMember).then(install(1)).then(unsafeCatalogBinding).then(unsafeMetadataActivation).expect(not(safe))
  run metadataAsInitializationCounterexampleTest=init.then(observeGraphMember).then(unsafeMetadataActivation).expect(not(safe))
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
  run ownedImageSurvivesCallerMutationTest=init.then(install(1)).then(freezeImage).then(validateImage).then(callerChange).expect(safe and p.image==1 and p.hold==6 and p.sends==0)
  run changedImageCannotBeAdmittedTest=init.then(install(1)).then(callerChange).then(freezeImage).then(validateImage.fail())
  run repeatedPureAdmissionIsInertTest=init.then(install(1)).then(freezeImage).then(validateImage).then(validateImage).expect(safe and p.hold==6 and p.sends==0)
  action unsafeBorrowedImage=p'=p.with("image",p.caller)
  action unsafeAdmissionAsSend=p'=p.with("sends",p.sends+1)
  run borrowedImageAfterAdmissionCounterexampleTest=init.then(install(1)).then(freezeImage).then(validateImage).then(callerChange).then(unsafeBorrowedImage).expect(not(safe))
  run localAdmissionAsSendCounterexampleTest=init.then(install(1)).then(freezeImage).then(validateImage).then(unsafeAdmissionAsSend).expect(not(safe))
}

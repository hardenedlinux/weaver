module LlmAccountCommit {
  import LlmExecutionReconciliation as R from "./LlmExecutionReconciliation"
  type Key={root:int,claim:int,profile:int,budget:int,history:int,reservation:int}
  type Transaction={id:int,key:Key,bound:int,usage:int,resolution:int,source:int,meter:int}
  type Balance={available:int,held:int,charged:int}
  type Image={revision:int,balance:Balance,applications:Set[Transaction],used:Set[int],holds:int->int}
  type Proposal={transaction:Transaction,before:Image,worker:int,sourceGeneration:int}
  type Record={proposal:Proposal,after:Image,epoch:int}
  type Account={anchor:Image,local:Image,journal:List[Record],epoch:int,qualified:bool,prepared:Set[Proposal],observed:Set[int],
    everReleased:int,everCharged:int,otherEvidence:bool,sourceGeneration:int}
  var a:Account
  pure val key={root:10,claim:11,profile:30,budget:5,history:9,reservation:11}
  pure val otherKey=key.with("root",20).with("claim",12).with("reservation",12)
  pure val tx0={id:100,key:key,bound:3,usage:2,resolution:1,source:1,meter:1}
  pure val tx1={id:101,key:otherKey,bound:2,usage:1,resolution:2,source:2,meter:2}
  pure val txFull=tx0.with("usage",3)
  pure val genesis={revision:0,balance:{available:5,held:5,charged:0},applications:Set(),used:Set(),holds:Set(11,12).mapBy(k=>if (k==11) 3 else 2)}
  pure def post(image,tx)=image.with("revision",image.revision+1)
    .with("balance",{available:image.balance.available+tx.bound-tx.usage,held:image.balance.held-tx.bound,charged:image.balance.charged+tx.usage})
    .with("applications",image.applications.union(Set(tx))).with("used",image.used.union(Set(tx.key.reservation))).with("holds",image.holds.set(tx.key.reservation,0))
  pure val p0={transaction:tx0,before:genesis,worker:0,sourceGeneration:0}
  pure val p1={transaction:tx1,before:genesis,worker:0,sourceGeneration:0}
  pure val after0=post(genesis,tx0)
  pure val initial={anchor:genesis,local:genesis,journal:List(),epoch:0,qualified:true,prepared:Set(),observed:Set(),everReleased:0,everCharged:0,otherEvidence:true,sourceGeneration:0}
  def originalEvidence(tx)=if (tx.key==key) R::e.decisions==List(R::executed) and R::e.source.length()==1 and R::e.usage==tx.usage and tx.bound==3 and tx.resolution==1 and tx.source==1 and tx.meter==1
    else tx==tx1 and a.otherEvidence
  def gate(p)=not(R::e.conflict) and R::e.qualified and p.sourceGeneration==a.sourceGeneration and a.qualified and a.local==a.anchor and p.worker==a.epoch and p.before==a.anchor and
    originalEvidence(p.transaction) and p.transaction.usage>=0 and p.transaction.usage<=p.transaction.bound and
    a.anchor.balance.held>=p.transaction.bound and a.anchor.holds.get(p.transaction.key.reservation)==p.transaction.bound and a.anchor.applications.forall(t=>t.id!=p.transaction.id) and
    not(a.anchor.used.contains(p.transaction.key.reservation))
  action init=all {R::usageApplied,a'=initial}
  action hold=R::inert
  action prepare(p)=all {gate(p),hold,a'=a.with("prepared",a.prepared.union(Set(p)))}
  action commit(p,policy,durable)=all {a.prepared.contains(p),gate(p),policy,durable,hold,
    val image=post(a.anchor,p.transaction)
    a'=a.with("anchor",image).with("journal",a.journal.append({proposal:p,after:image,epoch:a.epoch})).with("qualified",false)
      .with("everReleased",a.everReleased+p.transaction.bound-p.transaction.usage).with("everCharged",a.everCharged+p.transaction.usage)}
  action rotate=all {hold,a'=a.with("epoch",a.epoch+1).with("qualified",false)}
  action restore(image)=all {not(a.qualified),hold,a'=a.with("local",image)}
  action recover(authentic)=all {not(a.qualified),authentic,a.local==a.anchor,hold,a'=a.with("qualified",true)}
  action query(tx,authentic)=all {authentic,a.anchor.applications.contains(tx),hold,a'=a.with("observed",a.observed.union(Set(tx.id)))}
  action loseReply=all {hold,a'=a.with("observed",Set())}
  action lateFull=all {R::lateFull,a'=a}
  action conflictUsage=all {R::conflict,a'=a.with("sourceGeneration",a.sourceGeneration+1)}
  action prepared=init.then(prepare(p0))
  action committed=prepared.then(commit(p0,true,true))
  action projected=committed.then(restore(after0)).then(recover(true))
  action restarted=committed.then(rotate)
  action twoPrepared=prepared.then(prepare(p1))
  action fullyCharged=all {R::sourceApplied.then(R::finalUsageReceipt(true)).then(R::usageCAS(R::executed,3,0,true)),a'=initial}
  val conservation=a.anchor.balance.available+a.anchor.balance.held+a.anchor.balance.charged==10 and
    a.anchor.balance.available==5+a.everReleased and a.anchor.balance.charged==a.everCharged and a.anchor.balance.held>=0
  val joined=a.qualified implies a.local==a.anchor
  val unique=a.anchor.applications.forall(x=>a.anchor.applications.forall(y=>x==y or (x.id!=y.id and x.key.reservation!=y.key.reservation))) and
    a.journal.indices().forall(i=>a.journal.indices().forall(j=>i==j or a.journal.nth(i).proposal.transaction.key.reservation!=a.journal.nth(j).proposal.transaction.key.reservation))
  val originalHolds=Set(11,12).forall(k=>a.anchor.holds.get(k)==(if (a.anchor.used.contains(k)) 0 else if (k==11) 3 else 2))
  val paired=a.anchor.applications.forall(t=>a.anchor.used.contains(t.key.reservation)) and
    a.anchor.used.forall(k=>a.anchor.applications.exists(t=>t.key.reservation==k))
  val chain=a.anchor.revision==a.journal.length() and a.journal.indices().forall(i=>{val r=a.journal.nth(i)
    r.proposal.worker==r.epoch and r.proposal.before==(if (i==0) genesis else a.journal.nth(i-1).after) and r.after==post(r.proposal.before,r.proposal.transaction)}) and
    a.anchor==(if (a.journal.length()==0) genesis else a.journal.nth(a.journal.length()-1).after)
  val evidence=a.journal.indices().forall(i=>originalEvidence(a.journal.nth(i).proposal.transaction))
  val safety=originalHolds and evidence and R::safety and conservation and joined and unique and paired and chain
  action step={nondet tx=Set(tx0,tx1,txFull).oneOf()
    nondet p=a.prepared.union(Set(p0,p1,{transaction:tx,before:a.anchor,worker:a.epoch,sourceGeneration:a.sourceGeneration})).oneOf()
    nondet image=a.journal.indices().map(i=>a.journal.nth(i).after).union(Set(genesis,a.anchor)).oneOf()
    any {prepare(p),commit(p,true,true),rotate,restore(image),recover(true),query(tx,true),loseReply,lateFull,conflictUsage}}
  run atomicCommitPairsRecordAndBalanceTest=committed.expect(safety and a.anchor.applications.contains(tx0) and a.anchor.balance.available==6 and a.anchor.balance.charged==2)
  run prepareDoesNotReleaseBalanceTest=prepared.expect(safety and a.anchor==genesis and a.everReleased==0)
  run commitClosesBalanceVisibilityTest=committed.expect(safety and not(a.qualified) and a.local==genesis)
  run lostCommitResponseQueriesOriginalTest=committed.then(loseReply).then(query(tx0,true)).expect(safety and a.observed==Set(100) and a.journal.length()==1)
  run lostCommitResponseCannotRepeatTest=projected.then(loseReply).then(commit(p0,true,true).fail())
  run sameReservationNewApplicationIdRejectedTest=projected.then(prepare({transaction:tx0.with("id",999),before:after0,worker:0,sourceGeneration:0}).fail())
  run sameApplicationChangedUsageRejectedTest=projected.then(prepare({transaction:tx0.with("usage",1),before:after0,worker:0,sourceGeneration:0}).fail())
  run sameApplicationOtherReservationRejectedTest=projected.then(prepare({transaction:tx1.with("id",100),before:after0,worker:0,sourceGeneration:0}).fail())
  run missingDurabilityCannotCommitTest=prepared.then(commit(p0,true,false).fail())
  run deniedFinalPolicyCannotCommitTest=prepared.then(commit(p0,false,true).fail())
  run twoPreparedOneSharedAccountRevisionTest=twoPrepared.then(commit(p0,true,true)).then(restore(after0)).then(recover(true)).then(commit(p1,true,true).fail())
  run rebaseOtherReservationPreservesBothChargesTest=projected.then(prepare({transaction:tx1,before:after0,worker:0,sourceGeneration:0}))
    .then(commit({transaction:tx1,before:after0,worker:0,sourceGeneration:0},true,true)).expect(safety and a.anchor.balance=={available:7,held:0,charged:3})
  run oldWorkerCannotUseFreshImageTest=restarted.then(restore(after0)).then(recover(true))
    .then(prepare({transaction:tx1,before:after0,worker:0,sourceGeneration:0}).fail())
  run oldPreparedCannotCommitAfterRotationTest=prepared.then(rotate).then(restore(genesis)).then(recover(true)).then(commit(p0,true,true).fail())
  run currentWorkerCanContinueOtherReservationTest=restarted.then(restore(after0)).then(recover(true))
    .then(prepare({transaction:tx1,before:after0,worker:1,sourceGeneration:0})).then(commit({transaction:tx1,before:after0,worker:1,sourceGeneration:0},true,true)).expect(safety)
  run fullOldSnapshotCannotRecoverTest=restarted.then(restore(genesis)).then(recover(true).fail())
  run idNewBalanceOldCannotRecoverTest=restarted.then(restore(after0.with("balance",genesis.balance))).then(recover(true).fail())
  run balanceNewIdOldCannotRecoverTest=restarted.then(restore(genesis.with("balance",after0.balance))).then(recover(true).fail())
  run revisionOnlyCannotRecoverTest=restarted.then(restore(genesis.with("revision",1))).then(recover(true).fail())
  run forgedPrefixCannotRecoverTest=restarted.then(restore(after0)).then(recover(false).fail())
  run accountAheadCanReplayOriginalSourceEvidenceTest=restarted.then(restore(after0)).then(recover(true)).then(query(tx0,true)).expect(safety and R::e.source.length()==1)
  run restoredCommitCannotReleaseAgainTest=restarted.then(restore(after0)).then(recover(true)).then(prepare({transaction:tx0,before:after0,worker:1,sourceGeneration:0}).fail())
  run lateReceiptCannotRepriceAccountTest=projected.then(lateFull).expect(safety and a.anchor==after0 and a.everReleased==1)
  run zeroRemainderStillConsumesReservationTest=fullyCharged.then(prepare({transaction:txFull,before:genesis,worker:0,sourceGeneration:0}))
    .then(commit({transaction:txFull,before:genesis,worker:0,sourceGeneration:0},true,true)).expect(safety and a.anchor.used.contains(11) and a.everReleased==0 and a.everCharged==3)
  run unknownUsageCannotPrepareTest=all {R::offered,a'=initial}.then(prepare(p0).fail())
  run sourceTerminalWithoutUsageCannotPrepareTest=all {R::sourceApplied,a'=initial}.then(prepare(p0).fail())
  run wrongOriginalClaimCannotPrepareTest=init.then(prepare(p0.with("transaction",tx0.with("key",key.with("claim",12)))).fail())
  run wrongOriginalProfileCannotPrepareTest=init.then(prepare(p0.with("transaction",tx0.with("key",key.with("profile",31)))).fail())
  run wrongSourceApplicationCannotPrepareTest=init.then(prepare(p0.with("transaction",tx0.with("source",2))).fail())
  run wrongUsageApplicationCannotPrepareTest=init.then(prepare(p0.with("transaction",tx0.with("meter",2))).fail())
  run accountCommitDoesNotApplySourcePaymentTest=committed.expect(safety and R::e.payments.length()==0 and a.journal.length()==1)
  run unknownOriginalCanCoexistWithOtherSettlementTest=all {R::offered,a'=initial}.then(prepare(p1)).then(commit(p1,true,true))
    .expect(safety and a.anchor.holds.get(11)==3 and a.anchor.balance.held==3 and a.everReleased==1)
  run sourceConflictAfterPrepareBlocksCommitTest=prepared.then(conflictUsage).then(commit(p0,true,true).fail())
  action unsafeIdOnly=all {hold,a'=a.with("anchor",a.anchor.with("applications",Set(tx0)).with("used",Set(11)))}
  action unsafeDeltaOnly=all {hold,a'=a.with("anchor",after0.with("applications",Set()).with("used",Set()))
    .with("everReleased",1).with("everCharged",2)}
  action unsafeApply(p)=all {hold,a'=a.with("anchor",post(a.anchor,p.transaction)).with("journal",a.journal.append({proposal:p,after:post(a.anchor,p.transaction),epoch:a.epoch}))
    .with("qualified",false).with("everReleased",a.everReleased+p.transaction.bound-p.transaction.usage).with("everCharged",a.everCharged+p.transaction.usage)}
  action unsafeRecover=all {hold,a'=a.with("qualified",true)}
  action unsafeRollback=all {hold,a'=a.with("anchor",genesis).with("local",genesis).with("journal",List()).with("qualified",true)}
  action unsafeResetUsed=all {hold,a'=a.with("anchor",a.anchor.with("used",Set()))}
  run idWithoutDeltaAccountCounterexampleTest=init.then(unsafeIdOnly).expect(not(chain))
  run deltaWithoutIdAccountCounterexampleTest=init.then(unsafeDeltaOnly).expect(not(chain))
  run retryAfterLostReplyAccountCounterexampleTest=projected.then(loseReply).then(unsafeApply(p0)).expect(not(unique))
  run newIdSameReservationAccountCounterexampleTest=projected.then(unsafeApply({transaction:tx0.with("id",999),before:after0,worker:0,sourceGeneration:0})).expect(not(unique))
  run staleSharedBalanceAccountCounterexampleTest=twoPrepared.then(commit(p0,true,true)).then(unsafeApply(p1)).expect(not(chain))
  run oldWorkerAccountCounterexampleTest=restarted.then(restore(after0)).then(recover(true)).then(unsafeApply({transaction:tx1,before:after0,worker:0,sourceGeneration:0})).expect(not(chain))
  run mixedIdBalanceAccountCounterexampleTest=restarted.then(restore(after0.with("balance",genesis.balance))).then(unsafeRecover).expect(not(joined))
  run anchorRollbackAccountCounterexampleTest=committed.then(unsafeRollback).expect(not(conservation))
  run unknownBudgetAccountCounterexampleTest=all {R::offered,a'=initial}.then(unsafeApply(p0)).expect(not(evidence))
  run tombstoneLossAccountCounterexampleTest=projected.then(unsafeResetUsed).expect(not(paired))
}

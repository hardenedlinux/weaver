// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Parameterized finite fixture. Lean proves arbitrary finite key-list cardinality.
// Root, budget account, history account and endpoint are different coordinates.
module FiniteDomainMigration {
  type Message = {
    reserved: bool, history: bool, issued: Set[int], consumes: int -> int,
    revision: int, candidate: int -> int, claims: int, claimed: bool,
    claimToken: int, claimStream: int, stream: int, authority: int, sends: int,
    observed: bool, retired: bool, finalCost: bool, charged: bool
  }
  type Ticket = {worker: int, generation: int, root: int, fence: int, revision: int, migration: bool}
  type Owner = {worker: int, generation: int, fence: int}
  type Ledger = {
    count: int, messages: int -> Message, aliases: int -> int, endpoints: int -> int,
    created: Set[int], active: Set[int], fences: int -> int,
    restricted: Set[int], live: Set[int], generations: int -> int,
    tickets: int -> Ticket, occupied: Set[int], owners: int -> Owner,
    revision: int, forbiddenOffers: int, staleActions: int,
    reservations: Set[int], auditRestricted: Set[int], originalOwners: int -> Owner,
    semanticClaims: int -> int, semanticOffers: int -> int
  }
  var s: Ledger
  pure val roots = Set(0, 1, 2)
  pure val accounts = Set(0, 1)
  pure val endpoints = 0.to(5)
  pure val workers = Set(0, 1)
  pure val tokens = Set(0, 1, 2, 3)
  pure val slots = 0.to(63)
  pure def intent(a) = a / 2
  pure def root(k) = k % 3
  pure def endpointRoot(e) = e % 3
  pure def budget(r) = if (r < 2) 0 else 1
  pure def history(r) = if (r == 1) 1 else 0
  pure def payload(k) = 10 + k
  pure def cost(k) = 1 + k % 2
  pure def capacity(b) = if (b == 0) 3 else 2
  pure val emptyOwner = {worker: -1, generation: -1, fence: -1}
  pure val emptyTicket = {worker: 0, generation: 0, root: 0, fence: 0, revision: 0, migration: false}
  pure val emptyMessage = {
    reserved: false, history: false, issued: Set(), consumes: tokens.mapBy(_ => 0),
    revision: 0, candidate: workers.mapBy(_ => 0), claims: 0, claimed: false,
    claimToken: 0, claimStream: 0, stream: 0, authority: 0, sends: 0,
    observed: false, retired: false, finalCost: false, charged: false
  }
  def intents = 0.to(s.count - 1)
  def rawAliases = 0.to(2 * s.count - 1)
  pure def writeMessage(l, k, m) = l.with("messages", l.messages.set(k, m)).with("revision", l.revision + 1)
  pure def owner(t) = {worker: t.worker, generation: t.generation, fence: t.fence}
  def booked(b) = intents.fold(0, (n, k) => n +
    (if (budget(root(k)) == b and s.messages.get(k).reserved) cost(k) else 0))
  def heldTotal(b) = intents.fold(0, (n, k) => n +
    (if (budget(root(k)) == b and s.messages.get(k).reserved and not(s.messages.get(k).charged)) cost(k) else 0))
  def chargedTotal(b) = intents.fold(0, (n, k) => n +
    (if (budget(root(k)) == b and s.messages.get(k).charged) cost(k) else 0))
  def current(t) = not(t.migration) and s.live.contains(t.worker) and
    t.generation == s.generations.get(t.worker) and s.active.contains(t.root) and
    t.fence == s.fences.get(t.root) and t.revision == s.revision
  def transferCurrent(t) = t.migration and s.live.contains(t.worker) and
    t.generation == s.generations.get(t.worker) and s.created.contains(t.root) and
    not(s.active.contains(t.root)) and t.fence == s.fences.get(t.root) and t.revision == s.revision
  def bound(a, e, t) = intents.contains(intent(a)) and s.aliases.get(a) == intent(a) and
    s.endpoints.get(e) == root(intent(a)) and t.root == root(intent(a))
  def ready(a, e, slot) = s.occupied.contains(slot) and current(s.tickets.get(slot)) and bound(a, e, s.tickets.get(slot))
  def canActivate(e, slot) = s.occupied.contains(slot) and transferCurrent(s.tickets.get(slot)) and
    endpointRoot(e) == s.tickets.get(slot).root and
    (s.endpoints.get(e) == -1 or s.endpoints.get(e) == s.tickets.get(slot).root)
  action initWith(n) = all { n >= 0, s' = {
    count: n, messages: 0.to(n - 1).mapBy(_ => emptyMessage), aliases: 0.to(2*n - 1).mapBy(_ => -1),
    endpoints: endpoints.mapBy(_ => -1), created: Set(), active: Set(), fences: roots.mapBy(_ => 0),
    restricted: Set(), live: Set(), generations: workers.mapBy(_ => 0), tickets: slots.mapBy(_ => emptyTicket),
    occupied: Set(), owners: 0.to(n-1).mapBy(_ => emptyOwner), revision: 0, forbiddenOffers: 0, staleActions: 0,
    reservations: Set(), auditRestricted: Set(), originalOwners: 0.to(n-1).mapBy(_ => emptyOwner),
    semanticClaims: 0.to(n-1).mapBy(_ => 0), semanticOffers: 0.to(n-1).mapBy(_ => 0)
  } }
  action init = initWith(4)
  action singletonInit = initWith(1)
  action largerInit = initWith(7)
  action enroll(a, p) = all {
    rawAliases.contains(a), p == payload(intent(a)), s.aliases.get(a) == -1 or s.aliases.get(a) == intent(a),
    s' = s.with("aliases", s.aliases.set(a, intent(a))).with("revision", s.revision + 1)
  }
  action create(e, r) = all {
    endpointRoot(e) == r, not(s.created.contains(r)), s.endpoints.get(e) == -1,
    s' = s.with("endpoints", s.endpoints.set(e, r)).with("created", s.created.union(Set(r)))
      .with("active", s.active.union(Set(r))).with("fences", s.fences.set(r, s.fences.get(r)+1))
      .with("revision", s.revision+1)
  }
  action domainAlias(e, r) = all {
    endpointRoot(e) == r, s.created.contains(r), s.endpoints.get(e) == -1 or s.endpoints.get(e) == r,
    s' = s.with("endpoints", s.endpoints.set(e, r)).with("revision", s.revision+1)
  }
  action restart(w) = all { s.generations.get(w) < 3,
    s' = s.with("live", s.live.union(Set(w))).with("generations", s.generations.set(w, s.generations.get(w)+1))
      .with("revision", s.revision+1) }
  action crash(w) = s' = s.with("live", s.live.exclude(Set(w))).with("revision", s.revision+1)
  action resumeOldWorker = s' = s
  action capture(slot, w, r, mode) = all {
    not(s.occupied.contains(slot)), s.live.contains(w), s.created.contains(r), s.active.contains(r) == not(mode),
    s' = s.with("tickets", s.tickets.set(slot,
      {worker: w, generation: s.generations.get(w), root: r, fence: s.fences.get(r), revision: s.revision, migration: mode}))
      .with("occupied", s.occupied.union(Set(slot)))
  }
  action reserve(a, e, slot) = {
    val k = intent(a)
    val t = s.tickets.get(slot)
    all { ready(a,e,slot), not(s.messages.get(k).reserved), booked(budget(t.root))+cost(k) <= capacity(budget(t.root)),
      s' = writeMessage(s,k,s.messages.get(k).with("reserved",true).with("history",true))
        .with("reservations",s.reservations.union(Set(k))) }
  }
  action issue(a,e,slot,tok) = {
    val k = intent(a)
    val m = s.messages.get(k)
    all { ready(a,e,slot), m.reserved, tok/2 == m.authority,
      s' = writeMessage(s,k,m.with("issued",m.issued.union(Set(tok)))) }
  }
  action captureNonce(a,e,slot,w) = {
    val k = intent(a)
    val m = s.messages.get(k)
    all { ready(a,e,slot), s' = writeMessage(s,k,m.with("candidate",m.candidate.set(w,m.revision))) }
  }
  action consume(a,e,slot,w,tok) = {
    val k = intent(a)
    val m = s.messages.get(k)
    all { ready(a,e,slot), m.issued.contains(tok), m.candidate.get(w) == m.revision, m.consumes.get(tok) == 0,
      s' = writeMessage(s,k,m.with("consumes",m.consumes.set(tok,m.consumes.get(tok)+1)).with("revision",m.revision+1)) }
  }
  action claim(a,e,slot,tok) = {
    val k = intent(a)
    val m = s.messages.get(k)
    val o = owner(s.tickets.get(slot))
    all { ready(a,e,slot), m.reserved, m.consumes.get(tok) == 1, not(m.claimed),
      s' = writeMessage(s,k,m.with("claimed",true).with("claims",m.claims+1).with("claimToken",tok).with("claimStream",m.stream))
        .with("owners",s.owners.set(k,o)).with("originalOwners",if (s.semanticClaims.get(k) == 0) s.originalOwners.set(k,o) else s.originalOwners)
        .with("semanticClaims",s.semanticClaims.set(k,s.semanticClaims.get(k)+1)) }
  }
  def localOfferReady(a,slot) = {
    val m = s.messages.get(intent(a))
    m.claimed and m.sends == 0 and m.claimStream == m.stream and not(m.retired) and
      s.owners.get(intent(a)) == owner(s.tickets.get(slot))
  }
  action offer(a,e,slot) = {
    val k = intent(a)
    all { ready(a,e,slot), localOfferReady(a,slot), not(s.restricted.contains(history(s.tickets.get(slot).root))),
      s' = writeMessage(s,k,s.messages.get(k).with("sends",s.messages.get(k).sends+1))
        .with("semanticOffers",s.semanticOffers.set(k,s.semanticOffers.get(k)+1))
        .with("forbiddenOffers",s.forbiddenOffers+(if (s.auditRestricted.contains(history(root(k)))) 1 else 0)) }
  }
  action rotate(a,e,slot) = all { ready(a,e,slot), s.messages.get(intent(a)).authority == 0,
    s' = writeMessage(s,intent(a),s.messages.get(intent(a)).with("authority",1)) }
  action reconnect(a,e,slot) = all { ready(a,e,slot), s.messages.get(intent(a)).stream < 2,
    s' = writeMessage(s,intent(a),s.messages.get(intent(a)).with("stream",s.messages.get(intent(a)).stream+1)) }
  action observe(a,e,slot,tok) = all { ready(a,e,slot), s.messages.get(intent(a)).claimed,
    s.messages.get(intent(a)).claimToken == tok,
    s' = writeMessage(s,intent(a),s.messages.get(intent(a)).with("observed",true)) }
  action retire(a,e,slot,tok) = all { ready(a,e,slot), s.messages.get(intent(a)).claimed,
    s.messages.get(intent(a)).claimToken == tok,
    s' = writeMessage(s,intent(a),s.messages.get(intent(a)).with("retired",true)) }
  action finalUsage(a,e,slot,tok) = all { ready(a,e,slot), s.messages.get(intent(a)).claimed,
    s.messages.get(intent(a)).claimToken == tok,
    s' = writeMessage(s,intent(a),s.messages.get(intent(a)).with("finalCost",true)) }
  action settle(a,e,slot) = {
    val k = intent(a)
    val m = s.messages.get(k)
    all { ready(a,e,slot),m.reserved,m.observed,m.retired,m.finalCost,s' = writeMessage(s,k,m.with("charged",true)) }
  }
  action restrict(h) = s' = s.with("restricted",s.restricted.union(Set(h)))
    .with("auditRestricted",s.auditRestricted.union(Set(h))).with("revision",s.revision+1)
  action sealRoot(r) = all { s.created.contains(r), s.active.contains(r),
    s' = s.with("active",s.active.exclude(Set(r))).with("fences",s.fences.set(r,s.fences.get(r)+1))
      .with("revision",s.revision+1) }
  action activate(e,slot) = all { canActivate(e,slot),
    s' = s.with("endpoints",s.endpoints.set(e,s.tickets.get(slot).root))
      .with("active",s.active.union(Set(s.tickets.get(slot).root)))
      .with("fences",s.fences.set(s.tickets.get(slot).root,s.fences.get(s.tickets.get(slot).root)+1))
      .with("revision",s.revision+1) }
  action step = {
    nondet a = rawAliases.oneOf()
    nondet e = endpoints.oneOf()
    nondet slot = slots.oneOf()
    nondet w = workers.oneOf()
    nondet r = roots.oneOf()
    nondet tok = tokens.oneOf()
    nondet h = accounts.oneOf()
    nondet mode = Set(false,true).oneOf()
    any { enroll(a,payload(intent(a))),create(e,r),domainAlias(e,r),restart(w),crash(w),resumeOldWorker,
      capture(slot,w,r,mode),reserve(a,e,slot),issue(a,e,slot,tok),captureNonce(a,e,slot,w),
      consume(a,e,slot,w,tok),claim(a,e,slot,tok),offer(a,e,slot),rotate(a,e,slot),reconnect(a,e,slot),
      observe(a,e,slot,tok),retire(a,e,slot,tok),finalUsage(a,e,slot,tok),settle(a,e,slot),restrict(h),sealRoot(r),activate(e,slot) }
  }
  val aliasSafety = rawAliases.forall(a => s.aliases.get(a) == -1 or s.aliases.get(a) == intent(a)) and
    endpoints.forall(e => s.endpoints.get(e) == -1 or s.endpoints.get(e) == endpointRoot(e))
  val localSafety = intents.forall(k => {
    val m = s.messages.get(k)
    tokens.forall(t => m.consumes.get(t) <= 1) and m.claims <= 1 and
      (m.claimed iff (m.claims == 1)) and (m.claimed implies m.reserved) and
      m.sends <= (if (m.claimed) 1 else 0) and (m.reserved implies m.history) and
      (m.charged implies (m.observed and m.retired and m.finalCost and m.reserved))
  })
  val semanticSafety = intents.forall(k => s.semanticClaims.get(k) == s.messages.get(k).claims and
    s.semanticOffers.get(k) == s.messages.get(k).sends and s.semanticClaims.get(k) <= 1 and s.semanticOffers.get(k) <= 1)
  val ownerSafety = intents.forall(k => s.messages.get(k).claimed implies s.owners.get(k) == s.originalOwners.get(k))
  val reservationSafety = intents.forall(k => s.messages.get(k).reserved iff s.reservations.contains(k))
  val budgetSafety = accounts.forall(b => booked(b) <= capacity(b) and heldTotal(b)+chargedTotal(b) == booked(b))
  val historySafety = s.restricted == s.auditRestricted and s.forbiddenOffers == 0
  val fencingSafety = s.staleActions == 0
  val safety = aliasSafety and localSafety and semanticSafety and ownerSafety and reservationSafety and budgetSafety and historySafety and fencingSafety

  // Mutants are excluded from step; audit counters and original facts survive.
  action clearMessage(k) = s' = writeMessage(s,k,emptyMessage)
  action clearHistory(h) = s' = s.with("restricted",s.restricted.exclude(Set(h))).with("revision",s.revision+1)
  action rebindClaim(a,slot) = s' = s.with("owners",s.owners.set(intent(a),owner(s.tickets.get(slot))))
  action unsafeOffer(a,e,slot) = {
    val k = intent(a)
    all { localOfferReady(a,slot),not(s.restricted.contains(history(s.tickets.get(slot).root))),
      s' = writeMessage(s,k,s.messages.get(k).with("sends",s.messages.get(k).sends+1))
        .with("semanticOffers",s.semanticOffers.set(k,s.semanticOffers.get(k)+1))
        .with("forbiddenOffers",s.forbiddenOffers+(if (s.auditRestricted.contains(history(root(k)))) 1 else 0))
        .with("staleActions",s.staleActions+(if (ready(a,e,slot)) 0 else 1)) }
  }
  action wrongDomainReserve(a,e,slot) = {
    val k = intent(a)
    val t = s.tickets.get(slot)
    all { current(t),not(s.messages.get(k).reserved),booked(budget(t.root))+cost(k) <= capacity(budget(t.root)),
      s' = writeMessage(s,k,s.messages.get(k).with("reserved",true).with("history",true))
        .with("reservations",s.reservations.union(Set(k))) }
  }

  action unsafeActivate(e,slot) = {
    val t = s.tickets.get(slot)
    all { t.migration,not(s.active.contains(t.root)),t.fence == s.fences.get(t.root),
      s' = s.with("endpoints",s.endpoints.set(e,t.root)).with("active",s.active.union(Set(t.root)))
        .with("fences",s.fences.set(t.root,s.fences.get(t.root)+1)).with("revision",s.revision+1)
        .with("staleActions",s.staleActions+(if (canActivate(e,slot)) 0 else 1)) }
  }
  run settledChargeSurvivesMigrationTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(offer(0,0,4))
    .then(capture(5,0,0,false))
    .then(observe(0,0,5,0))
    .then(capture(6,0,0,false))
    .then(retire(0,0,6,0))
    .then(capture(7,0,0,false))
    .then(finalUsage(0,0,7,0))
    .then(capture(8,0,0,false))
    .then(settle(0,0,8))
    .then(sealRoot(0))
    .then(capture(9,1,0,true))
    .then(activate(3,9))
    .expect(safety and s.messages.get(0).sends == 1 and chargedTotal(0) == 1 and heldTotal(0) == 0 and booked(0) == 1)
  run emptyUniverseTest = initWith(0)
    .expect(safety and intents.size() == 0 and booked(0) == 0)
  run threeMessagesAndSharedAccountsTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(enroll(2,11))
    .then(enroll(4,12))
    .then(create(1,1))
    .then(create(2,2))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,1,false))
    .then(reserve(2,1,1))
    .then(capture(2,0,2,false))
    .then(reserve(4,2,2))
    .expect(safety and booked(0) == 3 and booked(1) == 1 and s.reservations.size() == 3)
  run migrationRetainsClaimAndEvidenceTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(sealRoot(0))
    .then(capture(5,1,0,true))
    .then(activate(3,5))
    .then(capture(6,1,0,false))
    .then(observe(0,3,6,0))
    .expect(safety and not(current(s.tickets.get(4))) and s.messages.get(0).claims == 1 and s.messages.get(0).observed and s.messages.get(0).sends == 0 and heldTotal(0) == 1 and s.owners.get(0) != owner(s.tickets.get(6)))
  run restartRetainsClaimTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(crash(0))
    .then(restart(0))
    .then(resumeOldWorker)
    .then(capture(5,0,0,false))
    .then(observe(0,0,5,0))
    .expect(safety and not(current(s.tickets.get(4))) and s.messages.get(0).claims == 1 and heldTotal(0) == 1 and s.owners.get(0) != owner(s.tickets.get(5)))
  run sharedAccountInvalidatesTransferTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(enroll(2,11))
    .then(create(1,1))
    .then(sealRoot(0))
    .then(capture(4,1,0,true))
    .then(capture(5,0,1,false))
    .then(reserve(2,1,5))
    .expect(safety and not(canActivate(3,4)) and booked(0) == 3 and not(s.active.contains(0)))
  run sealedDomainAliasDoesNotReopenTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(sealRoot(0))
    .then(domainAlias(3,0))
    .expect(safety and not(s.active.contains(0)) and s.created.contains(0))
  run recreateExistingRootRejectedTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(sealRoot(0))
    .then(create(3,0).fail())
  run wrongBudgetDomainRejectedTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(create(2,2))
    .then(capture(0,0,2,false))
    .then(reserve(0,2,0).fail())
  run oldWorkerAfterMigrationCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(sealRoot(0))
    .then(capture(5,1,0,true))
    .then(activate(3,5))
    .then(resumeOldWorker)
    .then(unsafeOffer(0,0,4))
    .expect(localSafety and semanticSafety and ownerSafety and not(fencingSafety) and s.staleActions == 1)
  run oldWorkerAfterRestartCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(crash(0))
    .then(restart(0))
    .then(resumeOldWorker)
    .then(unsafeOffer(0,0,4))
    .expect(localSafety and semanticSafety and not(fencingSafety))
  run claimHandoffCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(sealRoot(0))
    .then(capture(5,1,0,true))
    .then(activate(3,5))
    .then(capture(6,1,0,false))
    .then(rebindClaim(0,6))
    .then(offer(0,3,6))
    .expect(localSafety and semanticSafety and not(ownerSafety) and s.semanticOffers.get(0) == 1)
  run wrongDomainBudgetCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(enroll(2,11))
    .then(enroll(6,13))
    .then(create(1,1))
    .then(create(2,2))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,1,false))
    .then(reserve(2,1,1))
    .then(capture(2,0,2,false))
    .then(wrongDomainReserve(6,2,2))
    .expect(localSafety and reservationSafety and not(budgetSafety) and booked(0) == 5)
  run newDomainHistoryCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(create(1,1))
    .then(restrict(0))
    .then(capture(4,0,1,false))
    .then(unsafeOffer(0,1,4))
    .expect(localSafety and ownerSafety and not(historySafety) and not(fencingSafety))
  run migrationHistoryResetCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(create(2,2))
    .then(restrict(0))
    .then(sealRoot(2))
    .then(capture(4,1,2,true))
    .then(activate(5,4))
    .then(clearHistory(0))
    .then(capture(5,0,0,false))
    .then(offer(0,0,5))
    .expect(localSafety and not(historySafety) and s.forbiddenOffers == 1)
  run staleTransferCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(enroll(2,11))
    .then(create(1,1))
    .then(sealRoot(0))
    .then(capture(4,1,0,true))
    .then(capture(5,0,1,false))
    .then(reserve(2,1,5))
    .then(unsafeActivate(3,4))
    .expect(localSafety and budgetSafety and not(fencingSafety))
  run restoredCheckpointReplayCounterexampleTest = init
    .then(enroll(0,10))
    .then(create(0,0))
    .then(restart(0))
    .then(restart(1))
    .then(capture(0,0,0,false))
    .then(reserve(0,0,0))
    .then(capture(1,0,0,false))
    .then(issue(0,0,1,0))
    .then(capture(2,0,0,false))
    .then(consume(0,0,2,0,0))
    .then(capture(3,0,0,false))
    .then(claim(0,0,3,0))
    .then(capture(4,0,0,false))
    .then(offer(0,0,4))
    .then(clearMessage(0))
    .then(capture(6,0,0,false))
    .then(reserve(0,0,6))
    .then(capture(7,0,0,false))
    .then(issue(0,0,7,1))
    .then(capture(8,0,0,false))
    .then(consume(0,0,8,0,1))
    .then(capture(9,0,0,false))
    .then(claim(0,0,9,1))
    .then(capture(10,0,0,false))
    .then(offer(0,0,10))
    .expect(localSafety and budgetSafety and not(semanticSafety) and s.semanticClaims.get(0) == 2 and s.semanticOffers.get(0) == 2)
}

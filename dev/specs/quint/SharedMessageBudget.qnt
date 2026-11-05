// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Two canonical intents, four aliases, a fixed shared budget/history domain.
// Owner-authenticated intent/payload facts are immutable fixture inputs.
module SharedMessageBudget {
  type Message = {
    reserved: bool, history: bool, issued: Set[int], consumes: int -> int,
    revision: int, candidate: int -> int, claims: int, claimed: bool,
    claimToken: int, claimStream: int, stream: int, authority: int, sends: int,
    observed: bool, retired: bool, finalCost: bool, charged: bool
  }
  type Ledger = {
    messages: int -> Message, aliases: int -> int, revision: int,
    candidates: int -> int, snapshots: int -> int, restricted: bool,
    forbiddenOffers: int, semanticClaims: int -> int, semanticOffers: int -> int, capacity: int
  }
  var s: Ledger
  pure val intents = Set(0, 1)
  pure val aliases = Set(0, 1, 2, 3)
  pure val tokens = Set(0, 1, 2, 3)
  pure val workers = Set(0, 1)
  pure def intent(a) = a / 2
  pure def payload(k) = 10 + k
  pure def cost(k) = k + 1
  pure val emptyMessage = {
    reserved: false, history: false, issued: Set(), consumes: tokens.mapBy(_ => 0),
    revision: 0, candidate: workers.mapBy(_ => 0), claims: 0, claimed: false,
    claimToken: 0, claimStream: 0, stream: 0, authority: 0, sends: 0,
    observed: false, retired: false, finalCost: false, charged: false
  }
  pure def allocation(m, k) = if (m.reserved) cost(k) else 0
  def booked = intents.fold(0, (n, k) => n + allocation(s.messages.get(k), k))
  def heldTotal = intents.fold(0, (n, k) =>
    n + (if (s.messages.get(k).reserved and not(s.messages.get(k).charged)) cost(k) else 0))
  def chargedTotal = intents.fold(0, (n, k) => n + (if (s.messages.get(k).charged) cost(k) else 0))
  def canonical(a) = s.aliases.get(a)
  def enrolled(a) = canonical(a) >= 0
  pure def replace(l, k, m) = l.with("messages", l.messages.set(k, m)).with("revision", l.revision + 1)
  action initWith(cap) = s' = {
    messages: intents.mapBy(_ => emptyMessage), aliases: aliases.mapBy(_ => -1), revision: 0,
    candidates: workers.mapBy(_ => 0), snapshots: workers.mapBy(_ => 0),
    restricted: false, forbiddenOffers: 0, semanticClaims: intents.mapBy(_ => 0), semanticOffers: intents.mapBy(_ => 0), capacity: cap
  }
  action init = initWith(3)
  action tightInit = initWith(2)
  action enroll(a, p) = all {
    p == payload(intent(a)), canonical(a) == -1 or canonical(a) == intent(a),
    s' = s.with("aliases", s.aliases.set(a, intent(a))).with("revision", s.revision + 1)
  }
  action capture(w) = s' = s.with("candidates", s.candidates.set(w, s.revision))
    .with("snapshots", s.snapshots.set(w, booked))
  def canReserve(a, w) = enrolled(a) and s.candidates.get(w) == s.revision and
    not(s.messages.get(canonical(a)).reserved) and booked + cost(canonical(a)) <= s.capacity
  action reserve(a, w) = all {
    canReserve(a, w),
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("reserved", true).with("history", true))
  }
  action issue(a, t) = {
    val m = s.messages.get(canonical(a))
    all { enrolled(a), m.reserved, t / 2 == m.authority,
      s' = replace(s, canonical(a), m.with("issued", m.issued.union(Set(t)))) }
  }
  action captureNonce(a, w) = {
    val m = s.messages.get(canonical(a))
    all { enrolled(a), s' = replace(s, canonical(a), m.with("candidate", m.candidate.set(w, m.revision))) }
  }
  action consume(a, w, t) = {
    val m = s.messages.get(canonical(a))
    all { enrolled(a), m.issued.contains(t), m.candidate.get(w) == m.revision, m.consumes.get(t) == 0,
      s' = replace(s, canonical(a), m.with("consumes", m.consumes.set(t, m.consumes.get(t) + 1))
        .with("revision", m.revision + 1)) }
  }
  def canClaim(a, t) = enrolled(a) and s.messages.get(canonical(a)).reserved and
    s.messages.get(canonical(a)).consumes.get(t) == 1 and not(s.messages.get(canonical(a)).claimed)
  action claim(a, t) = {
    val m = s.messages.get(canonical(a))
    all { canClaim(a, t),
      s' = replace(s, canonical(a), m.with("claims", m.claims + 1).with("claimed", true)
        .with("claimToken", t).with("claimStream", m.stream))
        .with("semanticClaims", s.semanticClaims.set(intent(a), s.semanticClaims.get(intent(a)) + 1)) }
  }
  def localOfferReady(a, w) = enrolled(a) and s.candidates.get(w) == s.revision and
    s.messages.get(canonical(a)).claimed and s.messages.get(canonical(a)).sends == 0 and
    s.messages.get(canonical(a)).claimStream == s.messages.get(canonical(a)).stream and
    not(s.messages.get(canonical(a)).retired)
  action offer(a, w) = all {
    localOfferReady(a, w), not(s.restricted),
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("sends", 1))
      .with("forbiddenOffers", s.forbiddenOffers + (if (s.restricted) 1 else 0))
      .with("semanticOffers", s.semanticOffers.set(intent(a), s.semanticOffers.get(intent(a)) + 1))
  }
  action rotate(a) = all { enrolled(a), s.messages.get(canonical(a)).authority == 0,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("authority", 1)) }
  action reconnect(a) = all { enrolled(a), s.messages.get(canonical(a)).stream < 2,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("stream", s.messages.get(canonical(a)).stream + 1)) }
  action observe(a, t) = all { enrolled(a), s.messages.get(canonical(a)).claimed,
    t == s.messages.get(canonical(a)).claimToken,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("observed", true)) }
  action retire(a, t) = all { enrolled(a), s.messages.get(canonical(a)).claimed,
    t == s.messages.get(canonical(a)).claimToken,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("retired", true)) }
  action finalUsage(a, t) = all { enrolled(a), s.messages.get(canonical(a)).claimed,
    t == s.messages.get(canonical(a)).claimToken,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("finalCost", true)) }
  action settle(a) = {
    val m = s.messages.get(canonical(a))
    all { enrolled(a), m.reserved, m.observed, m.retired, m.finalCost,
      s' = replace(s, canonical(a), m.with("charged", true)) }
  }
  action restrict = s' = s.with("restricted", true).with("revision", s.revision + 1)
  action step = {
    nondet a = aliases.oneOf()
    nondet w = workers.oneOf()
    nondet t = tokens.oneOf()
    any { enroll(a, payload(intent(a))), capture(w), reserve(a, w), issue(a, t), captureNonce(a, w),
      consume(a, w, t), claim(a, t), offer(a, w), rotate(a), reconnect(a), observe(a, t), retire(a, t),
      finalUsage(a, t), settle(a), restrict }
  }
  val aliasSafety = aliases.forall(a => canonical(a) == -1 or canonical(a) == intent(a))
  val localSafety = intents.forall(k => {
    val m = s.messages.get(k)
    tokens.forall(t => m.consumes.get(t) <= 1) and m.claims <= 1 and
    (m.claimed iff (m.claims == 1)) and (m.claimed implies m.reserved) and
    m.sends <= (if (m.claimed) 1 else 0) and (m.reserved implies m.history) and
    (m.charged implies (m.observed and m.retired and m.finalCost and m.reserved))
  })
  val semanticSafety = intents.forall(k => s.semanticClaims.get(k) == s.messages.get(k).claims and
    s.semanticClaims.get(k) <= 1 and s.semanticOffers.get(k) == s.messages.get(k).sends and
    s.semanticOffers.get(k) <= 1)
  val budgetSafety = booked <= s.capacity and heldTotal + chargedTotal == booked
  val historySafety = s.forbiddenOffers == 0
  val safety = aliasSafety and localSafety and semanticSafety and budgetSafety and historySafety

  // Bad transitions are excluded from step. Independent semantic counters expose
  // two locally unique claims that actually refer to the same admitted intent.
  action misresolve(a, k) = s' = s.with("aliases", s.aliases.set(a, k)).with("revision", s.revision + 1)
  action cachedReserve(a, w) = all {
    enrolled(a), not(s.messages.get(canonical(a)).reserved),
    s.snapshots.get(w) + cost(canonical(a)) <= s.capacity,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("reserved", true).with("history", true))
  }
  action privateBudgetReserve(a) = all { enrolled(a), cost(canonical(a)) <= s.capacity,
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("reserved", true).with("history", true)) }
  action historyBlindOffer(a, w) = all { localOfferReady(a, w),
    s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("sends", 1))
      .with("forbiddenOffers", s.forbiddenOffers + (if (s.restricted) 1 else 0))
      .with("semanticOffers", s.semanticOffers.set(intent(a), s.semanticOffers.get(intent(a)) + 1)) }
  action forgetSettledReservation(a) = s' = replace(s, canonical(a), s.messages.get(canonical(a)).with("reserved", false))

  run distinctMessagesTest = init.then(enroll(0, 10)).then(enroll(2, 11))
    .then(capture(0)).then(reserve(0, 0)).then(capture(1)).then(reserve(2, 1))
    .expect(safety and booked == 3 and heldTotal == 3)
  run aliasRefreshTest = init.then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(capture(0)).then(offer(0, 0))
    .then(enroll(1, 10)).then(rotate(1)).then(issue(1, 2)).then(captureNonce(1, 1))
    .then(consume(1, 1, 2)).then(reconnect(1)).then(observe(1, 0))
    .expect(safety and not(canClaim(1, 2)) and booked == 1 and heldTotal == 1 and
      s.messages.get(0).claimToken == 0 and s.messages.get(0).claimStream != s.messages.get(0).stream)
  run sharedHistoryTest = init.then(enroll(0, 10)).then(enroll(2, 11)).then(restrict)
    .then(capture(0)).then(reserve(2, 0)).then(issue(2, 0)).then(consume(2, 0, 0))
    .then(claim(2, 0)).then(capture(0))
    .expect(safety and localOfferReady(2, 0) and s.restricted)
  run sharedContentionTest = initWith(2).then(enroll(0, 10)).then(enroll(2, 11))
    .then(capture(0)).then(capture(1)).then(reserve(0, 0))
    .expect(safety and not(canReserve(2, 1)) and s.candidates.get(1) != s.revision)
  run settlementKeepsChargeTest = init.then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(observe(0, 0))
    .then(retire(0, 0)).then(finalUsage(0, 0)).then(settle(0))
    .then(enroll(2, 11)).then(capture(0)).then(reserve(2, 0))
    .expect(safety and booked == 3 and heldTotal == 2 and chargedTotal == 1)
  run wrongPayloadTest = init.then(enroll(0, 10)).then(enroll(0, 11).fail())
  run freshNonceKeyCounterexampleTest = init.then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(capture(0)).then(offer(0, 0))
    .then(misresolve(1, 1)).then(capture(0)).then(reserve(1, 0))
    .then(issue(1, 1)).then(consume(1, 0, 1)).then(claim(1, 1)).then(capture(0)).then(offer(1, 0))
    .expect(localSafety and budgetSafety and not(aliasSafety) and not(semanticSafety) and
      s.semanticClaims.get(0) == 2 and s.semanticOffers.get(0) == 2)
  run freshAuthorityKeyCounterexampleTest = init.then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(capture(0)).then(offer(0, 0))
    .then(misresolve(1, 1)).then(capture(0)).then(reserve(1, 0))
    .then(rotate(1)).then(issue(1, 2)).then(consume(1, 0, 2)).then(claim(1, 2)).then(capture(0)).then(offer(1, 0))
    .expect(localSafety and budgetSafety and not(aliasSafety) and not(semanticSafety) and
      s.semanticClaims.get(0) == 2 and s.semanticOffers.get(0) == 2)
  run reconnectKeyCounterexampleTest = init.then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(capture(0)).then(offer(0, 0))
    .then(misresolve(1, 1)).then(capture(0)).then(reserve(1, 0))
    .then(reconnect(1)).then(issue(1, 0)).then(consume(1, 0, 0)).then(claim(1, 0)).then(capture(0)).then(offer(1, 0))
    .expect(localSafety and budgetSafety and not(aliasSafety) and not(semanticSafety) and
      s.semanticClaims.get(0) == 2 and s.semanticOffers.get(0) == 2)
  run concurrentBudgetCounterexampleTest = initWith(2).then(enroll(0, 10)).then(enroll(2, 11))
    .then(capture(0)).then(capture(1)).then(reserve(0, 0)).then(cachedReserve(2, 1))
    .expect(localSafety and not(budgetSafety) and booked == 3)
  run privateBudgetCounterexampleTest = initWith(2).then(enroll(0, 10)).then(enroll(2, 11))
    .then(privateBudgetReserve(0)).then(privateBudgetReserve(2))
    .expect(localSafety and not(budgetSafety))
  run freshKeyHistoryCounterexampleTest = init.then(enroll(0, 10)).then(restrict)
    .then(enroll(2, 11)).then(capture(0)).then(reserve(2, 0)).then(issue(2, 0))
    .then(consume(2, 0, 0)).then(claim(2, 0)).then(reconnect(0))
    .then(capture(0)).then(historyBlindOffer(2, 0))
    .expect(localSafety and not(historySafety))
  run settlementBudgetCounterexampleTest = initWith(2).then(enroll(0, 10)).then(capture(0)).then(reserve(0, 0))
    .then(issue(0, 0)).then(consume(0, 0, 0)).then(claim(0, 0)).then(observe(0, 0))
    .then(retire(0, 0)).then(finalUsage(0, 0)).then(settle(0)).then(forgetSettledReservation(0))
    .then(enroll(2, 11)).then(capture(0)).then(reserve(2, 0))
    .expect(not(budgetSafety) and heldTotal + chargedTotal > s.capacity)
}

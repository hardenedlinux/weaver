// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Two canonical origins share capacity. The durable image is authoritative;
// calls are an external ghost history, and cursor/activation are volatile.
module ProviderEgressWindow {
  pure val origins = Set(0, 1)
  pure val slots = Set(0, 1, 2)
  pure val coordinates = Set((0,0), (0,1), (0,2), (1,0), (1,1), (1,2))
  pure def canonical(alias: int): int = if (alias == 2) 0 else alias

  type State = {
    owner: int, durable: int, image: int, allowed: bool, blocked: bool,
    mutation: int, cut: int, committed: bool,
    burns: int -> int, requestBound: Set[int], lost: Set[int], active: Set[int], cursor: int -> int,
    calls: (int, int) -> int, held: int, history: Set[int], terminal: Set[int], settled: Set[int]
  }
  var s: State

  action init = s' = {
    owner: 1, durable: 0, image: 0, allowed: true, blocked: false,
    mutation: 0, cut: 0, committed: false,
    burns: Map(0 -> 0, 1 -> 0), requestBound: Set(), lost: Set(), active: Set(),
    cursor: Map(0 -> 0, 1 -> 0),
    calls: coordinates.mapBy(_ => 0), held: 0, history: Set(), terminal: Set(), settled: Set()
  }

  pure def joins(blocked: bool, projected: int, durable: int): bool =
    not(blocked) and projected == durable

  action stage(kind: int): bool = all {
    not(s.blocked), s.image == s.durable, Set(1, 2, 3, 4, 5).contains(kind),
    s' = {...s, blocked: true, mutation: kind, cut: s.cut + 1, committed: false}
  }

  // New original claim, hold and history are one durable transition.
  // A new wire alias cannot allocate another canonical window.
  action burn(alias: int, cut: int): bool = {
    val origin = canonical(alias)
    all {
      s.blocked, s.cut == cut, s.mutation == 1, not(s.committed),
      s.burns.get(origin) == 0, s.held + 3 <= 6,
      s' = {...s, durable: s.durable + 1, committed: true,
            burns: s.burns.set(origin, s.owner), held: s.held + 3, history: s.history.union(Set(origin))}
    }
  }

  // Policy/grant revocation and domain migration share the effect barrier.
  // A migration changes the exact image while retaining the same exposure.
  action change(cut: int): bool = all {
    s.blocked, s.cut == cut, Set(2, 3).contains(s.mutation), not(s.committed),
    s' = {...s, durable: s.durable + 1, committed: true, requestBound: Set(), active: Set(),
          lost: origins.filter(origin => s.burns.get(origin) != 0),
          allowed: if (s.mutation == 2) false else s.allowed}
  }

  // Recovery observes the exact durable decision; a delayed ack cannot reopen.
  action publish(cut: int, observed: int): bool = all {
    s.blocked, s.committed, s.cut == cut, observed == s.durable,
    s' = {...s, image: observed, blocked: false, mutation: 0, committed: false}
  }

  action abortMutation(cut: int): bool = all {
    s.blocked, s.cut == cut, s.mutation != 0, not(s.committed), s.image == s.durable,
    s' = {...s, blocked: false, mutation: 0}
  }

  action abandonAck(origin: int): bool = all {
    s.burns.get(origin) == s.owner, not(s.active.contains(origin)),
    s' = {...s, lost: s.lost.union(Set(origin))}
  }

  // Confirmed response from the exact guarded provider request. This models
  // the existing request-writer seal and binding, rather than a new send.
  action bindRequest(origin: int, owner: int): bool = all {
    joins(s.blocked, s.image, s.durable), owner == s.owner,
    s.burns.get(origin) == owner, not(s.lost.contains(origin)),
    not(s.requestBound.contains(origin)),
    s' = {...s, requestBound: s.requestBound.union(Set(origin))}
  }

  action activate(origin: int, owner: int): bool = all {
    joins(s.blocked, s.image, s.durable), owner == s.owner,
    s.burns.get(origin) == owner, not(s.lost.contains(origin)),
    s.requestBound.contains(origin), not(s.active.contains(origin)), not(s.terminal.contains(origin)),
    s' = {...s, active: s.active.union(Set(origin))}
  }

  // Evaluation and transport offer share one owner-linearized turn.
  // cedar is the fresh result for these exact bytes under this image.
  action offer(alias: int, slot: int, owner: int, projected: int, cedar: bool, exact: bool): bool = {
    val origin = canonical(alias)
    all {
      joins(s.blocked, projected, s.durable), s.image == projected,
      owner == s.owner, s.burns.get(origin) == owner, s.active.contains(origin),
      s.allowed, cedar, exact, s.cursor.get(origin) == slot, slots.contains(slot),
      s' = {...s, cursor: s.cursor.set(origin, slot + 1),
            calls: s.calls.set((origin, slot), s.calls.get((origin, slot)) + 1)}
    }
  }

  // Terminal authorization is a separate durable change. All three slots
  // are the finite fixture's required prefix and include the terminal frame.
  action commitTerminal(origin: int, cut: int): bool = all {
    s.blocked, s.mutation == 4, s.cut == cut, not(s.committed),
    s.active.contains(origin), s.requestBound.contains(origin),
    s.cursor.get(origin) == 3, not(s.terminal.contains(origin)),
    s' = {...s, durable: s.durable + 1, committed: true,
          active: s.active.exclude(Set(origin)), terminal: s.terminal.union(Set(origin))}
  }

  // The application key is canonical origin in this finite fixture.
  // authentic abstracts the existing independent issuer and exact tariff join.
  action applySettlement(alias: int, cut: int, authentic: bool): bool = {
    val origin = canonical(alias)
    all {
      s.blocked, s.mutation == 5, s.cut == cut, not(s.committed),
      authentic, s.terminal.contains(origin), not(s.settled.contains(origin)),
      s' = {...s, durable: s.durable + 1, committed: true,
            settled: s.settled.union(Set(origin)), held: s.held - 3}
    }
  }

  // The next incarnation can reconcile the durable image but cannot reopen
  // any old burn. Unsent slots are retired and the hold stays unknown.
  action restart = s' = {
    ...s, owner: s.owner + 1, blocked: true, mutation: 0, cut: s.cut + 1, committed: true,
    requestBound: Set(), active: Set(), cursor: Map(0 -> 0, 1 -> 0)
  }

  action step = {
    nondet alias = Set(0, 1, 2).oneOf()
    nondet slot = slots.oneOf()
    nondet kind = Set(1, 2, 3, 4, 5).oneOf()
    any {
      stage(kind), burn(alias, s.cut), change(s.cut), publish(s.cut, s.durable), abortMutation(s.cut),
      abandonAck(canonical(alias)), bindRequest(canonical(alias), s.owner),
      activate(canonical(alias), s.owner),
      offer(alias, slot, s.owner, s.image, true, true),
      commitTerminal(canonical(alias), s.cut), applySettlement(alias, s.cut, true), restart
    }
  }

  val safety =
    s.image <= s.durable and (not(s.blocked) implies s.image == s.durable) and
    s.history == origins.filter(origin => s.burns.get(origin) != 0) and
    s.settled.subseteq(s.terminal) and s.terminal.subseteq(s.history) and
    s.held == s.history.exclude(s.settled).size() * 3 and s.held >= 0 and s.held <= 6 and
    s.active.forall(origin => not(s.terminal.contains(origin)) and s.requestBound.contains(origin) and s.burns.get(origin) == s.owner and not(s.lost.contains(origin))) and
    coordinates.forall(key =>
      s.calls.get(key) <= 1 and
      (s.calls.get(key) == 1 implies s.burns.get(key._1) != 0))

  action burned = init.then(stage(1)).then(burn(0, 1))
  action ready = burned.then(publish(1, 1)).then(bindRequest(0, 1)).then(activate(0, 1))
  action first = ready.then(offer(0, 0, 1, 1, true, true))

  run orderedOffersKeepUnknownExposureTest = first
    .then(offer(2, 1, 1, 1, true, true))
    .expect(safety and s.held == 3 and s.calls.get((0, 1)) == 1)
  run oldAliasCannotDuplicateOfferTest = first
    .then(offer(2, 0, 1, 1, true, true).fail())
  run staleOrDeniedInputCannotOfferTest = ready
    .then(offer(0, 0, 1, 0, true, true).fail())
  run mutablePayloadCannotOfferTest = ready
    .then(offer(0, 0, 1, 1, true, false).fail())
  run freshCedarDenialCannotOfferTest = ready
    .then(offer(0, 0, 1, 1, false, true).fail())
  run burnWithoutConfirmedRequestCannotActivateTest = burned.then(publish(1, 1))
    .then(activate(0, 1).fail())
  run oldQueuedTransportCannotOfferAfterRestartTest = first.then(restart).then(publish(2, 1))
    .then(offer(0, 1, 1, 1, true, true).fail())
  run committedButUnprojectedChangeBlocksOfferTest = first.then(stage(2)).then(change(2))
    .then(offer(0, 1, 1, 1, true, true).fail())

  run durableCommitNeedsImageActivationTest = burned.then(activate(0, 1).fail())
  run lostBurnAckSealsOriginalTest = burned.then(publish(1, 1)).then(abandonAck(0))
    .expect(safety and s.held == 3)
    .then(activate(0, 1).fail())
  run pendingRevocationStopsActualOfferTest = first.then(stage(2))
    .then(offer(0, 1, 1, 1, true, true).fail())
  run stalePublicationAckCannotReopenTest = first.then(stage(2)).then(change(2))
    .then(publish(2, 1).fail())
  run committedRevocationStopsActualOfferTest = first.then(stage(2)).then(change(2))
    .then(publish(2, 2)).then(offer(0, 1, 1, 2, true, true).fail())
  run migrationRejoinsHeadAndRetiresOldWindowTest = first.then(stage(3)).then(change(2))
    .then(publish(2, 2)).expect(safety and s.held == 3)
    .then(offer(0, 1, 1, 2, true, true).fail())
  run restartDiscardsTailAndKeepsHoldTest = first.then(restart).then(publish(2, 1))
    .expect(safety and s.held == 3 and s.calls.get((0, 0)) == 1)
    .then(activate(0, 1).fail())
  run reconnectCannotBurnAliasTest = first.then(restart).then(publish(2, 1)).then(stage(1))
    .then(burn(2, 3).fail())
  run secondOriginUsesSameBudgetTest = first.then(stage(1)).then(burn(1, 2)).then(publish(2, 2))
    .then(bindRequest(1, 1)).then(activate(1, 1)).then(offer(1, 0, 1, 2, true, true))
    .expect(safety and s.held == 6)

  run lateMutationCannotCommitAfterAbortAndRestageTest = init.then(stage(2))
    .then(abortMutation(1)).then(stage(2)).then(change(1).fail())
  run sameDurableImageCannotOpenAnotherCutTest = first.then(stage(2))
    .then(abortMutation(2)).then(stage(3)).then(change(3)).then(publish(2, 2).fail())

  action unsafeRehydrate(origin: int): bool = all {
    s.burns.get(origin) != 0, s.burns.get(origin) != s.owner, not(s.blocked),
    s' = {...s, burns: s.burns.set(origin, s.owner),
          requestBound: s.requestBound.union(Set(origin)), active: s.active.union(Set(origin))}
  }
  run rehydratingOldWindowActuallyDuplicatesOfferTest = first.then(restart).then(publish(2, 1))
    .then(unsafeRehydrate(0)).then(offer(2, 0, 2, 1, true, true))
    .expect(not(safety) and s.calls.get((0, 0)) == 2)

  action terminalOriginal = first.then(offer(0, 1, 1, 1, true, true))
    .then(offer(0, 2, 1, 1, true, true))
    .then(stage(4)).then(commitTerminal(0, 2)).then(publish(2, 2))
  run retiredUnknownWindowCannotSettleTest = first.then(restart).then(publish(2, 1))
    .then(stage(5)).then(applySettlement(2, 3, true).fail())
  run unverifiedMeterCannotSettleTest = terminalOriginal.then(stage(5))
    .then(applySettlement(0, 3, false).fail())
  run terminalSettlementAppliesOnceAcrossRestartTest = terminalOriginal.then(stage(5))
    .then(applySettlement(0, 3, true)).then(restart).then(publish(4, 3))
    .expect(safety and s.held == 0 and s.settled.contains(0))
    .then(stage(5)).then(applySettlement(2, 5, true).fail())

  action unsafeRollBackDurableBurn = all {
    s.blocked,
    s' = {...s, durable: 0, image: 0, burns: Map(0 -> 0, 1 -> 0),
          lost: Set(), history: Set(), held: 0}
  }
  run coherentStoreRollbackActuallyDuplicatesOfferTest = first.then(restart).then(unsafeRollBackDurableBurn)
    .then(publish(2, 0)).then(stage(1)).then(burn(2, 3)).then(publish(3, 1))
    .then(bindRequest(0, 2)).then(activate(0, 2)).then(offer(2, 0, 2, 1, true, true))
    .expect(not(safety) and s.calls.get((0, 0)) == 2)

  // Negative controls exhibit why shortcuts cannot serve as refinement.
  run versionOnlyPublicationCounterexampleTest = first.then(stage(2)).expect(
    s.image == s.durable and not(joins(s.blocked, s.image, s.durable)))
  run rehydrateVolatileCursorCounterexampleTest = first.then(restart).then(publish(2, 1))
    .expect(s.cursor.get(0) == 0 and s.calls.get((0, 0)) == 1 and s.burns.get(0) != s.owner)
  run lastAckDoesNotEstablishNoEffectCounterexampleTest = first.then(restart)
    .expect(s.calls.get((0, 0)) == 1 and s.held == 3)
}

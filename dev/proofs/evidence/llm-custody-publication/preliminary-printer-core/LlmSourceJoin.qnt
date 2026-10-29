module LlmSourceJoin {
  import LlmAdmissionFloor as F from "./LlmAdmissionFloor"
  import LlmAccountCommit as A from "./LlmAccountCommit"
  type Ticket = { proposal: F::Proposal, operation: int, intent: int, floor: F::Receipt, account: A::Image, journal: List[A::Record], worker: int, sourceGeneration: int, qualified: bool, sourceRevision: int }
  pure val empty = Rec("proposal", F::pAppend, "operation", 0, "intent", 0, "floor", Rec("revision", 1, "record", F::seed), "account", A::after0, "journal", List(), "worker", 0, "sourceGeneration", 0, "qualified", true, "sourceRevision", 0)
  action idle = actionAll(F::idle, assign(F::f, F::f))
  type Join = { revision: int, allows: bool, ticket: Ticket, haveTicket: bool, lastChecked: bool, attempted: Ticket }
  pure val initial = Rec("revision", 0, "allows", true, "ticket", empty, "haveTicket", false, "lastChecked", true, "attempted", empty)
  var j: Join
  def current = ((p) => Rec("proposal", p, "operation", field(p, "id"), "intent", field(p, "intent"), "floor", F::current, "account", field(A::a, "anchor"), "journal", field(A::a, "journal"), "worker", field(A::a, "epoch"), "sourceGeneration", field(A::a, "sourceGeneration"), "qualified", field(A::a, "qualified"), "sourceRevision", field(j, "revision")))
  val safety = and(field(j, "lastChecked"), F::safety)
  action init = actionAll(F::sealedRecovered, assign(j, initial))
  action appendInit = actionAll(F::qualifiedInit, assign(j, initial))
  action sourceChange = ((allow) => actionAll(idle, assign(j, with(with(j, "revision", iadd(field(j, "revision"), 1)), "allows", allow))))
  action propose = ((p) => actionAll(F::propose(p, true), assign(j, j)))
  action financialCommit = actionAll(F::financialCommit, assign(j, j))
  action query = actionAll(F::query(field(A::a, "epoch"), true), assign(j, j))
  action copies = actionAll(F::installCopies(true), assign(j, j))
  action project = actionAll(F::project(field(A::a, "epoch"), true), assign(j, j))
  action resolve = ((id) => actionAll(F::resolve(id), assign(j, j)))
  action loseReply = actionAll(F::loseReply, assign(j, j))
  action restart = actionAll(idle, assign(j, with(j, "haveTicket", false)))
  action restore = actionAll(F::restore(F::i0, Set(), Set()), assign(j, j))
  def joined = ((p) => and(field(j, "haveTicket"), eq(field(j, "ticket"), current(p))))
  action validate = ((p, authentic) => actionAll(authentic, F::qualified, field(j, "allows"), idle, assign(j, with(with(j, "ticket", current(p)), "haveTicket", true))))
  action publishCut = ((p) => actionAll(joined(p), field(j, "allows"), F::commitCut(p, true, true, true), assign(j, with(j, "haveTicket", false))))
  action publishAppend = ((p) => actionAll(joined(p), field(j, "allows"), F::commitAppend(p, true, true, true), assign(j, with(j, "haveTicket", false))))
  action publishFence = ((p) => actionAll(joined(p), field(j, "allows"), F::commitFence(p, true, true, true), assign(j, with(j, "haveTicket", false))))
  action staged = then(then(init, propose(F::pFence)), validate(F::pFence, true))
  action appendStaged = then(then(appendInit, propose(F::pAppend)), validate(F::pAppend, true))
  action earlyCutStaged = then(then(appendInit, propose(F::pEarlyCut)), validate(F::pEarlyCut, true))
  action unsafeFence = ((p) => actionAll(F::commitFence(p, true, true, true), assign(j, with(with(j, "lastChecked", and(joined(p), field(j, "allows"))), "attempted", current(p)))))
  action unsafeCut = ((p) => actionAll(F::commitCut(p, true, true, true), assign(j, with(with(j, "lastChecked", and(joined(p), field(j, "allows"))), "attempted", current(p)))))
  action unsafeDescriptor = ((p) => actionAll(idle, assign(j, with(with(j, "lastChecked", and(joined(p), field(j, "allows"))), "attempted", current(p)))))
  action accountChanged = then(staged, financialCommit)
  action sourceChanged = then(staged, sourceChange(false))
  action fenced = then(staged, publishFence(F::pFence))
  action appendPublished = then(appendStaged, publishAppend(F::pAppend))
  action step = nondet p = oneOf(Set(F::pAppend, F::pCut, F::pEarlyCut, F::pFence)) { actionAny(validate(p, true), sourceChange(true), sourceChange(false), publishCut(p), publishAppend(p), publishFence(p), propose(p), financialCommit, query, copies, project, resolve(field(p, "id")), loseReply, restart, restore) }
  action sourceReallowed = then(sourceChanged, sourceChange(true))
}

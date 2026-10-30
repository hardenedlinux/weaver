namespace Weaver.ControlActivation

/- Refinement premises: the authenticated source accurately projects native
   governor open-patterns; FFI borrows valid immutable buffers synchronously;
   Rust registration/consumption/release CAS is durable and non-rollback;
   fresh Cedar and fence checks serialize with actual effect admission.
   This proof does not establish C pointer validity, TLS, compiler correctness,
   Kubernetes identity issuance, filesystem durability, or provider exactly-once. -/

structure Gate where
  contractValid : Bool := false
  semanticReady : Bool := false
  nativeOpen : Bool := false
  ffiValidated : Bool := false
  registered : Bool := false
  committed : Bool := false
  acknowledged : Bool := false
  active : Bool := false

def Ready (g : Gate) : Prop := g.contractValid = true ∧ g.semanticReady = true ∧ g.nativeOpen = true ∧ g.ffiValidated = true ∧
  g.registered = true ∧ g.committed = true ∧ g.acknowledged = true
def GateSafe (g : Gate) : Prop := g.active = true → Ready g

inductive GateStep : Gate → Gate → Prop where
  | decode (g) (unregistered : g.registered = false) (valid : Bool) :
      GateStep g {g with contractValid := valid}
  | assess (g) (unregistered : g.registered = false) (ready : Bool) :
      GateStep g {g with semanticReady := ready}
  | select (g) (unregistered : g.registered = false) (admitted : Bool) :
      GateStep g {g with nativeOpen := admitted}
  | preflight (g) : GateStep g {g with ffiValidated := true}
  | register (g) (typed : g.contractValid = true) (semantic : g.semanticReady = true) (admitted : g.nativeOpen = true) :
      GateStep g {g with registered := true}
  | commit (g) (registered : g.registered = true) (typed : g.ffiValidated = true) : GateStep g {g with committed := true}
  | ack (g) (committed : g.committed = true) : GateStep g {g with acknowledged := true}
  | activate (g) (ready : Ready g) : GateStep g {g with active := true}
  | stop (g) : GateStep g {g with active := false}
  | observe (g) : GateStep g g

theorem gate_step_safe (initial : GateSafe g) (step : GateStep g h) : GateSafe h := by
  cases step <;> simp_all [GateSafe, Ready]

theorem active_requires_specific_contracts (safe : GateSafe g) (active : g.active = true) :
    g.contractValid = true := (safe active).1

structure Execution (Key : Type) where
  calls : Key → Nat
  spent : Key → Bool
  reserved : Key → Bool
  held : Nat
  revision : Nat
  permitRevision : Nat
  releases : List Bool

variable {Key : Type}

def ExecutionSafe (budget : Nat) (s : Execution Key) : Prop :=
  (∀ k, s.calls k ≤ 1 ∧ (s.calls k > 0 → s.spent k = true ∧ s.reserved k = true)) ∧
  s.held ≤ budget ∧ (∀ check ∈ s.releases, check = true)

inductive Step [DecidableEq Key] (budget : Nat) : (Gate × Execution Key) → (Gate × Execution Key) → Prop where
  | source (g h s) (gate : GateStep g h) : Step budget (g,s) (h,s)
  | reserve (g : Gate) (s : Execution Key) (key : Key) (cost : Nat) (active : g.active = true)
      (unused : s.reserved key = false) (positive : cost > 0) (capacity : s.held + cost ≤ budget) :
      Step budget (g,s) (g,{s with held := s.held + cost, reserved := fun k => if k = key then true else s.reserved k})
  | send (g : Gate) (s : Execution Key) (key : Key) (active : g.active = true)
      (fresh : s.permitRevision = s.revision) (unspent : s.spent key = false)
      (unused : s.calls key = 0) (reservation : s.reserved key = true) :
      Step budget (g,s) (g,{s with calls := (fun k => if k = key then 1 else s.calls k), spent := fun k => if k = key then true else s.spent k})
  | release (g s) (active : g.active = true) (fresh : s.permitRevision = s.revision)
      (cedar : Bool) (allowed : cedar = true) :
      Step budget (g,s) (g,{s with releases := s.releases ++ [cedar]})
  | publish (g s) : Step budget (g,s) (g,{s with revision := s.revision + 1})
  | recover (g s) : Step budget (g,s) ({g with active := false},s)
  | observe (g s) : Step budget (g,s) (g,s)

def Safe (budget : Nat) (s : Gate × Execution Key) : Prop := GateSafe s.1 ∧ ExecutionSafe budget s.2

theorem composition_step_safe [DecidableEq Key] {a b : Gate × Execution Key} (initial : Safe budget a) (step : Step budget a b) : Safe budget b := by
  rcases initial with ⟨gate, native⟩
  cases step with
  | source g h s transition => exact ⟨gate_step_safe gate transition,native⟩
  | reserve g s key cost active unused positive capacity =>
      refine ⟨gate,?_,capacity,native.2.2⟩
      intro k
      by_cases same : k = key
      · subst k
        have prior := native.1 key
        simp_all
      · simpa [same] using native.1 k
  | send g s key active fresh unspent unused reservation =>
      refine ⟨gate,?_,native.2.1,native.2.2⟩
      intro k
      by_cases same : k = key <;> simp_all
      exact native.1 k
  | release g s active fresh cedar allowed =>
      refine ⟨gate,native.1,native.2.1,?_⟩
      intro check member
      simp only [List.mem_append, List.mem_singleton] at member
      rcases member with prior | rfl
      · exact native.2.2 check prior
      · exact allowed
  | publish => exact ⟨gate,native⟩
  | recover => exact ⟨by simp [GateSafe],native⟩
  | observe => exact ⟨gate,native⟩

inductive Run [DecidableEq Key] (budget : Nat) : (Gate × Execution Key) → (Gate × Execution Key) → Prop where
  | refl (s) : Run budget s s
  | next : Run budget a b → Step budget b c → Run budget a c

theorem composition_run_safe [DecidableEq Key] {a b : Gate × Execution Key} (initial : Safe budget a) (run : Run budget a b) : Safe budget b := by
  induction run with
  | refl => exact initial
  | next history step ih => exact composition_step_safe ih step

theorem recovery_keeps_unknown_budget (g : Gate) (s : Execution Key) :
    (({g with active := false},s) : Gate × Execution Key).2.held = s.held := rfl

theorem old_receipt_is_not_current (s : Execution Key)
    (stale : s.permitRevision < s.revision) : s.permitRevision ≠ s.revision := by omega

theorem fresh_nonce_cannot_select_new_claim (canonical : Nonce → Key)
    (ledger : Key → Execution Root) (old fresh : Nonce)
    (bound : canonical old = canonical fresh) : ledger (canonical old) = ledger (canonical fresh) := by rw [bound]

#print axioms composition_run_safe
#print axioms recovery_keeps_unknown_budget
#print axioms old_receipt_is_not_current
#print axioms fresh_nonce_cannot_select_new_claim
end Weaver.ControlActivation

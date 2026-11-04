// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package WeaverZeroTrust {
    private import ScalarValues::*;
    doc /* Semantic refinement view of existing library and execution owners.
       These parts denote contract interpretations, not new services, ledgers,
       transport channels or proof-carrying send permits. Source ownership stays
       in WeaverExecution::CedarSecurityFrameworks and Project.sysml. */
    item def RequirementProjection;
    port def RequirementPort { out item constraintValue : RequirementProjection; }

    requirement def ZeroTrustContractRefinement {
        doc /* Retain the SPEC Framework, UsageControl and independently required
           POO parent contracts when interpreting actual Gateway effects. Cedar
           Allow alone is insufficient. Initial and ongoing use require current
           authoritative facts, original committed consumption, unknown retention
           and complete effect mediation. Obligations are witnessed transitions;
           recovery is not authorization and closure requires terminal AND accounted.
           The named Lean consumer is conditional and candidate-qualified; SDK
           structure or a diagram cannot discharge Rust/SQL/IO refinement premises. */
    }

    part def CoreContract {
        attribute displayName : String = "SPEC / Core contract";
        attribute responsibility : String = "Identity + authorization\nCurrent facts + not revoked\nConsumption + mediation\nUnknown exposure retained";
        attribute glyph : String = "obligation";
        attribute visualRole : String = "publication";
        doc /* CedarPooSpec.ZeroTrust.Model and Continuous: authenticated,
           authorized, currentAtUse, consumptionCommitted, unknownRetained,
           not revoked and mediated. Immutable generation-bound observations
           prevent equal attribute values from refreshing an old observation. */
        port requirements : RequirementPort;
    }
    part def UsageContract {
        attribute displayName : String = "SPEC / Usage control";
        attribute responsibility : String = "Initial + ongoing checks\nConditions + witnessed obligations\nMutation of actual state\nRecovery is not authorization\nClose = terminal + accounted";
        attribute glyph : String = "decision";
        attribute visualRole : String = "selection";
        doc /* CedarPooSpec.ZeroTrust.UsageControl: initial/ongoing authorization,
           conditions, witnessed obligation and mutation across actual states.
           Resume is the supplied recovery relation; close is terminal AND
           accounted. No identity authority, scheduler or persistence is supplied. */
        port core : ~RequirementPort;
        port requirements : RequirementPort;
    }
    part def ParentContract {
        attribute displayName : String = "SPEC / POO profiles";
        attribute responsibility : String = "Retain required parent\nConjoin selected projection\nStrengthen original scope";
        attribute glyph : String = "selection";
        attribute visualRole : String = "semantic";
        doc /* CedarPooSpec.ZeroTrust.ProfileObject.composeSessions retains both
           independently required parent and selected object projections. A root
           refinement or child-selected parent cannot substitute for that join. */
        port requirements : RequirementPort;
    }
    part def ApplicationInterpretation {
        attribute displayName : String = "Weaver / Interpretation";
        attribute responsibility : String = "Original task + profile\nShared budget + history\nCurrent facts + reviewed Policy\nHost materialization premises";
        attribute glyph : String = "model";
        attribute visualRole : String = "policy";
        doc /* CedarPooSpec.Gateway.ZeroTrust specializes the generic contracts.
           Weaver.ZeroTrustEnrichment applies existing SPEC laws to RuntimeView:
           original profile, context, commit floor, budget, history, pending
           publication and executor session. Host readers and native transition
           materialization remain explicit proof premises. Scheme owns task/profile
           semantics; Go carries authenticated candidates; Rust decides actual use. */
        port usage : ~RequirementPort;
        port parents : ~RequirementPort;
        port requirements : RequirementPort;
    }
    part def FinalEnforcement {
        attribute displayName : String = "Rust / Actual use";
        attribute responsibility : String = "Persist original consumption\nCurrent reviewed Policy + fence\nMediate final external bytes\nUnknown writes keep their hold";
        attribute glyph : String = "rust";
        attribute visualRole : String = "execution";
        doc /* Existing Rust ledger/policy/broker/executor roles discharge the
           application interpretation at final use, under the deciding transaction:
           current Cedar and fence, original claim, exact exposure and durable burn. Independent SPEC review producer qualification is bound to an immutable original publication and authority-owned parent. Deployment owns its verification key and exact independently qualified catalogue. The native transaction binds actual candidate, parent policy/schema and epoch; signature-only historical NoGain heads cannot activate. The current reviewed-head association is checked inside each existing effect transaction; registration and publication cannot send bytes. Authentication and actual semantic qualification remain separate premises.
           Recheck after waits; ambiguous or partial writes keep their hold. External
           identity/fact authority and independent rollback protection still need
           deployment evidence. A conditional proof is not a writable capability. */
        port requirements : ~RequirementPort;
    }
    part def ContractRefinement {
        attribute displayName : String = "Contract refinement / arrows carry requirements";
        attribute glyph : String = "model";
    }
    part refinement : ContractRefinement {
        part core : CoreContract;
        part usage : UsageContract;
        part parents : ParentContract;
        part application : ApplicationInterpretation;
        part enforcement : FinalEnforcement;
        connection core_requirements_to_usage_core connect core.requirements to usage.core;
        connection usage_requirements_to_application_usage connect usage.requirements to application.usage;
        connection parents_requirements_to_application_parents connect parents.requirements to application.parents;
        connection application_requirements_to_enforcement_requirements connect application.requirements to enforcement.requirements;
    }
}

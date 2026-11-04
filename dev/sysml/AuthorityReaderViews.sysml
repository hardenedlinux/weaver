// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverAuthorityReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Reading projections of the authority protocols in the LLM Gateway
       documentation. These parts name responsibilities and durable facts. */
    item def AuthorityFact;
    port def AuthorityFactPort { out item value : AuthorityFact; }

    part def attemptLedger_context {
        attribute displayName : String = "Task and catalog";
        attribute responsibility : String = "Eligible providers";
        attribute glyph : String = "routing";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def attemptLedger_allowance {
        attribute displayName : String = "Bound attempt";
        attribute responsibility : String = "Reserve scoped budget";
        attribute glyph : String = "budget";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def attemptLedger_consume {
        attribute displayName : String = "Consume once";
        attribute responsibility : String = "Original claim";
        attribute glyph : String = "claim";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def attemptLedger_queue {
        attribute displayName : String = "Durable queue";
        attribute responsibility : String = "Dispatch the committed attempt";
        attribute glyph : String = "ledger";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def attemptLedger_stream {
        attribute displayName : String = "Winner stream";
        attribute responsibility : String = "One bound source";
        attribute glyph : String = "stream";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def attemptLedger_usage {
        attribute displayName : String = "Usage evidence";
        attribute responsibility : String = "Settle the original hold";
        attribute glyph : String = "history";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part attemptLedgerBoundary {
        part context : attemptLedger_context;
        part allowance : attemptLedger_allowance;
        part consume : attemptLedger_consume;
        part queue : attemptLedger_queue;
        part stream : attemptLedger_stream;
        part usage : attemptLedger_usage;
        connection select connect context.outgoing to allowance.incoming;
        connection admit connect allowance.outgoing to consume.incoming;
        connection commit connect consume.outgoing to queue.incoming;
        connection winner connect queue.outgoing to stream.incoming;
        connection observe connect queue.outgoing to usage.incoming;
    }
    view attemptLedger {
        attribute mappedFile : String = "docs/10-19-llm-gateway/11-attempts-and-failover/11.02-attempt-ledger.d2";
        attribute displayTitle : String = "Select, reserve, then commit";
        attribute displaySubtitle : String = "Failover proposals keep the original task and allowance.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "Which original attempt may write?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Failover proposals keep the original task and allowance.";
        attribute designFocus : String = "queue";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose attemptLedgerBoundary::context;
        expose attemptLedgerBoundary::allowance;
        expose attemptLedgerBoundary::consume;
        expose attemptLedgerBoundary::queue;
        expose attemptLedgerBoundary::stream;
        expose attemptLedgerBoundary::usage;
        expose attemptLedgerBoundary::select;
        expose attemptLedgerBoundary::admit;
        expose attemptLedgerBoundary::commit;
        expose attemptLedgerBoundary::winner;
        expose attemptLedgerBoundary::observe;
        render asInterconnectionDiagram;
    }

    part def scope_original {
        attribute displayName : String = "Original contract";
        attribute responsibility : String = "Claim, profile and domains";
        attribute glyph : String = "claim";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def scope_child {
        attribute displayName : String = "Derived scope";
        attribute responsibility : String = "Keep required parents";
        attribute glyph : String = "policy";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def scope_wire {
        attribute displayName : String = "Provider request";
        attribute responsibility : String = "Exact body and target";
        attribute glyph : String = "message";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def scope_current {
        attribute displayName : String = "Current domain cut";
        attribute responsibility : String = "Budget and history";
        attribute glyph : String = "history";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def scope_gate {
        attribute displayName : String = "Actual-use gate";
        attribute responsibility : String = "Join scope and current cut";
        attribute glyph : String = "authorization";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def scope_result {
        attribute displayName : String = "Scoped outputs";
        attribute responsibility : String = "Document or tool proposal";
        attribute glyph : String = "provider";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part scopeBoundary {
        part original : scope_original;
        part child : scope_child;
        part wire : scope_wire;
        part current : scope_current;
        part gate : scope_gate;
        part result : scope_result;
        connection derive connect original.outgoing to child.incoming;
        connection encode connect child.outgoing to wire.incoming;
        connection resolve connect child.outgoing to current.incoming;
        connection bindBytes connect wire.outgoing to gate.incoming;
        connection recheck connect current.outgoing to gate.incoming;
        connection mediate connect gate.outgoing to result.incoming;
    }
    view scope {
        attribute mappedFile : String = "docs/10-19-llm-gateway/13-authoritative-scope/13.02-authoritative-scope.d2";
        attribute displayTitle : String = "Derive scope from the original task";
        attribute displaySubtitle : String = "The adapter encodes a request inside the admitted child scope.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "What prevents a provider adapter from inventing scope?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The adapter encodes a request inside the admitted child scope.";
        attribute designFocus : String = "gate";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose scopeBoundary::original;
        expose scopeBoundary::child;
        expose scopeBoundary::wire;
        expose scopeBoundary::current;
        expose scopeBoundary::gate;
        expose scopeBoundary::result;
        expose scopeBoundary::derive;
        expose scopeBoundary::encode;
        expose scopeBoundary::resolve;
        expose scopeBoundary::bindBytes;
        expose scopeBoundary::recheck;
        expose scopeBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def publication_review {
        attribute displayName : String = "Reviewed contract";
        attribute responsibility : String = "Subject, object and receipt";
        attribute glyph : String = "policy";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def publication_intent {
        attribute displayName : String = "Publication intent";
        attribute responsibility : String = "Keep exact operation";
        attribute glyph : String = "claim";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def publication_journal {
        attribute displayName : String = "Authority journal";
        attribute responsibility : String = "Commit original outcome";
        attribute glyph : String = "ledger";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def publication_fence {
        attribute displayName : String = "Current fence";
        attribute responsibility : String = "Read authoritative floor";
        attribute glyph : String = "authorization";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def publication_join {
        attribute displayName : String = "Recovery joinedEvidence";
        attribute responsibility : String = "Match decision and fence";
        attribute glyph : String = "recovery";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def publication_consume {
        attribute displayName : String = "Final consume";
        attribute responsibility : String = "Keep unresolved holds";
        attribute glyph : String = "budget";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part publicationBoundary {
        part review : publication_review;
        part intent : publication_intent;
        part journal : publication_journal;
        part fence : publication_fence;
        part joinedEvidence : publication_join;
        part consume : publication_consume;
        connection bindReview connect review.outgoing to intent.incoming;
        connection publish connect intent.outgoing to journal.incoming;
        connection readBack connect journal.outgoing to joinedEvidence.incoming;
        connection match connect fence.outgoing to joinedEvidence.incoming;
        connection admit connect joinedEvidence.outgoing to consume.incoming;
    }
    view publication {
        attribute mappedFile : String = "docs/10-19-llm-gateway/14-registry-publication/14.02-registry-publication.d2";
        attribute displayTitle : String = "Publish an exact reviewed profile";
        attribute displaySubtitle : String = "A lost reply is recovered from the authoritative decision.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "When does a reviewed profile become usable?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A lost reply is recovered from the authoritative decision.";
        attribute designFocus : String = "joinedEvidence";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose publicationBoundary::review;
        expose publicationBoundary::intent;
        expose publicationBoundary::journal;
        expose publicationBoundary::fence;
        expose publicationBoundary::joinedEvidence;
        expose publicationBoundary::consume;
        expose publicationBoundary::bindReview;
        expose publicationBoundary::publish;
        expose publicationBoundary::readBack;
        expose publicationBoundary::match;
        expose publicationBoundary::admit;
        render asInterconnectionDiagram;
    }

    part def recoveryCAS_image {
        attribute displayName : String = "Recovery image";
        attribute responsibility : String = "Exact operation and cut";
        attribute glyph : String = "history";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def recoveryCAS_prepare {
        attribute displayName : String = "Prepared proposal";
        attribute responsibility : String = "Retain original binding";
        attribute glyph : String = "message";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def recoveryCAS_fence {
        attribute displayName : String = "Current fence";
        attribute responsibility : String = "Owner and generation";
        attribute glyph : String = "authorization";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def recoveryCAS_decide {
        attribute displayName : String = "Deciding CAS";
        attribute responsibility : String = "Compare the whole cut";
        attribute glyph : String = "ledger";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def recoveryCAS_hold {
        attribute displayName : String = "Unresolved result";
        attribute responsibility : String = "Read original outcome";
        attribute glyph : String = "unknown";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def recoveryCAS_consume {
        attribute displayName : String = "Committed result";
        attribute responsibility : String = "Current Policy still applies";
        attribute glyph : String = "policy";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part recoveryCASBoundary {
        part image : recoveryCAS_image;
        part prepare : recoveryCAS_prepare;
        part fence : recoveryCAS_fence;
        part decisionCAS : recoveryCAS_decide;
        part hold : recoveryCAS_hold;
        part consume : recoveryCAS_consume;
        connection prepareImage connect image.outgoing to prepare.incoming;
        connection submit connect prepare.outgoing to decisionCAS.incoming;
        connection compare connect fence.outgoing to decisionCAS.incoming;
        connection unknown connect decisionCAS.outgoing to hold.incoming;
        connection committed connect decisionCAS.outgoing to consume.incoming;
    }
    view recoveryCAS {
        attribute mappedFile : String = "docs/10-19-llm-gateway/15-recovery-cas/15.02-recovery-cas.d2";
        attribute displayTitle : String = "Recheck the recovered cut at CAS";
        attribute displaySubtitle : String = "Preparation carries the original binding. The deciding transaction compares it again.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "Can a recovered read authorize a later consume?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Preparation carries the original binding. The deciding transaction compares it again.";
        attribute designFocus : String = "decisionCAS";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose recoveryCASBoundary::image;
        expose recoveryCASBoundary::prepare;
        expose recoveryCASBoundary::fence;
        expose recoveryCASBoundary::decisionCAS;
        expose recoveryCASBoundary::hold;
        expose recoveryCASBoundary::consume;
        expose recoveryCASBoundary::prepare;
        expose recoveryCASBoundary::submit;
        expose recoveryCASBoundary::compare;
        expose recoveryCASBoundary::unknown;
        expose recoveryCASBoundary::committed;
        render asInterconnectionDiagram;
    }

    part def canonical_protocol {
        attribute displayName : String = "Protocol identity";
        attribute responsibility : String = "MCP, A2A or ACP";
        attribute glyph : String = "message";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def canonical_alias {
        attribute displayName : String = "Namespaced aliasBinding";
        attribute responsibility : String = "Bind to canonical origin";
        attribute glyph : String = "routing";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def canonical_original {
        attribute displayName : String = "Original origin";
        attribute responsibility : String = "Keep claim and domains";
        attribute glyph : String = "claim";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def canonical_recover {
        attribute displayName : String = "Qualified lookup";
        attribute responsibility : String = "Join projection and fence";
        attribute glyph : String = "recovery";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def canonical_gate {
        attribute displayName : String = "Final consume";
        attribute responsibility : String = "Check current scope";
        attribute glyph : String = "authorization";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def canonical_hold {
        attribute displayName : String = "Unknown outcome";
        attribute responsibility : String = "Keep the original hold";
        attribute glyph : String = "unknown";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part canonicalBoundary {
        part protocol : canonical_protocol;
        part aliasBinding : canonical_alias;
        part original : canonical_original;
        part recover : canonical_recover;
        part gate : canonical_gate;
        part hold : canonical_hold;
        connection resolve connect protocol.outgoing to aliasBinding.incoming;
        connection origin connect aliasBinding.outgoing to original.incoming;
        connection readBack connect original.outgoing to recover.incoming;
        connection current connect recover.outgoing to gate.incoming;
        connection unknown connect recover.outgoing to hold.incoming;
    }
    view canonical {
        attribute mappedFile : String = "docs/10-19-llm-gateway/18-canonical-registry/18.02-canonical-registry.d2";
        attribute displayTitle : String = "Resolve aliases to one original task";
        attribute displaySubtitle : String = "Reconnects look up the same origin before any new progress.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "What does a resumed protocol identifier resolve to?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Reconnects look up the same origin before any new progress.";
        attribute designFocus : String = "original";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose canonicalBoundary::protocol;
        expose canonicalBoundary::aliasBinding;
        expose canonicalBoundary::original;
        expose canonicalBoundary::recover;
        expose canonicalBoundary::gate;
        expose canonicalBoundary::hold;
        expose canonicalBoundary::resolve;
        expose canonicalBoundary::origin;
        expose canonicalBoundary::readBack;
        expose canonicalBoundary::current;
        expose canonicalBoundary::unknown;
        render asInterconnectionDiagram;
    }

    part def multiKey_origin {
        attribute displayName : String = "Original origin";
        attribute responsibility : String = "Stable canonical key";
        attribute glyph : String = "claim";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def multiKey_aliases {
        attribute displayName : String = "Alias keys";
        attribute responsibility : String = "Current bindings";
        attribute glyph : String = "routing";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def multiKey_owner {
        attribute displayName : String = "Current owner";
        attribute responsibility : String = "Fence and source head";
        attribute glyph : String = "authorization";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def multiKey_decide {
        attribute displayName : String = "Registry CAS";
        attribute responsibility : String = "Compare all original keys";
        attribute glyph : String = "ledger";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def multiKey_projection {
        attribute displayName : String = "Committed projection";
        attribute responsibility : String = "Publish exact decision";
        attribute glyph : String = "publication";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part def multiKey_hold {
        attribute displayName : String = "Unknown outcome";
        attribute responsibility : String = "Recover without replay";
        attribute glyph : String = "unknown";
        port incoming : ~AuthorityFactPort;
        port outgoing : AuthorityFactPort;
    }
    part multiKeyBoundary {
        part origin : multiKey_origin;
        part aliases : multiKey_aliases;
        part owner : multiKey_owner;
        part decisionCAS : multiKey_decide;
        part projection : multiKey_projection;
        part hold : multiKey_hold;
        connection original connect origin.outgoing to decisionCAS.incoming;
        connection aliasesCurrent connect aliases.outgoing to decisionCAS.incoming;
        connection ownerCurrent connect owner.outgoing to decisionCAS.incoming;
        connection project connect decisionCAS.outgoing to projection.incoming;
        connection unresolved connect decisionCAS.outgoing to hold.incoming;
    }
    view multiKey {
        attribute mappedFile : String = "docs/10-19-llm-gateway/19-multi-key-registry/19.02-multi-key-registry.d2";
        attribute displayTitle : String = "Commit the complete registry read set";
        attribute displaySubtitle : String = "An owner change must not turn a partial projection into authority.";
        attribute displayEyebrow : String = "WEAVER / ORIGINAL AUTHORITY";
        attribute readerQuestion : String = "How does one decision bind multiple registry keys?";
        attribute designAudience : String = "Gateway reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "An owner change must not turn a partial projection into authority.";
        attribute designFocus : String = "decisionCAS";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose multiKeyBoundary::origin;
        expose multiKeyBoundary::aliases;
        expose multiKeyBoundary::owner;
        expose multiKeyBoundary::decisionCAS;
        expose multiKeyBoundary::projection;
        expose multiKeyBoundary::hold;
        expose multiKeyBoundary::original;
        expose multiKeyBoundary::aliasesCurrent;
        expose multiKeyBoundary::ownerCurrent;
        expose multiKeyBoundary::project;
        expose multiKeyBoundary::unresolved;
        render asInterconnectionDiagram;
    }
}

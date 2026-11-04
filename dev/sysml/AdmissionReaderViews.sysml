// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverAdmissionReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Reader projections for source custody, enrollment and routine use. */
    item def AdmissionFact;
    port def FactPort { out item value : AdmissionFact; }
    part def ReaderNode {
        port incoming : ~FactPort;
        port outgoing : FactPort;
    }
    part def sourceJoin_image :> ReaderNode {
        attribute displayName : String = "Admission image";
        attribute responsibility : String = "Original tail and owner";
        attribute glyph : String = "ledger";
    }
    part def sourceJoin_account :> ReaderNode {
        attribute displayName : String = "Current account";
        attribute responsibility : String = "Qualification and balance";
        attribute glyph : String = "budget";
    }
    part def sourceJoin_policyState :> ReaderNode {
        attribute displayName : String = "Source and Policy";
        attribute responsibility : String = "History and source revision";
        attribute glyph : String = "policy";
    }
    part def sourceJoin_publishFloor :> ReaderNode {
        attribute displayName : String = "Final floor CAS";
        attribute responsibility : String = "Compare the whole join";
        attribute glyph : String = "authorization";
    }
    part sourceJoinBoundary {
        part p_image : sourceJoin_image;
        part p_account : sourceJoin_account;
        part p_policyState : sourceJoin_policyState;
        part p_publishFloor : sourceJoin_publishFloor;
        connection floorParent connect p_image.outgoing to p_publishFloor.incoming;
        connection currentAccount connect p_account.outgoing to p_publishFloor.incoming;
        connection sourceRevision connect p_policyState.outgoing to p_publishFloor.incoming;
    }
    view sourceJoin {
        attribute mappedFile : String = "docs/40-49-admission-coordination/40-source-join/40.02-source-join.d2";
        attribute displayTitle : String = "Join live authority at publication";
        attribute displaySubtitle : String = "An unchanged floor parent cannot validate stale account or Policy state.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "Which state must the final floor CAS compare?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "An unchanged floor parent cannot validate stale account or Policy state.";
        attribute designFocus : String = "p_publishFloor";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose sourceJoinBoundary::p_image;
        expose sourceJoinBoundary::p_account;
        expose sourceJoinBoundary::p_policyState;
        expose sourceJoinBoundary::p_publishFloor;
        expose sourceJoinBoundary::floorParent;
        expose sourceJoinBoundary::currentAccount;
        expose sourceJoinBoundary::sourceRevision;
        render asInterconnectionDiagram;
    }

    part def sourceCustody_ticket :> ReaderNode {
        attribute displayName : String = "Recovered join";
        attribute responsibility : String = "Original operation";
        attribute glyph : String = "history";
    }
    part def sourceCustody_custody :> ReaderNode {
        attribute displayName : String = "Current custody";
        attribute responsibility : String = "Holder and fence";
        attribute glyph : String = "authentication";
    }
    part def sourceCustody_cas :> ReaderNode {
        attribute displayName : String = "Determining CAS";
        attribute responsibility : String = "Verify both live bindings";
        attribute glyph : String = "authorization";
    }
    part def sourceCustody_deny :> ReaderNode {
        attribute displayName : String = "Stale holder";
        attribute responsibility : String = "Refuse publication";
        attribute glyph : String = "unknown";
    }
    part sourceCustodyBoundary {
        part p_ticket : sourceCustody_ticket;
        part p_custody : sourceCustody_custody;
        part p_cas : sourceCustody_cas;
        part p_deny : sourceCustody_deny;
        connection rejoin connect p_ticket.outgoing to p_cas.incoming;
        connection checkHolder connect p_custody.outgoing to p_cas.incoming;
        connection staleFence connect p_cas.outgoing to p_deny.incoming;
    }
    view sourceCustody {
        attribute mappedFile : String = "docs/40-49-admission-coordination/41-source-custody/41.02-source-custody.d2";
        attribute displayTitle : String = "Reject the old custody permit";
        attribute displaySubtitle : String = "A fresh observation cannot revive a stale custody permit.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "What happens after custody transfers?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A fresh observation cannot revive a stale custody permit.";
        attribute designFocus : String = "p_cas";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose sourceCustodyBoundary::p_ticket;
        expose sourceCustodyBoundary::p_custody;
        expose sourceCustodyBoundary::p_cas;
        expose sourceCustodyBoundary::p_deny;
        expose sourceCustodyBoundary::rejoin;
        expose sourceCustodyBoundary::checkHolder;
        expose sourceCustodyBoundary::staleFence;
        render asInterconnectionDiagram;
    }

    part def custodyPublication_transfer :> ReaderNode {
        attribute displayName : String = "Custody transfer";
        attribute responsibility : String = "Replace holder and fence";
        attribute glyph : String = "authentication";
    }
    part def custodyPublication_admission :> ReaderNode {
        attribute displayName : String = "Floor admission";
        attribute responsibility : String = "Bind exact original outcome";
        attribute glyph : String = "publication";
    }
    part def custodyPublication_journal :> ReaderNode {
        attribute displayName : String = "Authority journal";
        attribute responsibility : String = "Compare one current head";
        attribute glyph : String = "ledger";
    }
    part def custodyPublication_projection :> ReaderNode {
        attribute displayName : String = "Committed prefix";
        attribute responsibility : String = "Project downstream state";
        attribute glyph : String = "history";
    }
    part custodyPublicationBoundary {
        part p_transfer : custodyPublication_transfer;
        part p_admission : custodyPublication_admission;
        part p_journal : custodyPublication_journal;
        part p_projection : custodyPublication_projection;
        connection orderTransfer connect p_transfer.outgoing to p_journal.incoming;
        connection orderAdmission connect p_admission.outgoing to p_journal.incoming;
        connection materialize connect p_journal.outgoing to p_projection.incoming;
    }
    view custodyPublication {
        attribute mappedFile : String = "docs/40-49-admission-coordination/42-custody-publication/42.02-custody-publication.d2";
        attribute displayTitle : String = "Use one deciding journal";
        attribute displaySubtitle : String = "Transfer and admission are separate events in one ordering domain.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "Where are transfer and floor publication ordered?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Transfer and admission are separate events in one ordering domain.";
        attribute designFocus : String = "p_journal";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose custodyPublicationBoundary::p_transfer;
        expose custodyPublicationBoundary::p_admission;
        expose custodyPublicationBoundary::p_journal;
        expose custodyPublicationBoundary::p_projection;
        expose custodyPublicationBoundary::orderTransfer;
        expose custodyPublicationBoundary::orderAdmission;
        expose custodyPublicationBoundary::materialize;
        render asInterconnectionDiagram;
    }

    part def callerCustody_caller :> ReaderNode {
        attribute displayName : String = "Authenticated caller";
        attribute responsibility : String = "Incarnation and key";
        attribute glyph : String = "authentication";
    }
    part def callerCustody_proof :> ReaderNode {
        attribute displayName : String = "Signed transcript";
        attribute responsibility : String = "Exact publish command";
        attribute glyph : String = "claim";
    }
    part def callerCustody_current :> ReaderNode {
        attribute displayName : String = "Current capability";
        attribute responsibility : String = "Holder and fence";
        attribute glyph : String = "policy";
    }
    part def callerCustody_guard :> ReaderNode {
        attribute displayName : String = "Rust publish guard";
        attribute responsibility : String = "Verify caller and custody";
        attribute glyph : String = "authorization";
    }
    part callerCustodyBoundary {
        part p_caller : callerCustody_caller;
        part p_proof : callerCustody_proof;
        part p_current : callerCustody_current;
        part p_guard : callerCustody_guard;
        connection bindCaller connect p_caller.outgoing to p_guard.incoming;
        connection verifyPossession connect p_proof.outgoing to p_guard.incoming;
        connection compareFence connect p_current.outgoing to p_guard.incoming;
    }
    view callerCustody {
        attribute mappedFile : String = "docs/40-49-admission-coordination/43-caller-custody/43.02-caller-custody.d2";
        attribute displayTitle : String = "Bind publication to the caller";
        attribute displaySubtitle : String = "Proof of possession and current custody are checked together.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "Why does matching the current fence not authenticate the caller?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Proof of possession and current custody are checked together.";
        attribute designFocus : String = "p_guard";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose callerCustodyBoundary::p_caller;
        expose callerCustodyBoundary::p_proof;
        expose callerCustodyBoundary::p_current;
        expose callerCustodyBoundary::p_guard;
        expose callerCustodyBoundary::bindCaller;
        expose callerCustodyBoundary::verifyPossession;
        expose callerCustodyBoundary::compareFence;
        render asInterconnectionDiagram;
    }

    part def incarnationIssuance_launch :> ReaderNode {
        attribute displayName : String = "Authorized launch";
        attribute responsibility : String = "Original task assignment";
        attribute glyph : String = "claim";
    }
    part def incarnationIssuance_bootstrap :> ReaderNode {
        attribute displayName : String = "Bootstrap proof";
        attribute responsibility : String = "Possess committed key";
        attribute glyph : String = "authentication";
    }
    part def incarnationIssuance_issuance :> ReaderNode {
        attribute displayName : String = "Pending issuance";
        attribute responsibility : String = "Recover exact result";
        attribute glyph : String = "ledger";
    }
    part def incarnationIssuance_activate :> ReaderNode {
        attribute displayName : String = "Activation CAS";
        attribute responsibility : String = "Join current custody";
        attribute glyph : String = "authorization";
    }
    part incarnationIssuanceBoundary {
        part p_launch : incarnationIssuance_launch;
        part p_bootstrap : incarnationIssuance_bootstrap;
        part p_issuance : incarnationIssuance_issuance;
        part p_activate : incarnationIssuance_activate;
        connection bindKey connect p_launch.outgoing to p_bootstrap.incoming;
        connection issue connect p_bootstrap.outgoing to p_issuance.incoming;
        connection activateCurrent connect p_issuance.outgoing to p_activate.incoming;
    }
    view incarnationIssuance {
        attribute mappedFile : String = "docs/40-49-admission-coordination/44-incarnation-issuance/44.02-incarnation-issuance.d2";
        attribute displayTitle : String = "Issue before activating custody";
        attribute displaySubtitle : String = "A launch assignment binds the key before the activation CAS.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "How does a new incarnation prove its key before activation?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A launch assignment binds the key before the activation CAS.";
        attribute designFocus : String = "p_activate";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose incarnationIssuanceBoundary::p_launch;
        expose incarnationIssuanceBoundary::p_bootstrap;
        expose incarnationIssuanceBoundary::p_issuance;
        expose incarnationIssuanceBoundary::p_activate;
        expose incarnationIssuanceBoundary::bindKey;
        expose incarnationIssuanceBoundary::issue;
        expose incarnationIssuanceBoundary::activateCurrent;
        render asInterconnectionDiagram;
    }

    part def bootstrapInvitation_beneficiary :> ReaderNode {
        attribute displayName : String = "Beneficiary assignment";
        attribute responsibility : String = "Commit the public key";
        attribute glyph : String = "authentication";
    }
    part def bootstrapInvitation_invitation :> ReaderNode {
        attribute displayName : String = "Exact invitation";
        attribute responsibility : String = "Bind original launch";
        attribute glyph : String = "claim";
    }
    part def bootstrapInvitation_consume :> ReaderNode {
        attribute displayName : String = "One authority event";
        attribute responsibility : String = "Consume and issue once";
        attribute glyph : String = "ledger";
    }
    part def bootstrapInvitation_pending :> ReaderNode {
        attribute displayName : String = "Pending issuance";
        attribute responsibility : String = "Activate at a later CAS";
        attribute glyph : String = "publication";
    }
    part bootstrapInvitationBoundary {
        part p_beneficiary : bootstrapInvitation_beneficiary;
        part p_invitation : bootstrapInvitation_invitation;
        part p_consume : bootstrapInvitation_consume;
        part p_pending : bootstrapInvitation_pending;
        connection bindKey connect p_beneficiary.outgoing to p_invitation.incoming;
        connection consumeExact connect p_invitation.outgoing to p_consume.incoming;
        connection recordOutcome connect p_consume.outgoing to p_pending.incoming;
    }
    view bootstrapInvitation {
        attribute mappedFile : String = "docs/40-49-admission-coordination/45-bootstrap-invitation/45.02-bootstrap-invitation.d2";
        attribute displayTitle : String = "Consume a key-bound invitation";
        attribute displaySubtitle : String = "The authoritative producer freezes the beneficiary before delivery.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "What prevents a forwarded invitation from enrolling another key?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The authoritative producer freezes the beneficiary before delivery.";
        attribute designFocus : String = "p_consume";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose bootstrapInvitationBoundary::p_beneficiary;
        expose bootstrapInvitationBoundary::p_invitation;
        expose bootstrapInvitationBoundary::p_consume;
        expose bootstrapInvitationBoundary::p_pending;
        expose bootstrapInvitationBoundary::bindKey;
        expose bootstrapInvitationBoundary::consumeExact;
        expose bootstrapInvitationBoundary::recordOutcome;
        render asInterconnectionDiagram;
    }

    part def beneficiaryRegistration_root :> ReaderNode {
        attribute displayName : String = "Enrollment root";
        attribute responsibility : String = "Original task and rendezvous";
        attribute glyph : String = "claim";
    }
    part def beneficiaryRegistration_principal :> ReaderNode {
        attribute displayName : String = "Enrollment proof";
        attribute responsibility : String = "Authorized launch principal";
        attribute glyph : String = "policy";
    }
    part def beneficiaryRegistration_keyProof :> ReaderNode {
        attribute displayName : String = "New-key proof";
        attribute responsibility : String = "Possess beneficiary key";
        attribute glyph : String = "authentication";
    }
    part def beneficiaryRegistration_register :> ReaderNode {
        attribute displayName : String = "First registration";
        attribute responsibility : String = "Bind the exact transcript";
        attribute glyph : String = "ledger";
    }
    part beneficiaryRegistrationBoundary {
        part p_root : beneficiaryRegistration_root;
        part p_principal : beneficiaryRegistration_principal;
        part p_keyProof : beneficiaryRegistration_keyProof;
        part p_register : beneficiaryRegistration_register;
        connection bindLaunch connect p_root.outgoing to p_register.incoming;
        connection verifyEntitlement connect p_principal.outgoing to p_register.incoming;
        connection verifyPossession connect p_keyProof.outgoing to p_register.incoming;
    }
    view beneficiaryRegistration {
        attribute mappedFile : String = "docs/40-49-admission-coordination/46-beneficiary-registration/46.02-beneficiary-registration.d2";
        attribute displayTitle : String = "Join two proofs on one transcript";
        attribute displaySubtitle : String = "Enrollment authority and possession of the new key must agree.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "What qualifies first registration of the beneficiary key?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Enrollment authority and possession of the new key must agree.";
        attribute designFocus : String = "p_register";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose beneficiaryRegistrationBoundary::p_root;
        expose beneficiaryRegistrationBoundary::p_principal;
        expose beneficiaryRegistrationBoundary::p_keyProof;
        expose beneficiaryRegistrationBoundary::p_register;
        expose beneficiaryRegistrationBoundary::bindLaunch;
        expose beneficiaryRegistrationBoundary::verifyEntitlement;
        expose beneficiaryRegistrationBoundary::verifyPossession;
        render asInterconnectionDiagram;
    }

    part def enrollmentCredential_subject :> ReaderNode {
        attribute displayName : String = "Authenticated subject";
        attribute responsibility : String = "Independent identity";
        attribute glyph : String = "authentication";
    }
    part def enrollmentCredential_assignment :> ReaderNode {
        attribute displayName : String = "Producer assignment";
        attribute responsibility : String = "Original task and key";
        attribute glyph : String = "claim";
    }
    part def enrollmentCredential_credential :> ReaderNode {
        attribute displayName : String = "Enrollment credential";
        attribute responsibility : String = "Issue the exact binding";
        attribute glyph : String = "publication";
    }
    part def enrollmentCredential_readback :> ReaderNode {
        attribute displayName : String = "Lost reply";
        attribute responsibility : String = "Recover original issuance";
        attribute glyph : String = "recovery";
    }
    part enrollmentCredentialBoundary {
        part p_subject : enrollmentCredential_subject;
        part p_assignment : enrollmentCredential_assignment;
        part p_credential : enrollmentCredential_credential;
        part p_readback : enrollmentCredential_readback;
        connection authenticate connect p_subject.outgoing to p_assignment.incoming;
        connection issue connect p_assignment.outgoing to p_credential.incoming;
        connection readOriginal connect p_readback.outgoing to p_credential.incoming;
    }
    view enrollmentCredential {
        attribute mappedFile : String = "docs/40-49-admission-coordination/47-enrollment-credential/47.02-enrollment-credential.d2";
        attribute displayTitle : String = "Start with an independent subject";
        attribute displaySubtitle : String = "The producer binds the pre-existing subject to the original launch.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "Who can issue the first enrollment credential?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The producer binds the pre-existing subject to the original launch.";
        attribute designFocus : String = "p_credential";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose enrollmentCredentialBoundary::p_subject;
        expose enrollmentCredentialBoundary::p_assignment;
        expose enrollmentCredentialBoundary::p_credential;
        expose enrollmentCredentialBoundary::p_readback;
        expose enrollmentCredentialBoundary::authenticate;
        expose enrollmentCredentialBoundary::issue;
        expose enrollmentCredentialBoundary::readOriginal;
        render asInterconnectionDiagram;
    }

    part def subjectAuthority_tenant :> ReaderNode {
        attribute displayName : String = "Tenant trust policy";
        attribute responsibility : String = "Issuer and purpose";
        attribute glyph : String = "policy";
    }
    part def subjectAuthority_directory :> ReaderNode {
        attribute displayName : String = "Identity authority";
        attribute responsibility : String = "Authenticate the subject";
        attribute glyph : String = "authentication";
    }
    part def subjectAuthority_mapping :> ReaderNode {
        attribute displayName : String = "Stable subject mapping";
        attribute responsibility : String = "Bind tenant subject";
        attribute glyph : String = "claim";
    }
    part def subjectAuthority_producer :> ReaderNode {
        attribute displayName : String = "Producer assignment";
        attribute responsibility : String = "Publish original plan";
        attribute glyph : String = "publication";
    }
    part subjectAuthorityBoundary {
        part p_tenant : subjectAuthority_tenant;
        part p_directory : subjectAuthority_directory;
        part p_mapping : subjectAuthority_mapping;
        part p_producer : subjectAuthority_producer;
        connection configureTrust connect p_tenant.outgoing to p_mapping.incoming;
        connection resolveSubject connect p_directory.outgoing to p_mapping.incoming;
        connection assignOriginal connect p_mapping.outgoing to p_producer.incoming;
    }
    view subjectAuthority {
        attribute mappedFile : String = "docs/40-49-admission-coordination/48-subject-authority/48.02-subject-authority.d2";
        attribute displayTitle : String = "Configure the subject authority";
        attribute displaySubtitle : String = "Tenant policy selects issuers, purpose and stable subject mapping.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "Where does the enterprise subject binding come from?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Tenant policy selects issuers, purpose and stable subject mapping.";
        attribute designFocus : String = "p_mapping";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose subjectAuthorityBoundary::p_tenant;
        expose subjectAuthorityBoundary::p_directory;
        expose subjectAuthorityBoundary::p_mapping;
        expose subjectAuthorityBoundary::p_producer;
        expose subjectAuthorityBoundary::configureTrust;
        expose subjectAuthorityBoundary::resolveSubject;
        expose subjectAuthorityBoundary::assignOriginal;
        render asInterconnectionDiagram;
    }

    part def routineRouting_configuration :> ReaderNode {
        attribute displayName : String = "Routine config";
        attribute responsibility : String = "Scheme or JSON/YAML";
        attribute glyph : String = "message";
        attribute illustration : String = "task-contract";
    }
    part def routineRouting_program :> ReaderNode {
        attribute displayName : String = "Admitted program";
        attribute responsibility : String = "Typed steps and obligations";
        attribute glyph : String = "routine";
    }
    part def routineRouting_catalog :> ReaderNode {
        attribute displayName : String = "Capability catalog";
        attribute responsibility : String = "Models, tools and agents";
        attribute glyph : String = "catalog";
    }
    part def routineRouting_route :> ReaderNode {
        attribute displayName : String = "Bound route";
        attribute responsibility : String = "Choose one eligible target";
        attribute glyph : String = "routing";
        attribute illustration : String = "route-choice";
    }
    part def routineRouting_gate :> ReaderNode {
        attribute displayName : String = "Actual-use guard";
        attribute responsibility : String = "Enforce current authority";
        attribute glyph : String = "authorization";
        attribute illustration : String = "permission-check";
    }
    part routineRoutingBoundary {
        part p_configuration : routineRouting_configuration;
        part p_program : routineRouting_program;
        part p_catalog : routineRouting_catalog;
        part p_route : routineRouting_route;
        part p_gate : routineRouting_gate;
        connection admit connect p_configuration.outgoing to p_program.incoming;
        connection requirements connect p_program.outgoing to p_route.incoming;
        connection capabilities connect p_catalog.outgoing to p_route.incoming;
        connection propose connect p_route.outgoing to p_gate.incoming;
    }
    view routineRouting {
        attribute mappedFile : String = "docs/40-49-admission-coordination/49-routine-routing-config/49.02-routine-routing-config.d2";
        attribute displayTitle : String = "Define work, then route one step";
        attribute displaySubtitle : String = "Scheme and JSON or YAML produce one admitted semantic program.";
        attribute displayEyebrow : String = "WEAVER / ADMISSION AND CUSTODY";
        attribute readerQuestion : String = "How does one routine choose a permitted binding?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Scheme and JSON or YAML produce one admitted semantic program.";
        attribute designFocus : String = "p_route";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"p_configuration\",\"p_program\",\"p_catalog\"],[\"p_route\",\"p_gate\"]]";
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose routineRoutingBoundary::p_configuration;
        expose routineRoutingBoundary::p_program;
        expose routineRoutingBoundary::p_catalog;
        expose routineRoutingBoundary::p_route;
        expose routineRoutingBoundary::p_gate;
        expose routineRoutingBoundary::admit;
        expose routineRoutingBoundary::requirements;
        expose routineRoutingBoundary::capabilities;
        expose routineRoutingBoundary::propose;
        render asInterconnectionDiagram;
    }
}

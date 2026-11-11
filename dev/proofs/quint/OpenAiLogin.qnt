// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module OpenAiLogin {
  type Identity = {issuer:int,audience:int,subject:int,nonce:int,signature:bool,permission:bool,fresh:bool}
  type Receipt = {client:int,subject:int,nonce:int,identity:Identity,at:int,deadline:int}
  type Registration = {client:int,subject:int,host:int,request:int,nonce:int,
    pending:bool,posted:bool,active:bool,lastLogout:int,revocation:int,
    clock:int,deadline:int,receipts:List[Receipt]}
  var r:Registration
  pure val initial = {client:0,subject:-1,host:17,request:0,nonce:0,
    pending:false,posted:false,active:false,lastLogout:0,revocation:0,clock:0,deadline:0,receipts:[]}
  pure def good(client:int,nonce:int,subject:int):Identity =
    {issuer:0,audience:client,subject:subject,nonce:nonce,signature:true,permission:true,fresh:true}
  action init = r'=initial
  action begin = r'=r.with("request",r.client).with("nonce",r.nonce+1)
    .with("pending",true).with("posted",false).with("deadline",r.clock+2)
  action callback(client:int):bool = all {r.pending,not(r.posted),r.clock<r.deadline,
    if (r.request==0) client>0 else client==0 or client==r.request,
    r'=r.with("client",if (r.request==0) client else r.request)
      .with("posted",true).with("active",false)}
  action invalidGrant = all {r.posted,r'=r.with("pending",false).with("posted",false)}
  pure def bound(identity:Identity,client:int,nonce:int,subject:int):bool =
    identity.signature and identity.issuer==0 and identity.audience==client and
    identity.nonce==nonce and identity.permission and identity.subject==subject and subject>0 and identity.fresh
  action activate(identity:Identity):bool = all {r.pending,r.posted,r.clock<r.deadline,
    bound(identity,r.client,r.nonce,identity.subject),
    r.subject == -1 or r.subject==identity.subject,
    r'=r.with("subject",identity.subject).with("pending",false).with("posted",false)
      .with("active",true).with("receipts",r.receipts.append(
        {client:r.client,subject:identity.subject,nonce:r.nonce,identity:identity,
          at:r.clock,deadline:r.deadline}))}
  action logout = r'=r.with("pending",false).with("posted",false).with("active",false)
    .with("lastLogout",r.nonce).with("revocation",if (r.active) 1 else 0)
  action revocationFailed = all {r.revocation==1,r'=r.with("revocation",3)}
  action revocationConfirmed = all {r.revocation==1,r'=r.with("revocation",2)}
  action restart = r'=r.with("pending",false).with("posted",false)
  action tick = r'=r.with("clock",r.clock+1)
  action unsafeActivate = r'=r.with("receipts",r.receipts.append(
    {client:r.client,subject:2,nonce:r.nonce,identity:good(99,99,2),at:r.clock,deadline:r.deadline}))
  action unsafeLateActivate = r'=r.with("receipts",r.receipts.append(
    {client:r.client,subject:r.subject,nonce:r.nonce,identity:good(r.client,r.nonce,r.subject),
      at:r.clock,deadline:r.deadline}))
  action unsafeReplaceAccount = r'=r.with("subject",r.subject+1)
  action unsafeReopen = r'=r.with("active",true)
  val safety = r.host==17 and r.receipts.indices().forall(i => {
    val receipt=r.receipts.nth(i)
    bound(receipt.identity,receipt.client,receipt.nonce,receipt.subject) and
      receipt.client==r.client and receipt.subject==r.subject and receipt.at<receipt.deadline
  }) and (r.active implies r.receipts.indices().exists(i => {
    val receipt=r.receipts.nth(i)
    receipt.client==r.client and receipt.subject==r.subject and receipt.nonce>r.lastLogout
  }))
  action step = any {begin,callback(1),callback(2),invalidGrant,
    activate(good(r.client,r.nonce,1)),activate(good(r.client,r.nonce,2)),logout,restart,
    revocationFailed,revocationConfirmed,tick}
  run registrationRequiresIssuedClientTest = init.then(begin).then(callback(0).fail())
  run reauthorizationCannotReplaceClientTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(begin).then(callback(2).fail())
  run invalidGrantRetainsIssuedClientTest = init.then(begin).then(callback(1))
    .then(invalidGrant).then(restart).then(begin).expect(r.request==1 and safety)
  run wrongIssuerCannotActivateTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1).with("issuer",1)).fail())
  run wrongAudienceCannotActivateTest = init.then(begin).then(callback(1))
    .then(activate(good(2,1,1)).fail())
  run wrongNonceCannotActivateTest = init.then(begin).then(callback(1))
    .then(activate(good(1,2,1)).fail())
  run badSignatureCannotActivateTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1).with("signature",false)).fail())
  run identityAloneCannotGrantInferenceTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1).with("permission",false)).fail())
  run logoutCannotReplaceSelectedAccountTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(logout).then(restart).then(begin).then(callback(0))
    .then(activate(good(1,2,2)).fail())
  run lateCallbackAfterLogoutCannotActivateTest = init.then(begin).then(callback(1))
    .then(logout).then(activate(good(1,1,1)).fail())
  run unsafeIdentityCounterexampleTest = init.then(begin).then(callback(1))
    .then(unsafeActivate).expect(not(safety))
  run failedRevocationCannotRestoreOldTokenTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(logout).then(revocationFailed)
    .expect(not(r.active) and r.client==1 and r.subject==1 and safety)
  run lateRevocationCannotClearNewLoginTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(logout).then(begin).then(callback(0))
    .then(activate(good(1,2,1))).then(revocationConfirmed).expect(r.active and safety)
  run revokedSessionReopenCounterexampleTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(logout).then(unsafeReopen).expect(not(safety))
  run expiredIdentityCannotActivateTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1).with("fresh",false)).fail())
  run verificationCannotExtendLoginDeadlineTest = init.then(begin).then(callback(1))
    .then(tick).then(tick).then(activate(good(1,1,1)).fail())
  run lateActivationCounterexampleTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(begin).then(callback(0)).then(tick).then(tick)
    .then(unsafeLateActivate).expect(not(safety))
  run accountReplacementCounterexampleTest = init.then(begin).then(callback(1))
    .then(activate(good(1,1,1))).then(unsafeReplaceAccount).expect(not(safety))
}

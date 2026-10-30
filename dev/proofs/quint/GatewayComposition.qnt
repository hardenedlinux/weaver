module GatewayComposition {
  import ProviderRpc as P from "./ProviderRpc"
  import ConnectionAdmission as C from "./ConnectionAdmission"
  val safe=P::safe and C::safe
  action init=all {P::init,C::init}
  action transport=all {C::step,P::observe}
  action execution=all {P::step,C::idle}
  action step=any {transport,execution}
  action admit=all {P::admit(0),C::idle}
  action consume=all {P::consume(0),C::idle}
  action burn=all {P::burn,C::idle}
  action invoke=all {P::invoke,C::idle}
  action publish=all {P::publish,C::idle}
  action release=all {P::batch(1,0),C::idle}
  action spent=init.then(admit).then(consume).then(burn).then(invoke)
  run setupDoesNotCreateClaimTest=init.then(transport).then(transport).expect(safe and P::s.stage==0 and P::s.calls==0 and P::s.held==0)
  run reconnectRetainsSpentRootTest=spent.then(transport).then(transport).expect(safe and P::s.calls==1 and P::s.held==4 and not(P::s.token)).then(consume.fail())
  run reconnectDoesNotReauthorizeReleaseTest=spent.then(publish).then(transport).expect(safe and P::s.held==4).then(release.fail())
}

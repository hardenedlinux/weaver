permit(
    principal == Weaver::Principal::"alice",
    action == Weaver::Action::"invoke",
    resource == Weaver::Target::"primary"
) when { context.family == "demo-family" && context.profile == "demo-profile" };

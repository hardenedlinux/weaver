permit (
    principal == Weaver::Principal::"alice",
    action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"],
    resource
) when {
    context.family == "f" && context.node == "infer" && context.profile == "p" &&
    context.model == "model-a" && context.ceiling >= 4 && context.sequence < 4096 &&
    ["protobuf", "arrow"].contains(context.format)
};
forbid (principal, action, resource == Weaver::Target::"denied");

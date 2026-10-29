// Contract: original task and immutable message binding authenticate these facts.
// CompoundAuthorization profile: allow is required and evaluation errors reject.
permit(
    principal == Weaver::Principal::"alice",
    action in [Weaver::Action::"admitMessage", Weaver::Action::"openStream",
               Weaver::Action::"resumeMessage", Weaver::Action::"writeRange"],
    resource
) when {
    context.family == "f" && context.node == "emit" && context.profile == "p" &&
    ["m0", "m1"].contains(context.message) && context.ceiling >= 4 &&
    context.payload_length > 0 && context.payload_length <= 1048576
};

forbid(principal, action == Weaver::Action::"writeRange", resource)
when {
    context.offset < 0 || context.length <= 0 ||
    context.offset + context.length > context.payload_length
};

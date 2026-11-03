// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

permit (
    principal == Weaver::Principal::"alice",
    action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"],
    resource
) when {
    context.family == "f" && context.node == "infer" && context.profile == "p" &&
    context.model == "model-a" && context.ceiling >= 4 && context.sequence < 4096 &&
    context.profile_digest != "" && context.protocol == "openai.chat-text-sse.v1" &&
    context.output_token_limit > 0 && context.output_token_limit <= 4096 && context.message_count <= 64 &&
    ["protobuf", "arrow"].contains(context.format)
};
forbid (principal, action, resource == Weaver::Target::"denied");

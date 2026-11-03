// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

#ifndef WEAVER_POLICY_H
#define WEAVER_POLICY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t weaver_policy_abi_v1(void);
/* Borrowed immutable UTF-8 buffers, each 1..65536 bytes, valid until return.
 * 0=validated inert artifact, 1=invalid Policy/schema, 2=invalid arguments,
 * 3=contained Rust unwind. No returned status authorizes an external effect.
 * No NUL termination is required; embedded NULs remain input bytes. */
int32_t weaver_policy_validate_v1(const uint8_t *policy, size_t policy_len,
                                const uint8_t *schema, size_t schema_len);
#ifdef __cplusplus
}
#endif
#endif

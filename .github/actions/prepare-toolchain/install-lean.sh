#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
#
# SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

set -euo pipefail

read -r toolchain < dev/proofs/cedar/lean-toolchain
[[ "$toolchain" == leanprover/lean4:v* ]]
tag="${toolchain#*:}"
asset_name="lean-${tag#v}-linux.tar.zst"
tag_uri="$(jq -nr --arg tag "$tag" '$tag | @uri')"
read -r asset_id sha256 < <(
  curl --fail --silent --show-error --location --retry 3 \
    "https://api.github.com/repos/leanprover/lean4/releases/tags/$tag_uri" |
    jq -er --arg name "$asset_name" \
      '.assets[] | select(.name == $name) | [.id, (.digest | ltrimstr("sha256:"))] | @tsv'
)
[[ "$asset_id" =~ ^[0-9]+$ && "$sha256" =~ ^[0-9a-f]{64}$ ]]
archive="${RUNNER_TEMP:?}/$asset_name"
release_root="$RUNNER_TEMP/weaver-lean"
curl --fail --location --retry 3 --header 'Accept: application/octet-stream' \
  --output "$archive" \
  "https://api.github.com/repos/leanprover/lean4/releases/assets/$asset_id"
echo "$sha256  $archive" | shasum -a 256 --check
mkdir -p "$release_root"
tar --zstd -xf "$archive" -C "$release_root" --strip-components=1
elan toolchain link "$toolchain" "$release_root"
elan run "$toolchain" lean --version

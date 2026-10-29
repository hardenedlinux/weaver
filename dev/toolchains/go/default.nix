{ go }:

# Backport the upstream coordinator fix without changing the locked package set.
go.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./fuzz-parent-deadline.patch ];
})

#!@PREFIX@/bin/sh
#
# The real binary lives in libexec so a later sidecar can sit beside it
# without polluting /usr/bin.
#
# @PREFIX@ is substituted at package time: empty for roothide, whose package
# is relocated into the jbroot it picked this boot and whose programs resolve
# unprefixed paths inside it, and /var/jb for a rootless bootstrap, where
# every path has to be spelled out — including this script's own interpreter.
exec @PREFIX@/usr/libexec/codex/codex "$@"

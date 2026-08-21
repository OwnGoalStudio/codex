#!@PREFIX@/bin/sh
#
# The real binary lives in libexec so a later sidecar can sit beside it
# without polluting /usr/bin.
#
# @PREFIX@ is substituted at package time: empty for roothide, whose vroot
# shell resolves unprefixed paths inside its randomized jbroot, and /var/jb for
# rootless, where every path has to be spelled out — including this script's
# own interpreter. The Rust binary itself is not vroot-linked.
#
# rustls-native-certs treats iOS as Unix, not macOS, so it probes openssl
# paths on the real rootfs (`/etc/ssl/cert.pem`) which are empty. Point it
# at the bootstrap CA bundle unless the user already set one. Codex's own
# websocket TLS builder reads the same SSL_CERT_FILE / CODEX_CA_CERTIFICATE.
if [ -z "${SSL_CERT_FILE:-}" ]; then
	for _codex_ca in \
		"@PREFIX@/etc/ssl/cert.pem" \
		"@PREFIX@/etc/ssl/certs/ca-certificates.crt" \
		"/var/jb/etc/ssl/cert.pem" \
		"/etc/ssl/cert.pem"
	do
		if [ -r "$_codex_ca" ]; then
			# RootHide shell paths are jbroot-based. Convert the chosen path to
			# the physical path that the unlinked Rust process must open.
			if [ -z "@PREFIX@" ]; then
				_codex_ca="$(jbroot "$_codex_ca")" || exit $?
			fi
			SSL_CERT_FILE="$_codex_ca"
			export SSL_CERT_FILE
			break
		fi
	done
	unset _codex_ca
fi
exec @PREFIX@/usr/libexec/codex/codex "$@"

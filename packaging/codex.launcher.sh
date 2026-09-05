#!@PREFIX@/bin/sh

# The payload uses libSystem directly. Export physical bootstrap paths so
# subprocess lookup and TLS work outside the parent's RootHide filesystem view.
_og_prefix="@PREFIX@"
if [ -z "$_og_prefix" ]; then
    _og_prefix="$(jbroot /)" || {
        echo "codex: cannot resolve RootHide bootstrap with jbroot" >&2
        exit 127
    }
    case "$_og_prefix" in
        /*) ;;
        *) echo "codex: jbroot returned an invalid path" >&2; exit 127 ;;
    esac
    _og_prefix=${_og_prefix%/}
fi
PATH="$_og_prefix/usr/local/bin:$_og_prefix/usr/bin:$_og_prefix/bin:$_og_prefix/usr/sbin:$_og_prefix/sbin${PATH:+:$PATH}"

# Only translate bootstrap shell paths; a physical or custom SHELL stays intact.
case "${SHELL:-}" in
    /bin/*|/usr/bin/*) SHELL="$_og_prefix$SHELL" ;;
esac
if [ -z "${SHELL:-}" ]; then
    for _og_shell in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
        if [ -x "@PREFIX@$_og_shell" ]; then
            SHELL="$_og_prefix$_og_shell"
            break
        fi
    done
fi
export PATH SHELL

# Preserve explicit user CA settings. Test in the shell's view, then pass the
# physical path to the payload (which cannot open RootHide's virtual /etc).
if [ -z "${SSL_CERT_FILE:-}" ]; then
    for _og_ca in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
        if [ -r "@PREFIX@$_og_ca" ]; then
            SSL_CERT_FILE="$_og_prefix$_og_ca"
            export SSL_CERT_FILE
            break
        fi
    done
fi
if [ -z "${BROWSER:-}" ] && [ -x "@PREFIX@/usr/bin/uiopen" ]; then
    BROWSER="$_og_prefix/usr/bin/uiopen"
    export BROWSER
fi
unset _og_prefix _og_shell _og_ca

exec @PREFIX@/usr/libexec/codex/codex "$@"

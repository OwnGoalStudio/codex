# codex — Agent Notes

[OpenAI Codex](https://github.com/openai/codex) — the terminal coding
agent — built for jailbroken iOS 15+ and installed as `codex`, for both
**roothide** and **rootless** bootstraps.

This repository holds **no application source**. It fetches openai/codex at a
pinned commit, applies `patches/`, cross-compiles for `aarch64-apple-ios`, and
packages. Everything runs through `Scripts/`, so CI and a local checkout
execute the same code.

## Hard rules

- **Not a fork.** Never vendor openai/codex source here. Every change to it is a
  patch in `patches/`, applied by `Scripts/prepare-source.sh` to a fresh
  checkout of `UPSTREAM_REF`. Keep patches small and single-purpose.
- **`UPSTREAM_REF` is a full commit sha**, not a branch. Bump with
  `make bump-upstream REF=…`.
- **One arm64 binary backs both packages.** arm64 runs on every arm64e device
  and the reverse is not true. The two `.deb` architectures name a *bootstrap
  layout*, not a CPU: `iphoneos-arm64` is rootless, `iphoneos-arm64e` is
  roothide. Never build an arm64e slice for the "arm64e" package. Aggregate
  release targets must build that payload once, package it twice, and checksum
  only the two exact current-version outputs; device installation must select
  the same exact version so stale artifacts cannot leak into either path.
- **Never hardcode a bootstrap path in patched source.** Probe for the file and
  take the first that exists. Prefix substitution belongs in *packaging*
  (`@PREFIX@`), not in Rust.
- **Versions live in `Configuration/version.txt` only.** `X.Y.Z` tracks
  upstream's crate version; `X.Y.Z-N` is a packaging-only respin.
- **Do not link libvroot into this binary.** See below.
- **`CLAUDE.md` is a symlink to `AGENTS.md`**, never a file of its own. One
  set of notes, two names; `make check` enforces it.
- **Review for sensitive information before anything is uploaded or
  published.** `Scripts/check-sensitive.sh` scans tracked files, the staged
  package tree and the finished `.deb`s for credentials, private keys, home
  and scratch paths, device identifiers, IP addresses and e-mail addresses.
  `make check`, `package-deb.sh` and the Release workflow all run it and
  stop on a hit. A deliberate public value goes on its allowlist; a rule is
  never loosened.
- **Jitless V8 still needs its iOS address-space entitlement.** Sandbox-enabled
  V8 reserves a large address cage on iOS, so sign the CLI and Code Mode host
  with `com.apple.developer.kernel.extended-virtual-addressing`; do not add JIT
  or unsigned-executable-memory entitlements to solve an address-space failure.

## libvroot is not our problem, and not our solution

RootHide's one-line summary is `roothide = rootful + libvroot`.

**libvroot** is a compile-time shim for C/C++ bootstrap programs. When Procursus
builds git, bash, ssh, it rewrites ~200 path APIs (`open`, `stat`, `execve`,
`posix_spawn`, …) so that `/bin/sh` and `/usr/bin/git` mean "those paths inside
the randomized jbroot", and the real iOS root is reached at `/rootfs/...`.
That is why a C program compiled into the bootstrap can keep writing `/bin/sh`
and still work on roothide, and why git's hardcoded `/bin/sh` for credential
helpers does **not** need a `/var/jb` patch on roothide.

Rootless has no such shim. `/bin/sh` is simply absent (`/var/jb/bin/sh` → dash).
That is the Procursus git `SHELL_PATH=$(MEMO_PREFIX).../bin/sh` patch.

This binary is **Rust**. rustc talks to libSystem directly. It is not built
with libvroot, and injecting vroot into a Rust std::process is not something
we will do. Consequences:

- A vroot parent shell may export `SHELL=/bin/zsh`. That path is true *inside*
  the parent, and a lie to this process: `is_executable("/bin/zsh")` looks at
  the real rootfs and fails on both bootstraps.
- Runtime lookup first derives RootHide's randomized bootstrap from the
  executable directory's official `.jbroot` link, then probes `/var/jb/bin`
  and `/var/jb/usr/bin` for rootless. Unprefixed `/bin` stays in the list for
  rootful and for a future vroot-linked world we are not in.
- **Packaging** is still two layouts. roothide dpkg unpacks an unprefixed tree
  into the jbroot it picked this boot; rootless dpkg unpacks under `/var/jb`.
  The architecture field (`iphoneos-arm64e` vs `iphoneos-arm64`) names that
  layout. Do not assume RootHide exposes `/var/jb`; ask
  `dpkg --print-architecture` when the installed layout matters.

Do not add `/var/jb` to patched source as a universal jailbreak prefix. It is
one rootless candidate in a probe list; RootHide discovery must use the
per-Mach-O-directory `.jbroot` contract rather than guessing its random path.

## Layout

```
Configuration/upstream.env   pinned ref, cargo package/bin, iOS floor, rustc
Configuration/version.txt    package version
patches/NNNN-*.patch         applied in sorted order to a pristine checkout
Packaging/DEBIAN/control     control template (@PLACEHOLDER@ substituted)
Packaging/codex.entitlements  what the signed binary carries, and why
Packaging/codex.launcher.sh   /usr/bin/codex → the real binary in libexec
Scripts/prepare-source.sh    fetch + patch (idempotent, stamped)
Scripts/prepare-rusty-v8.sh  fetch matching full recursive V8 source
Scripts/build-ios.sh         build CLI + Code Mode host, verify both Mach-Os
Scripts/package-deb.sh       stage + ldid + dpkg-deb + verify
Scripts/install-device.sh    install over SSH and smoke-test (dev only)
build/                       everything generated; not source
```

## Build & verify

- `make check` — script syntax, config sanity, patch set, packaging inputs
- `make source` — fetch + patch; fails loudly if a patch no longer applies
- `make build` — cross-compile and verify the Mach-O is iOS
- `make debs` — both packages plus `SHA256SUMS`; what CI releases
- `make install` — install on an attached device and run `--version`.
  Over USB: `iproxy 4422:2222 &`

Test by installing, never by copying a binary onto `/var/mobile`. A copied
binary runs with its entitlements ignored (trustcache never saw it).

## The OwnGoalPackages contract

Same as kk: a non-draft, non-prerelease tag `vX.Y.Z`; assets whose names end
in `iphoneos-arm64.deb` / `iphoneos-arm64e.deb`; a `SHA256SUMS` of bare names.

`Follow upstream` runs every Monday at 00:00 UTC: pin to the newest stable
`openai/codex` `rust-vX.Y.Z` release, `make source` to prove `patches/` still
apply, then commit and tag `vX.Y.Z` as `bot <bot@owngoal.dev>`. `Release` builds
that tag. A packaging respin `X.Y.Z-N` already tracks upstream `X.Y.Z`, so the
job advances on a new stable version rather than a different same-version SHA.
OwnGoalPackages fetches it at 04:00 UTC.

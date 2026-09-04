[OpenAI Codex](https://github.com/openai/codex) — the terminal coding agent — built for jailbroken iOS and installed as `codex`.

## Which one do I download?

The architecture field names the **bootstrap layout, not the CPU**. Both packages carry the same arm64 binary.

| your bootstrap | download |
| -------------- | -------- |
| rootless (Dopamine, palera1n rootless) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64.deb` |
| roothide (RootHide Dopamine) | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64e.deb` |

Not sure? Ask the device: `dpkg --print-architecture`.

Requires **iOS @MIN_IOS_MAJOR@ or later** and a bootstrap that provides a shell. Or add the [OwnGoal Studio repository](https://github.com/owngoal-dev/OwnGoalPackages) and let your package manager pick.

## Usage

Run `codex` in a terminal on device. Authenticate with ChatGPT or an API key. The browser login uses `uiopen`. Code Mode uses the packaged native `codex-code-mode-host` sidecar.

## About this build

Upstream [`openai/codex@@UPSTREAM_SHORT@`](https://github.com/openai/codex/commit/@UPSTREAM_REF@), plus the patches that port it to a jailbroken iOS userspace. The binary is a Rust executable: it is **not** linked with libvroot, so it has to probe for the bootstrap's shell instead of trusting `/bin/sh`. See [`patches/`](https://github.com/owngoal-dev/codex/tree/@TAG@/patches).

Verify your download against `SHA256SUMS`.

**Full changelog**: https://github.com/owngoal-dev/codex/commits/@TAG@

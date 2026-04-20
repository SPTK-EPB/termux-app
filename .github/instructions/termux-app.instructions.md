<!-- Generated from .claude/rules/termux-app.md by sync-rules-to-instructions.sh — do not edit directly -->
# Termux App — Unity Fork Rules

> This is SPTK-EPB's fork of [termux/termux-app](https://github.com/termux/termux-app).
> All fork-specific logic lives in `app/src/main/java/com/termux/app/TermuxInstaller.java`.
> Mark every Unity block with `// Unity:` so it's easy to isolate during upstream rebases.

## Fork Identity

- **Package name**: `com.termux` (unchanged from upstream — required for plugin compatibility)
- **Version scheme**: `0.118.0-unity.N` based on upstream `v0.118.3`. `versionCode` = `118N` (e.g. unity.12 → 118012)
- **Distribution**: debug APK only via GitHub Releases + UDM `fleet-install`. Not on F-Droid or Google Play.
- **Default build target**: `apt-android-7` variant. Override via `TERMUX_PACKAGE_VARIANT` env var.

## What This Fork Adds (all in TermuxInstaller.java)

After bootstrap zip extraction, before `whenDone.run()`, in order:

1. **`holdAptVersions()`** — pins apt and gpgv at bootstrap versions. Upgraded apt 2.8.1+ with gpgv 2.5.17/libgcrypt 1.11.2 fails to read the bootstrap keyring ("unsupported filetype"). Never remove this hold.
2. **`injectSshBootstrap()`** — writes `~/.ssh/authorized_keys` (fleet management key) and `~/.bashrc` (sshd safety net), installs openssh, starts sshd via `Runtime.exec()`. Log: `~/unity-ssh-setup.log`.
3. **`runUnityProvisioning(activity)`** — reads `deviceId`, `deviceSecret`, `baseUrl` from Android Application Restrictions (DPC-set), fetches and runs the UDM bootstrap script. Retries 6× with 5 s gaps (restrictions may not be available at first launch). Log: `~/unity-provisioning.log`.
4. **Bootstrap completion broadcast** — sends `work.unityoperator.unityapp.ACTION_TERMUX_BOOTSTRAP_COMPLETE` to the DPC with `bootstrapDurationMs`. Non-fatal if DPC absent — older DPC versions fall back to a 300 s polling window.

## Runtime.exec() PATH Trap

`$PREFIX/bin` is NOT on PATH when launched via `Runtime.exec()`. All commands in provisioning/SSH scripts must either:
- Use absolute Termux paths: `/data/data/com.termux/files/usr/bin/<tool>`
- Or be invoked as: `$PREFIX/bin/bash -c '...'` (sets up correct env)

## Bootstrap Concurrency Race (Android 11+)

`injectSshBootstrap()` and `runUnityProvisioning()` both call `Runtime.exec()` and use `apt`/`pkg`. They race for the apt lock. The SSH setup script has a 30 × 4 s wait loop for the lock — do not remove it. Do not use `yes | pkg install` — it causes broken pipe on Android 11 (use `pkg install -y openssh` instead).

## Upstream Sync Strategy

- Upstream is `termux/termux-app`. The fork diverges only in `TermuxInstaller.java`.
- When rebasing onto a newer upstream: the `// Unity:` comments mark all hunks to carry forward.
- **Ask before rebasing** — coordinate in GitHub Issues; do not rebase unilaterally.
- Do NOT modify `terminal-emulator/`, `terminal-view/`, or `termux-shared/` unless fixing a confirmed upstream bug.

## Release Pipeline

1. Bump `versionCode` and `versionName` in `app/build.gradle` (both required).
2. Create a GitHub Release — CI workflow `attach_debug_apks_to_release.yml` fires on `published`, builds both package variants, attaches 5 ABI APKs + sha256sums per variant.
3. APK filename format: `termux-app_<version>+<variant>-github-debug_<abi>.apk`
4. After CI attaches APKs, register the new version in UDM and deploy via `fleet-install`.
5. The signing keystore (`.jks`) is gitignored — never commit it.

## Logging Convention

Use `Logger.logInfo(LOG_TAG, ...)` and `Logger.logError(LOG_TAG, ...)` — not `android.util.Log` directly. Unity-specific logs go to the dedicated log files (`~/unity-ssh-setup.log`, `~/unity-provisioning.log`) via shell redirection in the provisioned scripts, not to logcat.

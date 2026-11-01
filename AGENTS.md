# Agent instructions

## Responsibility

Maintain the Orange Pi 5 UEFI platform. Board policy, boot arguments and the kernel are in `UniXNU-orangepi5`.

## Rules

- Never modify the edk2-rk3588 checkout; everything lives in `UniXNUOrangePi5/`.
- Machine paths, hosts, accounts and passwords belong in `.env` only (git-ignored). Never put them into a script, comment or document.
- Do not commit generated files (`build/`, `out/`, logs).
- The watchdog driver cannot be disarmed once armed; do not add a code path that tries.
- The board has no remote power switch: a hang ends in the watchdog's reset or in someone pulling the plug. Say so before a run that could hang.
- Report commands, revisions and results; keep hardware observations apart from host test results.

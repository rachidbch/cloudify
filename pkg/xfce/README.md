# pkg/xfce

XFCE desktop + xrdp GUI endpoint on an Ubuntu 24.04 guest, ready to be driven
over RDP by Guacamole or any RDP client. Proven oracle: cloudstation:guac-gui
(fact table in plans/xfce-pkg-plan.md).

## Boundary

Owns: XFCE + xrdp packages, the GUI login account, session file, default
browser registration, the xrdp service and key.pem.

Does NOT own: container creation, Tailscale identity/tags, ACLs, UFW
forwarding, guacamole or its connection record. The RDP side of the guacamole
wiring is data, not this package: the printed/generated password + the guest's
tailnet IP go into guacamole's config, then `cloudify configure guacamole`.

## Install

```bash
cloudify --on <guest> install xfce
cloudify --on <guest> configure xfce    # re-assert session/registration + xrdp
cloudify --on <guest> verify xfce       # verify-only
```

Split package (ADR-008). Password handling is install-time only.

## Configuration

Secrets/deployment values arrive via caller env or
`~/.config/cloudify/pkgs/xfce.yaml`. Remote-forwarded names (`.remote-vars`):
`CLOUDIFY_XFCE_USER`, `CLOUDIFY_XFCE_USER_PASSWORD`.

- `CLOUDIFY_XFCE_USER` - human-given login name, default `gui`. Created once
  (POSIX name: lowercase start, alnum/`_`/`-`).
- `CLOUDIFY_XFCE_USER_PASSWORD` - optional. Provided: used as the password at
  user creation, never printed. Absent: auto-generated (24+ URL-safe chars)
  and printed once in the install output with a banner.
- `CLOUDIFY_XFCE_SESSION` - default `startxfce4`.
- `CLOUDIFY_XFCE_RDP_PORT` - default `3389`.
- `CLOUDIFY_XFCE_INSTALL_CHROME` - default `true` (google-chrome apt repo,
  oracle-proven; not a .deb download).

## Password model

- Set/changed only at user creation. Reruns never alter an existing password.
- Generated passwords print ONCE with a banner; the recovery copy lives in
  `/etc/cloudify/xfce-user.env` (root-only, mode 600) on the guest.
- The generated or env-passed password is what xrdp authenticates against
  (PAM) and what the guacamole connection record needs as
  `CLOUDIFY_GUACAMOLE_RDP_PASSWORD`.
- Rotation is a documented manual operation (out of package scope): change the
  password on the guest and update the guacamole record in the same step.

## Verification

`pkg_verify` (self-contained, reads the on-guest state file only, retried
until `PKG_VERIFY_TIMEOUT`): user exists with the configured session in
`.xsession`; xrdp active and listening on the configured port; key.pem
resolvable with xrdp in `ssl-cert`; chrome + `helpers.rc` present when chrome
is enabled. A local hook cannot prove a remote RDP/Guacamole session renders -
that E2E gate needs a real client and is in the xfce plan.

## Gotchas

- Env-passed passwords must not contain single quotes or control chars
  (cloudify payload landmine L1). Generated ones are alnum-only by design.
- `gui` is non-sudo by default. The live oracle's sudo grant is an instance
  deviation, not a package default.
- XFCE GTK/icon theming is unrenderable under xrdp (upstream xorgxrdp lacks
  XI2) - cosmetic, do not chase it (parked, see the SOP learnings).
- No destructive `--clear-data` path: the user home is never deleted. The
  package owns no data volume; clear-data semantics do not apply.
- Remote hosts run code from GitHub master: push before testing.

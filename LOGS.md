# Cloudify session log

## 2026-08-31

- Recorded the successful XFCE and Guacamole oracle and the next Omarchy VM automation path.
- Aborted and trashed the mistaken local Omarchy ISO download before any VM creation.

## 2026-08-31 (session 2) — Omarchy parked

- Root-caused the cloudstation SSH blocker: `/etc/hosts` pinned cloudstation to its public IP, bypassing MagicDNS. Pin removed by user; `ssh cloudstation` now goes over tailnet (MagicSSH), no passphrase needed.
- Exa-grounded every plan assumption: Arch + Hyprland base, v4.0.1 ISO + checksum, Incus ISO/cidata mechanics, xrdp/Wayland incompatibility, wayvnc as the community remote-desktop path, no container precedent (domarchy/devmarchy findings).
- User decisions: no Incus VM on the 8 GiB host; Omarchy deferred until community container support exists. ADR-016 supersedes ADR-015.
- Minted the tag:incus authkey via `ivps tag create incus` (reported; reusable; expires 2026-09-01 02:05).

## 2026-08-31 (session 2 cont.) — Guacamole admin password reset

- User lost the Guacamole web-admin (`rbc`) plaintext; reset via the SOP hash formula against `guacamole_db`. Guacamole 1.6.0 schema fact: `guacamole_user` has no `username` column — the login name lives in `guacamole_entity.name` (joined via `entity_id`), a departure from the SOP's older-schema wording.
- New random salt + password generated on cloudstation (never echoed), `UPDATE guacamole_user SET password_hash/password_salt/password_date WHERE entity_id=(... name='rbc')`, verified via `POST /api/tokens` → 200 + token.
- Credentials persisted to `/home/rbc/guacamole/.env` (`GUACAMOLE_ADMIN_USER`, `GUACAMOLE_ADMIN_PASSWORD`, mode 600); temp state file removed.

## 2026-08-31 (session 2 cont. 2) — guac-gui auto-tiling + XFCE theme investigation

- Enabled **Cortile** auto-tiling on `cloudstation:guac-gui` (pinned v2.5.2, SHA256 verified, installed to /usr/local/bin, XDG autostart for the gui user). Verified live: windows auto-tile on open (Pop!_OS-style), no keybinding needed. Snapshot `guac-gui-cortile` taken.
- Wallpaper set to the user's chosen image (transferred laptop→cloudstation→container to /usr/share/backgrounds/modern.png).
- **XFCE GTK/icon theming is blocked by a known upstream bug**: under xorgxrdp the virtual X server lacks XI2, so xfsettingsd cannot own `_XSETTINGS_S0` → GTK apps get no theme. Config is correct (Arc/Papirus) but unrendered. Receipts: Launchpad #354830 (affects 20, "no gtk theme" when XI absent via xrdp/VNC), Xfce forums #8112 & #8603. Parked by user decision.
- Themed attempts left strays; cleaned up xfsettingsd + temp files. Theme bug parked; substantive goals (Cortile tiling, wallpaper, speed) delivered.

## 2026-08-31 (session 2 cont. 3) — guac-gui final polish; Guacamole letterbox fixed

- Diagnosed the "black strip top/bottom" as **Guacamole client letterboxing**, not XFCE — the RDP connection used Guacamole's default fixed resolution; the client scaled it to the browser preserving aspect, padding the mismatch with black. Confirmed via right-click (strip showed the browser menu, not XFCE).
- Fixed by setting the `cloudstation GUI` connection's `resize-method=display-update` in guacamole_connection_parameter → the RDP session now dynamically resizes to the browser window (resolution went 1536x729 → 1536x864, no letterbox). Verified: xrdp + tailscale + Cortile healthy after resize.
- Final persistent guac-gui state: Cortile auto-tiling (autostart), user wallpaper, no desktop icons, xfwm compositing off, Guacamole display-update. XFCE GTK theme still parked (known xorgxrdp XI2 bug).

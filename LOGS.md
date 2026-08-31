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

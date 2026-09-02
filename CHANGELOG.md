# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.1.0] - 2026-09-02

### Fixed

- **A file changing while the data archive is written no longer marks
  the backup as failed.** GNU `tar` exits 1 when a live application
  touched a file mid-read; the archive is complete and usable. The loop
  now treats exit 1 as success (noting it in the log line) and only a
  real `tar` failure (exit 2) produces `FAILED`. CI's archive check now
  reads the file name from the `backup OK` log line instead of racing an
  archive that may still be being written.

### Added

- **`tests/e2e-backup-restore.sh`** — seven end-to-end scenarios against
  the live stack, run by CI on every push and by you locally: the
  required-variable guard fires, a backup is produced, it is a readable
  archive with real dump content (and a readable data `tar.gz` where the
  stack has one), a database outage is reported as `FAILED`, **restore
  genuinely replaces database state** (a marker row inserted after the
  baseline backup is gone after restoring it), and pruning removes only
  old files.

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  The old loop piped the dump into `gzip` and only checked `gzip`'s exit
  status, so a dump that failed halfway (database down, wrong password,
  disk full) still left a small `.gz` that looked like a backup. The loop
  now runs with `pipefail`, logs `Database backup OK: <file> (<bytes>
  bytes)` or `Database backup FAILED` per cycle, keeps a failed dump as
  `<file>.failed` for diagnosis, and prunes only its own files. Retention
  set to `0` disables pruning instead of deleting everything.

### Added

- CI now waits for the first backup cycle and proves the produced
  archive is readable and contains a real dump header (plus a readable
  `tar.gz` for the data backup where the stack has one).

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Credentials untracked from git.** The repository previously shipped a
  tracked `.env` with generated-looking passwords; anyone who deployed
  without editing it ran production on credentials published on GitHub.
  `.env` is now gitignored; `.env.example` ships `change_me_*` placeholders
  with generation commands, and the compose file fails fast via `${VAR:?}`
  when required secrets are unset.
- **Nextcloud bumped 29 → 34.0.3** (`nextcloud:34.0.3@sha256:da8a5481…`).
  Nextcloud 29 is end-of-life and no longer receives security updates.
  ❗ Existing deployments must upgrade one major at a time (29 → 30 → … → 34);
  see the README upgrade section before pulling.
- **Traefik bumped 3.2 → 3.7** (`traefik:3.7@sha256:9c2a54d8…`). Traefik
  3.2's vendored Docker client cannot talk to Docker Engine 29 — the docker
  provider fails in a retry loop and the stack silently serves 404s on
  hosts running current Docker.
- **Redis bumped 7.2 → 7.4**, **postgres:16 digest pinned** — all four
  images now pinned by `tag@sha256:digest`.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block, `${VAR:-tag@sha256:…}`): `git pull` alone delivers the
  tested version combination, `.env` carries only secrets and deliberate
  overrides, and an override set in `.env` still wins.
- Operational variables (log level, timezone, DB/admin names, backup
  schedule and paths) now have compose-level defaults — the minimal `.env`
  is secrets and hostnames only.

### Added

- **Deployment Verification workflow** rebuilt: shellcheck + actionlint
  lint job; Trivy scans of all four pinned images (SARIF to the Security
  tab); weekly `check-pin-freshness` job that re-resolves every pinned tag
  against its registry and compares the pinned Nextcloud version and
  Traefik minor line against the latest upstream releases; and a
  deploy-and-test job that stands up the full stack with ephemeral
  credentials and waits for `status.php` to report `"installed":true`
  through Traefik — the shipped configuration must produce a working
  Nextcloud instance, not just started containers. Runs on push, PR,
  weekly cron, and manual dispatch.

### Fixed

- Shellcheck findings in both restore scripts (`read -r`, removed an unused
  unquoted variable).

[Unreleased]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0

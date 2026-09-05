# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.5.0] - 2026-09-04

### Added

- **A shutdown grace period for PostgreSQL and Redis.** Docker stops a container with
  SIGTERM and ten seconds, then SIGKILL. That default is not always enough:
  PostgreSQL has a checkpoint to write, MariaDB has InnoDB to flush, and Redis
  saves its dataset on the way out. Killed halfway, the next start does crash
  recovery, and a Redis holding another application's file locks leaves them
  behind for a person to clear by hand. Sixty seconds now, overridable per
  service with `<PREFIX>_STOP_GRACE_PERIOD` in `.env`. The backup sidecar is
  deliberately left alone: its failure mode is a truncated dump file, which a
  longer grace period does not fix.

## [1.4.0] - 2026-09-03

### Added

- **Per-image version overrides.** Every pin in the `x-images` block is
  now `${<PREFIX>_IMAGE_TAG:-repo:${<PREFIX>_IMAGE_VERSION:-tag@sha256:digest}}`.
  Set `<PREFIX>_IMAGE_VERSION` in `.env` to run a different version of one
  image while every other pin stays as tested (Compose pulls that tag
  without a digest), or `<PREFIX>_IMAGE_TAG` to replace the whole
  reference as before. A deployment that sets neither is unchanged. The
  freshness job, the Trivy matrix and the fleet digest automation resolve
  the nested default before reading a pin. Needs Docker Compose v2.5 or
  newer (2022): v2.0 to v2.4 leave the inner `${...}` unexpanded and
  `docker compose up` fails with an invalid reference instead of
  deploying something unexpected.

### Changed

- `nextcloud:34.0.3` re-pinned to the digest upstream now publishes for that tag (a rebuild, same version).

## [1.3.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

## [1.2.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.1.1] - 2026-09-02

### Fixed

- `tests/e2e-backup-restore.sh` hardened against what the first CI runs
  across the fleet surfaced: no `grep -q` on a `docker logs` pipe (with
  `pipefail`, grep exiting early failed the whole pipeline on long
  logs); the dump content check scans the whole dump instead of its
  first 80 lines; content and restore are judged on a backup taken
  after the marker exists; containers are resolved through
  `docker compose ps -q` so a `container_name` override cannot break
  the lookup; the fake-old prune file uses `touch -t`, which BusyBox
  accepts.

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

- **`tests/e2e-backup-restore.sh`**: seven end-to-end scenarios against
  the live stack, run by CI on every push and by you locally: the
  required-variable guard fires, a backup is produced, it is a readable
  archive with real dump content (and a readable data `tar.gz` where the
  stack has one), a database outage is reported as `FAILED`, **restore
 replaces database state** (a marker row inserted after the
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
  3.2's vendored Docker client cannot talk to Docker Engine 29: the docker
  provider fails in a retry loop and the stack silently serves 404s on
  hosts running current Docker.
- **Redis bumped 7.2 → 7.4**, postgres:16 digest pinned: all four
  images now pinned by `tag@sha256:digest`.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block, `${VAR:-tag@sha256:…}`): `git pull` alone delivers the
  tested version combination, `.env` carries only secrets and deliberate
  overrides, and an override set in `.env` still wins.
- Operational variables (log level, timezone, DB/admin names, backup
  schedule and paths) now have compose-level defaults: the minimal `.env`
  is secrets and hostnames only.

### Added

- **Deployment Verification workflow** rebuilt: shellcheck + actionlint
  lint job; Trivy scans of all four pinned images (SARIF to the Security
  tab); weekly `check-pin-freshness` job that re-resolves every pinned tag
  against its registry and compares the pinned Nextcloud version and
  Traefik minor line against the latest upstream releases; and a
  deploy-and-test job that stands up the full stack with ephemeral
  credentials and waits for `status.php` to report `"installed":true`
  through Traefik: the shipped configuration must produce a working
  Nextcloud instance, not just started containers. Runs on push, PR,
  weekly cron, and manual dispatch.

### Fixed

- Shellcheck findings in both restore scripts (`read -r`, removed an unused
  unquoted variable).

[Unreleased]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0

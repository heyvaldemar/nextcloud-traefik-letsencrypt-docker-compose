# Nextcloud + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Features](#features)
  - [Typical use cases](#typical-use-cases)
- [Background jobs via cron](#background-jobs-via-cron)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Restoring backups](#restoring-backups)
- [Operations](#operations)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **Nextcloud** behind **Traefik** with automatic **Let's Encrypt TLS**, backed by **PostgreSQL** and **Redis**, with a dedicated **cron container** for background jobs, a scheduled **backup container** (database + application data), and companion **restore scripts**. One `docker compose up` away from a production-shaped private cloud at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-nextcloud-using-docker-compose/](https://www.heyvaldemar.com/install-nextcloud-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Nextcloud AIO | Other compose examples |
|------|-----------|----------------|---------------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ hours of setup | ✅ | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | ✅ | Varies |
| PostgreSQL + Redis wired with healthchecks | ✅ | Separate installs | ✅ | Varies |
| Dedicated cron container for background jobs | ✅ | Manual crontab | ✅ | Often missing |
| Scheduled DB **and** data backups + pruning | ✅ | Manual cron | Borg-based | Rare |
| Restore scripts included | ✅ two scripts | Manual | ✅ | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | ❌ floating | Rare |
| Weekly pin-freshness check in CI | ✅ | N/A | ❌ | Rare |
| CI-verified install on every push | ✅ waits for `installed:true` | N/A | ❌ | Rare |
| Credentials via env (never committed) | ✅ | N/A | ✅ | Often committed plaintext |

Six moving parts (Traefik + Nextcloud + cron + Postgres + Redis + backups). No Kubernetes prerequisites, no manual certificate management.

## Prerequisites

Before you start, you need:

- **A Linux server** with a public IP. Tested on Ubuntu 22.04 LTS+ and Debian 12+. Local Mac/Windows works for dev; production is Linux.
- **Docker Engine 24+ and Docker Compose 2.20+.** Quick check: `docker version` and `docker compose version`.
- **A domain you control,** with two `A` records pointing at your server's public IP — one for Nextcloud (e.g. `nextcloud.example.com`), one for the Traefik dashboard (e.g. `traefik.nextcloud.example.com`). DNS must propagate before deploy or the Let's Encrypt TLS-ALPN challenge will fail.
- **Ports 80 and 443 open** on the server's firewall and not bound by another service.
- **~2 GB free RAM and 1 free CPU** for the running stack, plus disk sized to the files you plan to store and the backup retention window.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose
cd nextcloud-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create nextcloud-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: NEXTCLOUD_DB_PASSWORD, NEXTCLOUD_REDIS_PASSWORD,
#   NEXTCLOUD_ADMIN_PASSWORD, NEXTCLOUD_HOSTNAME, NEXTCLOUD_URL,
#   TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.
#   See .env.example for generation commands.

# 4. Deploy
docker compose -f nextcloud-traefik-letsencrypt-docker-compose.yml -p nextcloud up -d
```

First boot runs the full Nextcloud installer against Postgres — within a couple of minutes `https://${NEXTCLOUD_HOSTNAME}` serves the login page with a fresh Let's Encrypt certificate. Log in with `NEXTCLOUD_ADMIN_USERNAME` / `NEXTCLOUD_ADMIN_PASSWORD`.

### What success looks like

```bash
# All services should report healthy / up:
docker compose -f nextcloud-traefik-letsencrypt-docker-compose.yml -p nextcloud ps

# The installer finished:
curl -fsS "https://${NEXTCLOUD_HOSTNAME}/status.php"
# Expected: {"installed":true, ... "versionstring":"34.0.3", ...}

# Traefik issued a certificate:
docker compose -p nextcloud logs traefik | grep -i "adding certificate"

# First backup lands after BACKUP_INIT_SLEEP (default 30m):
docker compose -p nextcloud logs backups | tail -3
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated or port 80 isn't reachable from the internet. Confirm with `dig +short ${NEXTCLOUD_HOSTNAME}` and `curl -I http://${NEXTCLOUD_HOSTNAME}` from outside the server.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it. Generate values per the comments in `.env.example`.
- **`network nextcloud-network not found`.** Step 2 was skipped.
- **`status.php` shows `"installed":false` for a long time.** The installer runs on first boot only; check `docker compose -p nextcloud logs nextcloud` for database connection errors (usually a typo'd `NEXTCLOUD_DB_PASSWORD` after a previous boot already initialized the Postgres volume).

### Apply `.env` or compose-file changes

```bash
docker compose -f nextcloud-traefik-letsencrypt-docker-compose.yml -p nextcloud up -d --force-recreate
```

## Features

- **Nextcloud** latest stable (34.0.3) with PostgreSQL 16 backing store and Redis caching/locking.
- **Traefik v3** reverse proxy with automatic HTTP→HTTPS redirect, Let's Encrypt TLS-ALPN certificate issuance, CalDAV/CardDAV well-known redirects, and HSTS security headers preconfigured.
- **Dedicated cron container** running Nextcloud background jobs on schedule (see [Background jobs via cron](#background-jobs-via-cron)).
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Scheduled backups of both the database and application data** with configurable interval, retention, and destination paths.
- **Two restore scripts** — database and application data — with interactive backup selection.
- **Healthchecks** on every service with start-order dependencies.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete.

### Typical use cases

- **Private cloud for a family or team** — files, calendars, contacts, photos on your own hardware.
- **Compliance-constrained file sharing** — data residency requirements that rule out hosted drives.
- **Small-office groupware** — Nextcloud apps for talk, notes, tasks on one box.
- **Homelab hub** — pair with the [Keycloak template](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) for SSO across your services.

## Background jobs via cron

The stack ships a dedicated `nextcloud-cron` container that executes Nextcloud's background jobs (file indexing, notifications, cleanup) every 5 minutes, independent of user activity. After the first login, tell Nextcloud to use it:

1. Log in as an administrator.
2. **Administration settings** → **Basic settings** → **Background jobs**.
3. Select **"Cron (Recommended)"**.

Cron is the reliable choice for any instance beyond casual use — AJAX and Webcron both depend on page visits to trigger jobs.

## Supply chain trust

This repository is a **deployment template**, not a custom Docker image. It orchestrates four upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image
- [`nextcloud`](https://hub.docker.com/_/nextcloud) — Nextcloud, Docker Hub official image
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL, Docker Hub official image
- [`redis`](https://hub.docker.com/_/redis) — Redis, Docker Hub official image

All four are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag — and `git pull` alone delivers the version combination this repository has tested, because the pins live in the tracked compose file rather than in your `.env`. Setting an `*_IMAGE_TAG` variable in `.env` overrides the default when you deliberately want a different version.

The weekly `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Nextcloud and Traefik versions against the latest upstream releases — any drift fails the run and notifies the maintainer. CI's **Deployment Verification** workflow runs on every push, pull request, and every Monday at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot's `github-actions` ecosystem keeps those fresh.

## Production checklist

Before exposing this to real users, check every box:

- [ ] **Strong secrets everywhere.** `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` at 24+ random characters; regenerate the Traefik dashboard BCrypt hash per deployment.
- [ ] **Enable cron background jobs** in the admin UI (section above).
- [ ] **Host-mount the backup volumes.** Named volumes die with the host — bind-mount `POSTGRES_BACKUPS_PATH` and `DATA_BACKUPS_PATH` to host paths covered by your off-host backup solution (restic, rclone, Borg, S3 sync).
- [ ] **Verify Let's Encrypt cert issuance** in the Traefik logs on first start.
- [ ] **Plan your upgrade path.** Nextcloud upgrades one major at a time — see the upgrade note below before pulling a newer template version onto an old instance.
- [ ] **Know the restore procedure.** Run both restore scripts against a test environment before you need them in production.

🔄 **Upgrading an existing deployment across majors:** Nextcloud only supports upgrading one major version at a time. If your instance runs an older major (for example 29), do not jump straight to the pinned version — step through each major by setting `NEXTCLOUD_IMAGE_TAG=nextcloud:30` in `.env`, running `docker compose pull && docker compose up -d`, waiting for the upgrade to finish, then repeating for 31, 32, 33, 34. Take a database backup before you start. Once you reach the pinned major, remove `NEXTCLOUD_IMAGE_TAG` from `.env` to switch to repo-managed versions.

## Backups

The `backups` container performs a dump → archive → prune → sleep loop:

Each cycle logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the same for the data archive where there is one). A failed dump is kept as `<file>.failed` for diagnosis and never overwrites a good backup — grep the log for `FAILED` from your monitoring.

1. **Database** — `pg_dump` of the Nextcloud database piped through `gzip`, timestamp-named.
2. **Application data** — `tar.gz` of the Nextcloud data directory (files, uploads).
3. **Prune** — deletes database backups older than `POSTGRES_BACKUP_PRUNE_DAYS` and data backups older than `DATA_BACKUP_PRUNE_DAYS` (both default 7).
4. **Sleep** — waits `BACKUP_INTERVAL` (default 24h) before the next cycle.

All knobs are configured via `.env` with compose-level defaults (30-minute warm-up, 24-hour interval, 7-day retention).

**Verify backups are running:**

```bash
docker compose -p nextcloud logs backups | tail -5
docker compose -p nextcloud exec backups sh -c 'ls -la /srv/nextcloud-postgres/backups/ /srv/nextcloud-application-data/backups/'
```

## Restoring backups

Two interactive scripts handle the restore flows. Make them executable once (`chmod +x *.sh`), then run from the repository root:

- **`nextcloud-restore-database.sh`** — lists available database backups, prompts for a selection, stops Nextcloud, drops and recreates the database, restores the chosen dump, and starts Nextcloud again.
- **`nextcloud-restore-application-data.sh`** — same guided flow for the application-data archives: stops Nextcloud, restores the chosen `tar.gz` over the data directory, starts Nextcloud.

For a full restore, run the database script first, then the application-data script, then re-scan files if needed (see [Operations](#operations)).

## Operations

Handy `occ` one-liners for day-2 operation (run as the container's `www-data`):

```bash
# Disable the skeleton files copied into new users' accounts:
docker compose -p nextcloud exec -u www-data nextcloud php occ config:system:set skeletondirectory --value=""

# Add missing database indices after upgrades (safe to run anytime):
docker compose -p nextcloud exec -u www-data nextcloud php occ db:add-missing-indices

# Re-scan files after restoring application data or editing files directly:
docker compose -p nextcloud exec -u www-data nextcloud php occ files:scan --all
```

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults — the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every Monday at 06:00 UTC:

1. **Lint** — shellcheck on both restore scripts, actionlint on the workflow.
2. **Trivy scans** of all four pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (weekly/manual) — digest drift against registries plus release-lag checks for Nextcloud and Traefik.
4. **Deploy-and-test** — boots the full stack with ephemeral credentials and waits for `status.php` to report `"installed":true` through Traefik — the shipped configuration must produce a working, fully installed Nextcloud, not just started containers — then checks the login page and the Traefik dashboard.

A green run is the authoritative proof that the template deploys end-to-end and that its backups restore. If your deploy misbehaves, compare the green CI run's logs to your own — most "doesn't work" cases trace to DNS propagation, firewall rules, or a customized `.env`.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the HTTPS smoke. The scenario that matters most is the restore roundtrip: insert a marker row, restore the earliest backup, assert the marker is gone — a backup that cannot be restored fails the build. Run it yourself against a running deployment with short intervals in `.env` (`BACKUP_INIT_SLEEP=15s`, `BACKUP_INTERVAL=60s`):

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

It stops the database container briefly to prove failure detection — run it on a staging copy, not on production.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- **Pre-rotation advisory.** Releases before v1.0.0 (2026-08-31) shipped a tracked `.env` with generated-looking credential values. Anyone who deployed without changing them should rotate `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD`, and the Traefik dashboard hash.
- HSTS headers and CalDAV/CardDAV redirects are preconfigured on the Traefik router.
- Upstream image digests are pinned; the weekly freshness job flags drift loudly.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>

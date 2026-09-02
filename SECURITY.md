# Security Policy

## Supported Versions

| Version                                        | Status             |
|------------------------------------------------|--------------------|
| Current `main` and the latest tagged release   | :white_check_mark: |
| Older tags without a recent rebuild            | :x:                |

Fixes land on `main` and ship as a new tag; older tags are not patched in place.

## Reporting a Vulnerability

Send reports to **v@valdemar.ai**. Encrypted email is preferred; the PGP public key is published at [heyvaldemar.com/security](https://heyvaldemar.com/security).

You can expect an acknowledgment within **7 days**. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit in the release notes and the changelog.

Please do not open public GitHub issues for security reports.

## Supply Chain Trust

This repository publishes a **deployment template**, not a custom software distribution. Upstream images are pinned by `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block, so a plain `git pull` delivers the exact combination this repository has tested. The Deployment Verification workflow re-resolves every pin daily and boots the full stack on every change; drift or breakage fails the run and notifies the maintainer. GitHub Actions are pinned by commit SHA.

The README's "Supply chain trust" section lists the upstream images and where they come from.

## Credentials

`.env` is gitignored and required variables fail fast at deploy time. If a repository ever tracked real credential values in its history, the README's "Security Notes" section carries a pre-rotation advisory with the exact rotation procedure.

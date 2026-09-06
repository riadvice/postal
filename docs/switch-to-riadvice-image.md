# Switching from `postalserver/postal` to `riadvice/postal`

This is a guide for existing Postal installations that want to switch their
running image from the official `postalserver/postal` image to this fork's
`riadvice/postal` image (published to Docker Hub), **without changing
anything else** — same config file, same database, same volumes, same
environment variables.

This fork's `Dockerfile` is a drop-in replacement: the entrypoint, expected
volumes, environment variables and `postal` CLI are unchanged from upstream.
Switching is just a matter of changing which image tag your deployment pulls.

## Before you start

- **Back up your database.** Use your existing backup process, or a plain
  `mysqldump`/`mariadb-dump` of the main Postal database and each
  `postal-server-*` message database. This is standard practice for any
  Postal version change, not specific to this switch.
- **Note your current image tag** (e.g. `postalserver/postal:stable` or a
  pinned version) so you can roll back by simply pointing back at it.

## Automated option

[`scripts/switch-to-riadvice-image.sh`](../scripts/switch-to-riadvice-image.sh)
does steps 2–4 below for you: it finds your `docker-compose.yml`'s image
reference (or a `POSTAL_IMAGE` variable in a neighbouring `.env` file), shows
you the exact one-line change, asks for confirmation, then pulls, runs
`postal upgrade`, and restarts.

```bash
./scripts/switch-to-riadvice-image.sh stable /path/to/docker-compose.yml
```

It only ever changes that one image reference — nothing else in your compose
file, config, or volumes. If it can't confidently find the image line, it
makes no changes and points you back at the manual steps below. Run it from
this repo (or copy it alongside your own `docker-compose.yml`).

## Manual steps

## 1. Pull the new image

```bash
docker pull riadvice/postal:stable
```

Other tags are also published: `latest` (tracks `main`), `branch-<name>` for
non-main branches, and `<version>` for a specific release — pick whichever
matches how you're currently pinning the upstream image.

## 2. Change only the image reference

Edit your `docker-compose.yml` (or Kubernetes manifest, or systemd unit,
whatever you use to run Postal) and change **only** the image name —
`postalserver/postal:...` → `riadvice/postal:...`. Do not touch:

- Your config volume / `postal.yml` (or environment-variable configuration)
- The database service or its volume
- Any other environment variables

If you use this repo's own `docker-compose.yml` pattern (image name driven
by a `POSTAL_IMAGE` variable), just update that variable.

## 3. Run the upgrade step

Before restarting the long-running services, run Postal's own upgrade
command so any pending database schema migration is applied first. This is
the same command you'd run for any Postal version upgrade — it's a no-op if
there's nothing pending:

```bash
docker compose run --rm postal postal upgrade
```

## 4. Restart the app containers

```bash
docker compose up -d
```

Do **not** run `docker compose down -v` or anything that removes volumes —
this is a plain container restart with a different image.

## 5. Rollback

Since this is a same-codebase, different-registry switch, rolling back is
just pointing the image reference back at your previous
`postalserver/postal` tag and restarting — there's no data to undo in the
common case.

This changes if a later `riadvice/postal` release you've moved to is ahead
of what you were previously running (i.e. it shipped its own new database
migrations) — in that case, restore from the backup taken in step 1 before
rolling back the image, since the schema may have moved forward.

# Switching from `postalserver/postal` to `riadvice/postal`

This is a guide for existing Postal installations that want to switch their
running image from the official `postalserver/postal` image to this fork's
`riadvice/postal` image (published to Docker Hub), **without changing
anything else** — same config file, same database, same volumes, same
environment variables.

This fork's `Dockerfile` is a drop-in replacement: the entrypoint, expected
volumes, environment variables and `postal` CLI are unchanged from upstream.
Switching is just a matter of changing which image tag your deployment pulls.

## Which tags exist

This is the part that catches people out, so it comes first.

`riadvice/postal` publishes:

| Tag | What it is |
| --- | --- |
| `stable` | The most recent `x.y.z` release tag. Recommended. |
| `<x.y.z>` | A specific release, e.g. `3.4.0`. |
| `latest` | Whatever is on `main`. |
| `branch-<name>` | The head of another branch. |

**Upstream's version numbers are not republished here.** This fork's releases
have their own numbering, so a version that exists on `postalserver/postal`
(say `3.3.7`) will usually not exist on `riadvice/postal`, and pulling it
fails with `manifest unknown`.

That matters because the official host-side installer (`/opt/postal/install`,
the thing that provides `postal start` / `postal upgrade` / `postal
set-version`) has a `get-latest-postal-version` helper hardcoded to
`https://api.github.com/repos/postalserver/postal/releases/latest`. Any command
that has to work out "the latest version" for itself — a bare `postal upgrade`,
or `postal start` regenerating a missing `docker-compose.yml` — asks *upstream*,
gets an upstream version number, and writes `riadvice/postal:<upstream
version>` into your compose file. That tag does not exist, so every service
fails to pull. (Only the first failure is interesting: once one service's pull
fails, Compose cancels the rest, and they log `context canceled` rather than a
problem of their own.)

The fix is to never let anything derive the version: the compose file and the
installer's template both get an **explicit, literal** `riadvice/postal` tag.
The script below does that, and refuses to write a tag Docker Hub does not
actually serve.

> After switching, do not run a bare `postal upgrade` on the host. It will
> re-derive the version from upstream's release feed and reintroduce exactly
> this breakage. Re-run the switch script to move between tags instead.

## Before you start

- **Back up your database.** Use your existing backup process, or a plain
  `mysqldump`/`mariadb-dump` of the main Postal database and each
  `postal-server-*` message database. This is standard practice for any
  Postal version change, not specific to this switch.
- **Note your current image tag** (e.g. `postalserver/postal:stable` or a
  pinned version) so you can roll back by simply pointing back at it.

## Automated option

[`scripts/switch-to-riadvice-image.sh`](../scripts/switch-to-riadvice-image.sh)
does everything in the manual section below. It needs nothing from this
repository at runtime, so it can be run straight from a checkout or piped from
GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/riadvice/postal/main/scripts/switch-to-riadvice-image.sh | sudo bash
```

Look before you leap — this shows the exact changes and writes nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/riadvice/postal/main/scripts/switch-to-riadvice-image.sh | sudo bash -s -- --dry-run
```

Pin a specific release, and skip the prompt (needed for unattended runs):

```bash
curl -fsSL https://raw.githubusercontent.com/riadvice/postal/main/scripts/switch-to-riadvice-image.sh | sudo bash -s -- --tag 3.4.0 --yes
```

Useful options: `--tag`, `--compose-file`, `--yes`, `--dry-run`,
`--no-restart`, `--help`.

What it does, in order:

1. Finds your `docker-compose.yml` — `./docker-compose.yml`,
   `/opt/postal/config/docker-compose.yml` or `/opt/postal/docker-compose.yml`
   unless you pass `--compose-file`.
2. Checks the tag against Docker Hub **before touching anything**, and if it
   is not published, stops and prints the tags that are. A registry it cannot
   reach is not treated as a missing tag.
3. Rewrites every `image:` (and `POSTAL_IMAGE=` in a neighbouring `.env`)
   reference to `postalserver/postal` or `riadvice/postal` — with or without a
   `ghcr.io`/`docker.io` prefix, with or without a tag — to your chosen
   `riadvice/postal:<tag>`. Only `image:`/`POSTAL_IMAGE=` lines are touched;
   nothing else in the file is.
4. If the official installer is present, rewrites its compose **template**
   too, replacing the `{{version}}` placeholder with the literal tag. Without
   this step the next `postal start` re-renders the template and silently
   reverts the switch.
5. Pulls the image, then edits (keeping a `.bak` of every file it changed).
6. Verifies afterwards that no `postalserver/postal` reference and no
   mismatched `riadvice/postal` tag survives; if one does, it stops and tells
   you to restore the backups.
7. Runs the database upgrade through the *in-container* CLI (`docker compose
   run --rm runner postal upgrade`), never the host `postal upgrade`, then
   `docker compose up -d`.

It only ever changes image references. If it can't confidently find one, it
makes no changes and points you back at the manual steps below.

## Manual steps

### 1. Pull the new image

```bash
docker pull riadvice/postal:stable
```

Pick the tag from the table at the top of this page.

### 2. Change only the image reference

Edit your `docker-compose.yml` (or Kubernetes manifest, or systemd unit,
whatever you use to run Postal) and change **only** the image name —
`postalserver/postal:...` → `riadvice/postal:...`, on every service that runs
Postal (typically `web`, `smtp`, `worker` and `runner`). Do not touch:

- Your config volume / `postal.yml` (or environment-variable configuration)
- The database service or its volume
- Any other environment variables

If you use this repo's own `docker-compose.yml` pattern (image name driven
by a `POSTAL_IMAGE` variable), just update that variable.

### 3. Pin the template if you used the official installer

If `/opt/postal/install` exists, the compose file you just edited is generated
from a template and will be regenerated behind your back. Edit the template's
image line the same way, replacing the whole reference — `{{version}}`
placeholder included — with a literal `riadvice/postal:<tag>`. That is what
stops `get-latest-postal-version` from ever picking the tag for you.

### 4. Run the upgrade step

Before restarting the long-running services, run Postal's own upgrade
command so any pending database schema migration is applied first. This is
the same command you'd run for any Postal version upgrade — it's a no-op if
there's nothing pending:

```bash
docker compose run --rm runner postal upgrade
```

`runner` is the one-off service in the official Postal install; if you use a
compose file based on this repository's, the service is called `postal`. Note
that this is the CLI *inside the container*, which only runs migrations — it is
not the host `postal upgrade`, which also rewrites your compose file from
upstream's release feed.

### 5. Restart the app containers

```bash
docker compose up -d
```

Do **not** run `docker compose down -v` or anything that removes volumes —
this is a plain container restart with a different image.

### 6. Check it actually came up

```bash
docker compose ps
docker compose logs --tail 50 worker
```

All four Postal services should be running on the tag you chose. A stopped
`worker` is worth catching here: while it is down, messages are accepted but
never dequeued, so they sit in the queue as `Pending` with no error recorded
against them.

## Rollback

Since this is a same-codebase, different-registry switch, rolling back is
just pointing the image reference back at your previous
`postalserver/postal` tag and restarting — there's no data to undo in the
common case. The script keeps a `.bak` of every file it edited, so restoring
those and running `docker compose up -d` is enough.

This changes if a later `riadvice/postal` release you've moved to is ahead
of what you were previously running (i.e. it shipped its own new database
migrations) — in that case, restore from the backup taken before you started
before rolling back the image, since the schema may have moved forward.

#!/usr/bin/env bash
#
# Switches a docker-compose deployment from postalserver/postal to riadvice/postal.
# Runs on the host, see docs/switch-to-riadvice-image.md.
#
# Can be run straight from a checkout or piped from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/riadvice/postal/main/scripts/switch-to-riadvice-image.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/riadvice/postal/main/scripts/switch-to-riadvice-image.sh | sudo bash -s -- --tag 3.3.7-riadvice --yes
#
set -euo pipefail

REPOSITORY="riadvice/postal"
TAG="stable"
COMPOSE_FILE=""
ASSUME_YES=0
DRY_RUN=0
RESTART=1

usage() {
  cat <<'USAGE'
Usage: switch-to-riadvice-image.sh [options] [tag] [compose-file]

Options:
  -t, --tag TAG            Tag of riadvice/postal to switch to (default: stable)
  -f, --compose-file PATH  docker-compose.yml to edit (default: autodetected)
  -y, --yes                Do not prompt for confirmation
      --dry-run            Show what would change, write nothing
      --no-restart         Edit the files but do not run upgrade/restart
  -h, --help               Show this message

Tags published for riadvice/postal are 'stable' (latest release), 'latest'
(tracks main), 'branch-<name>' and each release. Releases are named after the
upstream version they are based on with a -riadvice suffix, e.g. '3.3.7-riadvice'
or '3.3.7-riadvice.2'. Upstream's own version numbers are NOT published here, so
always pick from this list — the script checks the tag against Docker Hub before
touching anything.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    -f|--compose-file) COMPOSE_FILE="${2:?--compose-file needs a value}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    # Positional form kept for compatibility with the first version of this script
    *)
      if [ "$TAG" = "stable" ] && [ -z "$COMPOSE_FILE" ]; then TAG="$1"
      elif [ -z "$COMPOSE_FILE" ]; then COMPOSE_FILE="$1"
      else echo "Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

NEW_IMAGE="${REPOSITORY}:${TAG}"

abort() { echo "$@" >&2; exit 1; }

if ! [[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
  abort "${TAG} is not a valid docker tag."
fi

# Ask the user, reading from the terminal rather than stdin so that the script
# still works when it is piped into bash.
confirm() {
  if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if [ ! -r /dev/tty ]; then
    abort "No terminal available to confirm on. Re-run with --yes (or --dry-run first)."
  fi

  local answer
  read -r -p "$1 [y/N] " answer < /dev/tty
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Locate the deployment
# ---------------------------------------------------------------------------

find_compose_file() {
  local candidate
  for candidate in \
    "${PWD}/docker-compose.yml" \
    /opt/postal/config/docker-compose.yml \
    /opt/postal/docker-compose.yml \
    /opt/postal/install/docker-compose.yml
  do
    if [ -f "$candidate" ]; then echo "$candidate"; return 0; fi
  done
  return 1
}

if [ -z "$COMPOSE_FILE" ]; then
  COMPOSE_FILE="$(find_compose_file)" || abort \
    "Could not find a docker-compose.yml. Pass one with --compose-file /path/to/docker-compose.yml."
  echo "Using compose file: ${COMPOSE_FILE}"
fi

[ -f "$COMPOSE_FILE" ] || abort "Could not find ${COMPOSE_FILE}"

COMPOSE_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd)"
COMPOSE_FILE="${COMPOSE_DIR}/$(basename "$COMPOSE_FILE")"
ENV_FILE="${COMPOSE_DIR}/.env"

# The official installer keeps a docker-compose template that it re-renders on
# every 'postal start' / 'postal upgrade'. If we only edit the rendered file the
# change is silently reverted the next time either command runs.
INSTALL_ROOT=""
for candidate in /opt/postal/install "${COMPOSE_DIR}/install" "${COMPOSE_DIR}/../install"; do
  if [ -d "$candidate" ]; then INSTALL_ROOT="$(cd "$candidate" && pwd)"; break; fi
done

# ---------------------------------------------------------------------------
# Check the tag exists before changing anything
# ---------------------------------------------------------------------------

DOCKER_HUB="https://hub.docker.com/v2/repositories/${REPOSITORY}"

# 0 = published, 1 = definitely not published, 2 = could not check
tag_exists() {
  command -v curl >/dev/null 2>&1 || return 2

  local code
  code="$(curl -fsSL -o /dev/null -w '%{http_code}' "${DOCKER_HUB}/tags/${TAG}" 2>/dev/null || true)"
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

published_tags() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL "${DOCKER_HUB}/tags?page_size=100" 2>/dev/null |
    tr ',' '\n' | sed -nE 's/.*"name":"([^"]+)".*/\1/p' | sort -u | tr '\n' ' '
}

echo "Checking that ${NEW_IMAGE} exists on Docker Hub..."
if tag_exists; then
  echo "  ok, ${NEW_IMAGE} is published"
else
  status=$?
  if [ "$status" -ne 1 ]; then
    echo "  could not reach Docker Hub, skipping the registry check (docker pull will catch a bad tag)"
  else
    echo >&2
    echo "${NEW_IMAGE} does not exist on Docker Hub." >&2
    echo >&2
    echo "This is the failure behind 'manifest unknown': upstream Postal version" >&2
    echo "numbers are not republished under ${REPOSITORY}. Published tags are:" >&2
    echo "  $(published_tags)" >&2
    echo >&2
    echo "Re-run with one of those, e.g. --tag stable" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Work out what to rewrite
# ---------------------------------------------------------------------------

# Matches postalserver/postal and riadvice/postal, with or without a registry
# prefix and with or without a tag (including the installer's '{{version}}'
# placeholder), and replaces the whole reference with an explicit image and tag.
# Only ever applied to 'image:' and 'POSTAL_IMAGE=' lines.
IMAGE_EXPR="s#([A-Za-z0-9.:-]+/)?(postalserver|riadvice)/postal(:[^[:space:]\"']*)?#${NEW_IMAGE}#g"
SED_ARGS=(-E -e "/^[[:space:]]*image:/ ${IMAGE_EXPR}" -e "/^[[:space:]]*POSTAL_IMAGE=/ ${IMAGE_EXPR}")

postal_image_lines() {
  grep -nE '^[[:space:]]*(image:|POSTAL_IMAGE=).*(postalserver|riadvice)/postal' "$1" || true
}

FILES_TO_EDIT=()
if [ -n "$(postal_image_lines "$COMPOSE_FILE")" ]; then
  FILES_TO_EDIT+=("$COMPOSE_FILE")
fi
if [ -f "$ENV_FILE" ] && [ -n "$(postal_image_lines "$ENV_FILE")" ]; then
  FILES_TO_EDIT+=("$ENV_FILE")
fi

# Add any installer template that renders a postal image reference
if [ -n "$INSTALL_ROOT" ]; then
  while IFS= read -r template; do
    if [ -n "$(postal_image_lines "$template")" ]; then FILES_TO_EDIT+=("$template"); fi
  done < <(find "$INSTALL_ROOT" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.tpl' \) 2>/dev/null | sort)
fi

if [ "${#FILES_TO_EDIT[@]}" -eq 0 ]; then
  abort "Could not find a postal image reference in ${COMPOSE_FILE}${INSTALL_ROOT:+, ${ENV_FILE} or ${INSTALL_ROOT}}.
Not making any changes — follow the manual steps in docs/switch-to-riadvice-image.md instead."
fi

echo
echo "The following image references will be changed to ${NEW_IMAGE}:"
for file in "${FILES_TO_EDIT[@]}"; do
  echo "  ${file}"
  postal_image_lines "$file" | sed 's/^/    - /'
  postal_image_lines "$file" | sed -E "${IMAGE_EXPR}" | sed 's/^/    + /'
done

if [ -n "$INSTALL_ROOT" ]; then
  echo
  echo "Detected the official installer at ${INSTALL_ROOT}. Its template is being"
  echo "pinned to an explicit ${REPOSITORY} tag so that 'postal start' and"
  echo "'postal upgrade' cannot re-derive a version from upstream's release feed."
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run, nothing was changed."
  exit 0
fi

confirm "Apply these changes?" || { echo "Aborted, nothing changed."; exit 0; }

echo "Pulling ${NEW_IMAGE} before touching anything..."
docker pull "$NEW_IMAGE"

for file in "${FILES_TO_EDIT[@]}"; do
  sed -i.bak "${SED_ARGS[@]}" "$file"
  echo "Updated ${file} (previous version kept at ${file}.bak)"
done

# Anything left pointing at an image we did not intend is a bug, not a warning
for file in "${FILES_TO_EDIT[@]}"; do
  if grep -qE '^[[:space:]]*(image:|POSTAL_IMAGE=).*postalserver/postal' "$file"; then
    abort "postalserver/postal is still referenced in ${file} after editing. Restore ${file}.bak and switch manually."
  fi
  if grep -E '^[[:space:]]*(image:|POSTAL_IMAGE=).*riadvice/postal' "$file" | grep -qvF "$NEW_IMAGE"; then
    abort "${file} still has a riadvice/postal reference on a tag other than ${TAG}. Restore ${file}.bak and switch manually."
  fi
done
echo "Verified: every postal image reference now reads ${NEW_IMAGE}"

if [ "$RESTART" -eq 0 ]; then
  echo "--no-restart given, stopping here. Run 'docker compose up -d' when ready."
  exit 0
fi

# The official install calls the one-off service "runner", this repo's compose file "postal"
SERVICE="$(grep -oE '^[[:space:]]{2}(runner|postal):' "$COMPOSE_FILE" | head -1 | tr -d ' :' || true)"

if [ -n "$SERVICE" ]; then
  # Deliberately the in-container CLI, not the host 'postal upgrade', which
  # would ask upstream what the latest version is.
  echo "Running 'postal upgrade' (safe no-op if there's nothing pending)..."
  docker compose --file "$COMPOSE_FILE" run --rm "$SERVICE" postal upgrade
else
  echo "No 'runner' or 'postal' one-off service in ${COMPOSE_FILE}; skipping the upgrade step." >&2
  echo "Run the database upgrade yourself before serving traffic." >&2
fi

echo "Restarting..."
docker compose --file "$COMPOSE_FILE" up -d

echo
echo "Done. Postal is running ${NEW_IMAGE}."
echo
echo "Do not run a bare 'postal upgrade' on the host from here on: it resolves"
echo "'latest' against upstream's release feed and will pin a version tag that"
echo "${REPOSITORY} does not publish. Re-run this script to change tags instead."
echo
echo "To roll back, restore the .bak files listed above and run 'docker compose up -d'."

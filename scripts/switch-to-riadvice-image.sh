#!/usr/bin/env bash
#
# Switches a Postal docker-compose deployment from postalserver/postal to
# riadvice/postal, running on the HOST (not inside the container — bin/postal
# runs inside the container and has no access to the host's docker-compose.yml
# or the docker CLI, so this can't be a `postal` subcommand).
#
# Usage: ./scripts/switch-to-riadvice-image.sh [tag] [compose-file]
#   tag           Image tag to switch to (default: stable)
#   compose-file  Path to docker-compose.yml (default: ./docker-compose.yml)
#
set -euo pipefail

TAG="${1:-stable}"
COMPOSE_FILE="${2:-docker-compose.yml}"
ENV_FILE="$(dirname "$COMPOSE_FILE")/.env"
NEW_IMAGE="riadvice/postal:${TAG}"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Could not find $COMPOSE_FILE" >&2
  exit 1
fi

echo "This will switch your Postal image to ${NEW_IMAGE}."
echo "See docs/switch-to-riadvice-image.md for what this does and does not touch."
echo

if grep -q '\${POSTAL_IMAGE}' "$COMPOSE_FILE" && [ -f "$ENV_FILE" ] && grep -q '^POSTAL_IMAGE=' "$ENV_FILE"; then
  OLD_LINE="$(grep '^POSTAL_IMAGE=' "$ENV_FILE")"
  echo "Found POSTAL_IMAGE in ${ENV_FILE}:"
  echo "  - ${OLD_LINE}"
  echo "  + POSTAL_IMAGE=${NEW_IMAGE}"
  TARGET_FILE="$ENV_FILE"
  SED_EXPR="s#^POSTAL_IMAGE=.*#POSTAL_IMAGE=${NEW_IMAGE}#"
elif grep -qE 'image:\s*.*postalserver/postal' "$COMPOSE_FILE"; then
  OLD_LINE="$(grep -E 'image:\s*.*postalserver/postal' "$COMPOSE_FILE")"
  echo "Found in ${COMPOSE_FILE}:"
  echo "  - ${OLD_LINE}"
  echo "  + $(echo "$OLD_LINE" | sed -E "s#[a-z0-9./]*postalserver/postal:[A-Za-z0-9._-]+#${NEW_IMAGE}#")"
  TARGET_FILE="$COMPOSE_FILE"
  SED_EXPR="s#[a-z0-9./]*postalserver/postal:[A-Za-z0-9._-]+#${NEW_IMAGE}#"
else
  echo "Could not confidently find a postalserver/postal image reference in" >&2
  echo "${COMPOSE_FILE} or ${ENV_FILE}. Not making any changes — follow the" >&2
  echo "manual steps in docs/switch-to-riadvice-image.md instead." >&2
  exit 1
fi

echo
read -r -p "Apply this change and restart Postal? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted, nothing changed."
  exit 0
fi

sed -i.bak -E "$SED_EXPR" "$TARGET_FILE"
rm -f "${TARGET_FILE}.bak"

echo "Updated ${TARGET_FILE}. Pulling the new image..."
docker compose --file "$COMPOSE_FILE" pull

echo "Running 'postal upgrade' (safe no-op if there's nothing pending)..."
docker compose --file "$COMPOSE_FILE" run --rm postal postal upgrade

echo "Restarting..."
docker compose --file "$COMPOSE_FILE" up -d

echo
echo "Done. To roll back, restore ${TARGET_FILE} from its previous value and re-run"
echo "'docker compose up -d' — see docs/switch-to-riadvice-image.md for details."

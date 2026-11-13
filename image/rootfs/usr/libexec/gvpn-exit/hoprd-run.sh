#!/usr/bin/env bash
# ExecStart wrapper for hoprd.service.
#
# hoprd takes its identity password and API token as values (HOPRD_PASSWORD,
# HOPRD_API_TOKEN), not as file paths. systemd delivers both as decrypted
# credentials on a per-service tmpfs ($CREDENTIALS_DIRECTORY); this wrapper
# reads them into the environment and execs hoprd, so the plaintext never
# touches persistent storage. The process environment is readable only by
# root and the hoprd uid.
#
# The v5 identity is a copy in the service's runtime directory, not the v4
# credential file itself. hoprd opens its identity file read/write, so pointing
# it at the v4 file would let a v5 start overwrite the only copy of the identity
# the v4 migration helper still needs. The sealed source credential is never
# modified; the copy is recreated on every start.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

HOPRD_BIN="${HOPRD_BIN:-/usr/bin/hoprd}"

if [[ -z "${CREDENTIALS_DIRECTORY:-}" ]]; then
  echo "CREDENTIALS_DIRECTORY is not set; run via hoprd.service" >&2
  exit 1
fi
if [[ -z "${RUNTIME_DIRECTORY:-}" ]]; then
  echo "RUNTIME_DIRECTORY is not set; run via hoprd.service" >&2
  exit 1
fi

# Print a credential's value without its trailing newline; fail if missing or empty.
read_credential() {
  local name="$1" value
  if [[ ! -s "${CREDENTIALS_DIRECTORY}/${name}" ]]; then
    echo "credential ${name} is missing or empty" >&2
    return 1
  fi
  value="$(< "${CREDENTIALS_DIRECTORY}/${name}")"
  printf '%s' "${value}"
}

HOPRD_PASSWORD="$(read_credential hoprd.password)"
HOPRD_API_TOKEN="$(read_credential hoprd.api-token)"
export HOPRD_PASSWORD HOPRD_API_TOKEN

# A fresh copy each start: systemd clears the runtime directory on restart, so
# this is the v5 identity for this run and never a stale one. 0600 because the
# hoprd uid may have to migrate the keystore in place; the v4 source is separate.
HOPRD_IDENTITY="${RUNTIME_DIRECTORY}/hopr-v5.id"
cp "${CREDENTIALS_DIRECTORY}/hopr.id" "${HOPRD_IDENTITY}"
chmod 0600 "${HOPRD_IDENTITY}"
export HOPRD_IDENTITY

# The PIX pool's blokli_url lives in the strategy stanza, which no environment
# variable overrides. Render the current image template into the runtime
# directory on every start, so the node uses the provisioned endpoint in both
# places without a stale copy in /etc surviving across updates.
HOPRD_CFG="${RUNTIME_DIRECTORY}/hoprd.cfg.yaml"
if ! render_hoprd_config "${HOPRD_BLOKLI_URL:-}" "${HOPRD_CFG}"; then
  # The service condition guarantees the provisioning file exists; a missing
  # or unusable Blokli URL is a configuration error, not a reason to start the
  # PIX pool against the placeholder in the image template.
  log "ERROR cannot render the hoprd configuration; HOPRD_BLOKLI_URL is missing or invalid"
  exit 1
fi

exec "${HOPRD_BIN}" --configurationFilePath "${HOPRD_CFG}" "$@"

#!/usr/bin/env bash
# Build-time snapshot of the blocklist feeds, parsed and bounds-checked with
# the same functions the device uses, so a device that never reaches the feed
# host still boots with a populated set.
#
#   snapshot-blocklist.sh ROOTFS OUTPUT
set -euo pipefail

rootfs="$1"
output="$2"
export GVPN_EXIT_DEFAULTS="${rootfs}/usr/share/gvpn-exit/exit.env"
export GVPN_EXIT_OVERRIDES=/nonexistent

# shellcheck source=SCRIPTDIR/../rootfs/usr/libexec/gvpn-exit/gvpn-blocklist-update.sh
source "${rootfs}/usr/libexec/gvpn-exit/gvpn-blocklist-update.sh"

all="$(mktemp)"
for url in "${FEEDS[@]}"; do
  # The feed URL is https, but a redirect is not bound by that, so the request
  # and every redirect are pinned to https (exit.env).
  curl -fsSL --proto =https --proto-redir =https --max-time "${CURL_TIMEOUT}" \
    --max-filesize "${MAX_FILESIZE}" --retry 3 "${url}" | parse_feed >> "${all}"
done
sort -u "${all}" -o "${all}"
count_within_bounds "$(wc -l < "${all}")"
coverage_within_bounds "${all}"
install -m 0644 "${all}" "${output}"
rm -f "${all}"
echo "blocklist snapshot: $(wc -l < "${output}") entries"

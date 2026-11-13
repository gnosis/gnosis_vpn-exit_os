#!/usr/bin/env bash
# Time box for the support tunnel.
#
#   check    ExecCondition of support-tunnel.service. Exit 0 only if
#            state/support-until holds a parsable RFC3339 deadline, the clock
#            is NTP-synchronized and now < deadline. Anything else exits 1 and
#            the tunnel stays down: the file existing is never enough.
#   enforce  support-tunnel-expire.timer (every 5 min). A recovery request left
#            by the recovery stick (docs/recovery.md) is consumed first: it is
#            a day count, and only a trusted clock may turn it into a deadline
#            and the expiry of the keys the stick added. The run holds the
#            support window's lock, which `gvpn-exit-support` also takes, so a
#            close cannot land between the request being read and the window
#            being written.
#            If check passes, start the tunnel (a no-op while it runs): at boot
#            the tunnel's own check usually runs before NTP syncs and skips it,
#            and this is what brings it up once the clock is trusted. If check
#            fails, stop the tunnel explicitly (kills autossh and its ssh
#            child). An unparsable window, or one a synchronized clock finds
#            expired, is deleted as bookkeeping; a valid window survives an
#            unsynced clock, ahead or behind, and reopens once NTP syncs.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

SUPPORT_UNTIL="${GVPN_STATE_DIR}/support-until"
DEVOPS_KEYS="${GVPN_DEVOPS_AUTHORIZED_KEYS:-/var/home/devops/.ssh/authorized_keys}"

# Deadline as epoch seconds; fails if the file is missing or unparsable.
deadline_epoch() {
  local until
  [[ -s "${SUPPORT_UNTIL}" ]] || return 1
  until="$(< "${SUPPORT_UNTIL}")"
  date -d "${until}" +%s 2>/dev/null
}

# retime_recovery_keys EXPIRY
# The keys a recovery stick added carry an expiry-time computed from the RTC,
# like the deadline it wrote. Move it to EXPIRY on the lines that carry the
# stick's marker and leave every other line alone. The file is rewritten in
# place, never replaced, so its owner, mode and SELinux label stay.
retime_recovery_keys() {
  local expiry="$1" tmp
  [[ -f "${DEVOPS_KEYS}" ]] || return 0
  tmp="$(mktemp)"
  sed -E "s/^expiry-time=\"[0-9]+Z\"( [^ ]+ [^ ]+ gvpn-recovery-[0-9]+)$/expiry-time=\"${expiry}\"\\1/" \
    "${DEVOPS_KEYS}" >"${tmp}"
  cat "${tmp}" >"${DEVOPS_KEYS}"
  rm -f "${tmp}"
}

# A recovery stick cannot trust the appliance's clock, so it writes the day
# count to state/recovery-request and lets this timer write the deadline, and
# the expiry of the keys it added, at the first NTP-synchronized run. The
# request is dropped only after both were written, so a boot without a synced
# clock simply tries again.
consume_recovery_request() {
  local request="${GVPN_STATE_DIR}/recovery-request" days deadline_at deadline
  [[ -s "${request}" ]] || return 0
  if ! ntp_synchronized; then
    log "recovery request pending: the clock is not NTP-synchronized"
    return 0
  fi
  days="$(< "${request}")"
  if [[ ! "${days}" =~ ^[1-9][0-9]*$ ]] || ((days > GVPN_SUPPORT_MAX_DAYS)); then
    log "dropping a recovery request with an invalid day count: ${days}"
    rm -f "${request}"
    return 0
  fi
  deadline_at=$(( $(now_epoch) + days * 86400 ))
  deadline="$(date -u -d "@${deadline_at}" +%Y-%m-%dT%H:%M:%SZ)"
  echo "${deadline}" | write_atomic "${SUPPORT_UNTIL}"
  retime_recovery_keys "$(date -u -d "@${deadline_at}" +%Y%m%d%H%MZ)"
  rm -f "${request}"
  log "recovery request opened the support window until ${deadline}"
}

check() {
  local deadline
  if ! deadline="$(deadline_epoch)"; then
    log "support window closed: ${SUPPORT_UNTIL} missing or unparsable"
    return 1
  fi
  if ! ntp_synchronized; then
    log "support window not trusted: clock is not NTP-synchronized"
    return 1
  fi
  if (( $(now_epoch) >= deadline )); then
    log "support window expired at $(< "${SUPPORT_UNTIL}")"
    return 1
  fi
  log "support window open until $(< "${SUPPORT_UNTIL}")"
}

enforce() {
  local deadline
  lock_support_window
  consume_recovery_request
  if check; then
    systemctl start support-tunnel.service
    return 0
  fi
  systemctl stop support-tunnel.service
  if ! deadline="$(deadline_epoch)" || { ntp_synchronized && (( $(now_epoch) >= deadline )); }; then
    rm -f "${SUPPORT_UNTIL}"
  fi
}

main() {
  case "${1:-}" in
    check) check ;;
    enforce) enforce ;;
    *) echo "usage: ${0} check|enforce" >&2; exit 64 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

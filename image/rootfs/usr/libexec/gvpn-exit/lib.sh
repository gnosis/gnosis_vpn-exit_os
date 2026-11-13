#!/usr/bin/env bash
# Shared helpers for the gvpn-exit scripts. Sourced, never executed.
#
# Every path is overridable through the environment so the same code runs on
# the device, in the bats unit suites and in the QEMU integration tests.

GVPN_EXIT_DEFAULTS="${GVPN_EXIT_DEFAULTS:-/usr/share/gvpn-exit/exit.env}"
GVPN_EXIT_OVERRIDES="${GVPN_EXIT_OVERRIDES:-/etc/gvpn-exit/exit.env}"
GVPN_STATE_DIR="${GVPN_STATE_DIR:-/var/lib/gvpn-exit/state}"
GVPN_IDENTITY_DIR="${GVPN_IDENTITY_DIR:-/var/lib/gvpn-exit/identity}"
GVPN_CREDS_DIR="${GVPN_CREDS_DIR:-/var/lib/gvpn-exit/creds}"
GVPN_RUN_DIR="${GVPN_RUN_DIR:-/run/gvpn-exit}"

# hoprd v5 keeps its database and snapshots apart from the v4 ones. The v4
# database at /var/lib/hoprd is what a rollback and the migration helper need,
# so the v5 service never writes it; only gvpn-exit-hoprd-migrate does, when it
# runs the bundled hoprd-v4 there to redeem tickets and close channels.
# Snapshots of the v5 database use their
# own directory as well; a rollback to the v4 deployment restores the snapshot
# update-apply.sh took there under the v4 path.
GVPN_HOPRD_DATA="${GVPN_HOPRD_DATA:-/var/lib/hoprd-v5}"
GVPN_HOPRD_SNAPSHOTS="${GVPN_HOPRD_SNAPSHOTS:-/var/lib/hoprd-v5.snapshots}"
# The v4 database, identity credentials and provisioning file, read by
# gvpn-exit-hoprd-migrate and, as a status fallback before migration, by
# checks.sh and gvpn-exit-status.
GVPN_HOPRD_V4_DATA="${GVPN_HOPRD_V4_DATA:-/var/lib/hoprd}"
GVPN_HOPRD_V4_SNAPSHOTS="${GVPN_HOPRD_V4_SNAPSHOTS:-/var/lib/hoprd.snapshots}"
GVPN_HOPRD_V4_ENV_DIR="${GVPN_HOPRD_V4_ENV_DIR:-/etc/hoprd/hoprd.env.d}"
# Provisioning values for hoprd v5. A fresh device writes only this file. An
# upgraded device also still has the v4 file below it; the service condition
# keeps hoprd stopped until this file exists and then the v5 file wins.
GVPN_HOPRD_ENV_DIR="${GVPN_HOPRD_ENV_DIR:-/etc/hoprd-v5/hoprd.env.d}"

# Schema of the uplink sample that capacity.sh writes to capacity_file().
GVPN_CAPACITY_SCHEMA=1

# Longest support window `gvpn-exit-support extend` and a recovery request may
# open. The tool and the timer enforce the same bound.
GVPN_SUPPORT_MAX_DAYS="${GVPN_SUPPORT_MAX_DAYS:-90}"

log() {
  echo "$*" >&2
}

# Path of the uplink sample and probe outcome written by capacity.sh.
capacity_file() {
  echo "${GVPN_CAPACITY_ENV:-${GVPN_STATE_DIR}/capacity.env}"
}

# render_hoprd_config URL [DEST]
# Copy the image hoprd configuration with every blokli_url entry replaced by
# URL. The PIX pool has its own blokli_url inside the strategy, and hoprd has
# no environment override for it, so hoprd-run.sh renders a per-start copy of
# the configuration instead of relying on the env var alone. The indentation of
# each entry is preserved.
render_hoprd_config() {
  local url="$1" dest="${2:-${GVPN_HOPRD_CFG_DEVICE:-/run/hoprd/hoprd.cfg.yaml}}"
  local template="${GVPN_HOPRD_CFG_TEMPLATE:-/usr/share/gvpn-exit/hoprd.cfg.yaml}" tmp
  https_url_ok "${url}" || return 1
  [[ -r "${template}" ]] || return 1
  mkdir -p "$(dirname "${dest}")" || return 1
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  if ! awk -v url="${url}" '
      /^[[:space:]]*blokli_url:[[:space:]]/ {
        match($0, /^[[:space:]]*/)
        print substr($0, 1, RLENGTH) "blokli_url: " url
        next
      }
      { print }
    ' "${template}" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${dest}"
}

# The provisioning env file: the v5 file when it exists, otherwise the v4 one
# that status and the check helpers report until the migration writes v5.
hoprd_env_file() {
  local file
  for file in "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" \
      "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env"; do
    if [[ -f "${file}" ]]; then
      echo "${file}"
      return 0
    fi
  done
  return 1
}

# Take over the operator's overrides from /etc/gvpn-exit/exit.env, which
# survives a rollback, without letting a broken file take down everything that
# loads them: the firewall, and with it sshd and both tunnels.
#
# The file is evaluated once, in a subshell that already holds the image
# defaults, so it can build on them the way sourcing it after the defaults
# always could: `GVPN_BLOCKLIST_FEEDS="${GVPN_BLOCKLIST_FEEDS} https://mirror"`,
# `export`, `+=`, several assignments on one line. What it changes is then taken
# over here, and a file that does not parse or whose commands fail leaves every
# default in place: a bad override costs the overrides and nothing else.
#
# Two things a sourced file could do are deliberately not taken over, because
# both turn a line in /etc into a device that cannot boot green, and /etc
# survives the rollback: `readonly` (the knob keeps its default, since a
# read-only variable in a script that derives it would fail) and `unset` (the
# knob keeps its default, since a knob that is gone makes every `set -u` reader
# of it abort). An operator who wants a knob out of the way sets it to an empty
# or benign value.
load_overrides() {
  local file="${GVPN_EXIT_OVERRIDES}" prelude dump before after line
  local -a inherited
  [[ -f "${file}" ]] || return 0
  # The subshell inherits the exported environment only, so the caller's own
  # variables are handed over: an override may build on lib.sh's directories the
  # way it could when the file was sourced in place. The list is checked first
  # because `declare -p` without a name would print the whole shell.
  inherited=("${!GVPN_@}")
  prelude=""
  (( ${#inherited[@]} == 0 )) || prelude="$(declare -p "${inherited[@]}" 2>/dev/null || true)"
  # A separate bash, because `set -e` inside a command substitution whose
  # status is being tested does not abort: only a process of its own makes a
  # failing command in the file end the evaluation. Comparing the variables
  # before and after the file catches every way it can set one, without this
  # function having to parse the file's syntax. The separator is assembled from
  # two pieces because the script text itself is one of the variables printed
  # below.
  if ! dump="$(bash -eu -c '
      eval "$3"
      source "$1"
      declare -p
      printf "@@%s@@\n" overrides
      source "$2"
      declare -p
    ' _ "${GVPN_EXIT_DEFAULTS}" "${file}" "${prelude}" 2>/dev/null)"; then
    log "WARN ${file} does not run cleanly; keeping the image defaults"
    return 0
  fi
  before="${dump%%@@overrides@@*}"
  after="${dump#*@@overrides@@}"
  while IFS= read -r line; do
    # A knob is an upper-case name: the shell's own variables (BASH_*, FUNCNAME,
    # PIPESTATUS, ...) are not, and a readonly one cannot be assigned anyway.
    [[ "${line}" =~ ^declare\ -[-a-zA-Z]*\ [A-Z_][A-Z0-9_]*= ]] || continue
    [[ "${line}" =~ ^declare\ -[-a-zA-Z]*r ]] && continue
    grep -qxF -- "${line}" <<< "${before}" && continue
    eval "declare -g ${line#declare }"
  done <<< "${after}"
}

# Source the image defaults, then the device overrides, and derive values
# that are computed from them.
load_exit_env() {
  # shellcheck source=/dev/null
  source "${GVPN_EXIT_DEFAULTS}"
  # The static ruleset and the greenboot firewall check name the self-address
  # set, so its name is an image constant: a value in /etc/gvpn-exit/exit.env
  # cannot rename it, while the rest of the file still applies.
  local self_ipset_name="${GVPN_SELF_IPSET_NAME}"
  load_overrides
  # shellcheck disable=SC2034 # read by the scripts that source this file
  GVPN_SELF_IPSET_NAME="${self_ipset_name}"
  load_capacity_cache
  resolve_capacity
  # 10.128.0.0/24 -> 10.128.0 (shaping and the peer pool only vary the last octet)
  local network="${WIREGUARD_CIDR%/*}"
  # shellcheck disable=SC2034 # read by the scripts that source this file
  GVPN_PEER_SUBNET_PREFIX="${network%.*}"
}

# kbit_ok VALUE
# A rate in kbit/s as plain decimal without leading zeros: 1..9999999999. The
# upper bound is a sanity limit (10 Tbit/s), not a policy: it keeps a corrupt
# cache or a nonsense probe answer out of tc.
kbit_ok() {
  [[ "$1" =~ ^[1-9][0-9]{0,9}$ ]]
}

# capacity_sample_ok DOWN_KBIT UP_KBIT
# An uplink sample the device may shape to: two rates, neither below
# GVPN_CAPACITY_MIN_KBIT. A probe can complete on a link that is throttled to a
# trickle, and a sample like that is treated as no measurement. A minimum that
# is not a rate refuses every sample, so a typo costs the measurement and the
# device runs on the supported-environment floor.
capacity_sample_ok() {
  kbit_ok "$1" && kbit_ok "$2" && kbit_ok "${GVPN_CAPACITY_MIN_KBIT:-}" \
    && (( $1 >= GVPN_CAPACITY_MIN_KBIT && $2 >= GVPN_CAPACITY_MIN_KBIT ))
}

# UTC timestamps as capacity.sh writes them.
is_timestamp() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# https_url_ok URL
# An https URL that is safe to hand to curl and to write into a configuration
# file: a host, an optional port and path, and only characters that RFC 3986
# allows in a URL. That excludes whitespace, quotes, backslashes and the shell
# metacharacters that would change the meaning of a value read back from a
# file.
#
# Deliberately narrow: the host is a name or an IPv4 address, so userinfo
# (user:pass@host) and an IPv6 literal in brackets are refused. Neither Blokli
# nor a fleet endpoint needs either, and a value that cannot be written into a
# configuration file is refused at provisioning time rather than at boot.
URL_SAFE_RE='^[]A-Za-z0-9._~:/?#@!&+,;=%-]+$'
https_url_ok() {
  local url="$1"
  [[ "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#].*)?$ ]] && [[ "${url}" =~ ${URL_SAFE_RE} ]]
}

# Load the last uplink sample and the outcome of the latest probe. The file is
# parsed, never sourced: it is state written by capacity.sh, and a corrupt one
# must neither run code nor reach tc. Every value is validated here and every
# read failure ends the load with an empty sample, because this runs inside the
# firewall's ExecStartPre and the required greenboot checks: a broken cache has
# to cost the measurement, never the boot.
load_capacity_cache() {
  local file size line key value
  local schema="" down="" up="" measured="" attempt="" attempt_at=""
  # shellcheck disable=SC2034 # read by the scripts that source this file
  GVPN_CAPACITY_DOWN_KBIT=""
  # shellcheck disable=SC2034
  GVPN_CAPACITY_UP_KBIT=""
  # shellcheck disable=SC2034
  GVPN_CAPACITY_MEASURED_AT=""
  # shellcheck disable=SC2034
  GVPN_CAPACITY_ATTEMPT=""
  # shellcheck disable=SC2034
  GVPN_CAPACITY_ATTEMPT_AT=""
  file="$(capacity_file)"
  [[ -f "${file}" ]] || return 0
  # capacity.sh writes a handful of short lines; anything larger is not ours.
  size="$(stat -c %s "${file}" 2>/dev/null)" || return 0
  (( size > 0 && size <= 4096 )) || return 0

  while IFS= read -r line; do
    key="${line%%=*}"
    [[ "${key}" == "${line}" ]] && continue
    value="${line#*=}"
    case "${key}" in
      GVPN_CAPACITY_SCHEMA) schema="${value}" ;;
      GVPN_CAPACITY_DOWN_KBIT) down="${value}" ;;
      GVPN_CAPACITY_UP_KBIT) up="${value}" ;;
      GVPN_CAPACITY_MEASURED_AT) measured="${value}" ;;
      GVPN_CAPACITY_ATTEMPT) attempt="${value}" ;;
      GVPN_CAPACITY_ATTEMPT_AT) attempt_at="${value}" ;;
    esac
  done < "${file}" || return 0

  [[ "${schema}" == "${GVPN_CAPACITY_SCHEMA}" ]] || return 0
  case "${attempt}" in
    ok|failed|skipped)
      # shellcheck disable=SC2034 # read by the scripts that source this file
      GVPN_CAPACITY_ATTEMPT="${attempt}" ;;
    *) return 0 ;;
  esac
  if is_timestamp "${attempt_at}"; then
    # shellcheck disable=SC2034 # read by the scripts that source this file
    GVPN_CAPACITY_ATTEMPT_AT="${attempt_at}"
  fi
  if capacity_sample_ok "${down}" "${up}" && is_timestamp "${measured}"; then
    # shellcheck disable=SC2034 # read by the scripts that source this file
    GVPN_CAPACITY_DOWN_KBIT="${down}"
    # shellcheck disable=SC2034
    GVPN_CAPACITY_UP_KBIT="${up}"
    # shellcheck disable=SC2034
    GVPN_CAPACITY_MEASURED_AT="${measured}"
  fi
}

# Derive the shaping aggregate and the peer pool from the measurement cache and
# the knobs that apply after the device overrides:
#   aggregate = floor(min(measured down, measured up) / GVPN_UPLINK_SHARE_DIVISOR)
#   slots     = floor(aggregate / GVPN_PEER_MIN_SHARE_KBIT), 1..last usable octet
#   ceiling   = min(GVPN_PEER_RATE_KBIT, aggregate)
#   guarantee = min(ceiling, floor(aggregate / slots))
# The `auto` knobs resolve here; a number in /etc/gvpn-exit/exit.env pins the
# value. Without a usable measurement the aggregate falls back to the
# supported-environment floor, and so does a measured aggregate that cannot
# give every slot of a pinned pool a 1 kbit/s share: a sample is not a pin, so
# it never leaves the derived values empty. Invalid knobs are left as they are,
# so the unit that consumes them (render-wg-conf.sh, tc) fails loudly instead of silently
# shaping to a different number.
resolve_capacity() {
  local aggregate="${GVPN_PEER_SHAPING_AGGREGATE_KBIT}"
  local divisor="${GVPN_UPLINK_SHARE_DIVISOR}" share="${GVPN_PEER_MIN_SHARE_KBIT}"
  local slots limit count ceiling guarantee measured_min
  # shellcheck disable=SC2034 # read by the scripts that source this file
  GVPN_PEER_CEIL_KBIT=""
  # shellcheck disable=SC2034
  GVPN_PEER_GUARANTEE_KBIT=""
  # shellcheck disable=SC2034
  GVPN_PEER_COUNT=""
  # shellcheck disable=SC2034
  GVPN_CAPACITY_SOURCE=fallback

  if [[ "${aggregate}" == auto ]]; then
    if [[ "${divisor}" =~ ^[1-9][0-9]{0,3}$ ]] \
        && kbit_ok "${GVPN_CAPACITY_DOWN_KBIT}" && kbit_ok "${GVPN_CAPACITY_UP_KBIT}"; then
      measured_min="${GVPN_CAPACITY_DOWN_KBIT}"
      if (( GVPN_CAPACITY_UP_KBIT < measured_min )); then
        measured_min="${GVPN_CAPACITY_UP_KBIT}"
      fi
      aggregate=$(( measured_min / divisor ))
      # shellcheck disable=SC2034
      GVPN_CAPACITY_SOURCE=measured
      # shellcheck disable=SC2153 # the pool knobs come from exit.env
      if peer_octet_range_ok "${GVPN_PEER_MIN_OCTET}" "${GVPN_PEER_MAX_OCTET}" \
          && (( aggregate < GVPN_PEER_MAX_OCTET - GVPN_PEER_MIN_OCTET + 1 )); then
        aggregate=auto
      fi
    fi
    if ! kbit_ok "${aggregate}"; then
      aggregate="${GVPN_PEER_CAPACITY_FALLBACK_KBIT}"
      # shellcheck disable=SC2034
      GVPN_CAPACITY_SOURCE=fallback
    fi
  else
    # shellcheck disable=SC2034
    GVPN_CAPACITY_SOURCE=pinned
  fi
  # shellcheck disable=SC2034
  GVPN_PEER_SHAPING_AGGREGATE_KBIT="${aggregate}"

  if [[ "${GVPN_PEER_MAX_OCTET}" == auto ]]; then
    # shellcheck disable=SC2153 # GVPN_PEER_MIN_OCTET comes from exit.env
    if peer_min_octet_ok "${GVPN_PEER_MIN_OCTET}" && kbit_ok "${aggregate}" && kbit_ok "${share}"; then
      slots=$(( aggregate / share ))
      if (( slots < 1 )); then
        # Below the supported floor: serve one client best effort rather than
        # refuse service, and let gvpn-exit-status report the degradation.
        slots=1
      fi
      limit=$(( 255 - GVPN_PEER_MIN_OCTET ))
      if (( slots > limit )); then
        slots="${limit}"
      fi
      # shellcheck disable=SC2034
      GVPN_PEER_MAX_OCTET=$(( GVPN_PEER_MIN_OCTET + slots - 1 ))
    fi
  fi

  # An unusable pin, or a pool that cannot give every peer a 1 kbit/s share of
  # the aggregate, leaves the three derived values empty on purpose: shaping
  # then refuses to build the tree and names the knob, instead of quietly
  # shaping to a number nobody asked for or over-subscribing the parent.
  # shellcheck disable=SC2153 # the three knobs come from exit.env
  if peer_octet_range_ok "${GVPN_PEER_MIN_OCTET}" "${GVPN_PEER_MAX_OCTET}" \
      && kbit_ok "${aggregate}" && kbit_ok "${GVPN_PEER_RATE_KBIT}"; then
    count=$(( GVPN_PEER_MAX_OCTET - GVPN_PEER_MIN_OCTET + 1 ))
    ceiling="${GVPN_PEER_RATE_KBIT}"
    if (( ceiling > aggregate )); then
      ceiling="${aggregate}"
    fi
    guarantee=$(( aggregate / count ))
    if (( guarantee > ceiling )); then
      guarantee="${ceiling}"
    fi
    if (( guarantee >= 1 )); then
      # shellcheck disable=SC2034 # read by the scripts that source this file
      GVPN_PEER_COUNT="${count}"
      # shellcheck disable=SC2034
      GVPN_PEER_CEIL_KBIT="${ceiling}"
      # shellcheck disable=SC2034
      GVPN_PEER_GUARANTEE_KBIT="${guarantee}"
    fi
  fi
}

is_provisioned() {
  [[ -f "${GVPN_IDENTITY_DIR}/provisioned" ]]
}

bootc_status_json() {
  bootc status --format=json
}

# Digest of the image the running deployment was built from. This is the
# deployment id used for data ownership and rejected-image bookkeeping.
booted_image_digest() {
  bootc_status_json | jq -r '.status.booted.image.imageDigest // empty'
}

# Digest of the staged deployment, empty when nothing is staged.
staged_image_digest() {
  bootc_status_json | jq -r '.status.staged.image.imageDigest // empty'
}

# Digest of the rollback deployment, empty when there is none.
rollback_image_digest() {
  bootc_status_json | jq -r '.status.rollback.image.imageDigest // empty'
}

# Whether greenboot rejected digest $1 on this device (state/rejected-digests,
# recorded by the red.d hook).
digest_rejected() {
  [[ -f "${GVPN_STATE_DIR}/rejected-digests" ]] && grep -qxF "$1" "${GVPN_STATE_DIR}/rejected-digests"
}

# peer_min_octet_ok OCTET
# The pool's first last-octet: .2 at the lowest because .1 is the server.
peer_min_octet_ok() {
  [[ "$1" =~ ^[1-9][0-9]{0,2}$ ]] && (( $1 >= 2 && $1 <= 254 ))
}

# peer_octet_range_ok MIN MAX
# The WireGuard client pool MIN..MAX (last octets, plain decimal) lies within
# 2..254: .0 is the network, .1 the server and .255 the broadcast address.
peer_octet_range_ok() {
  peer_min_octet_ok "$1" && [[ "$2" =~ ^[1-9][0-9]{0,2}$ ]] && (( $2 <= 254 && $1 <= $2 ))
}

# Replace $1 with stdin via a temp file in the same directory and a rename,
# so readers never observe a partially written file.
write_atomic() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "${tmp}"
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${dest}"
}

# Current time as epoch seconds; GVPN_NOW pins it in tests.
now_epoch() {
  echo "${GVPN_NOW:-$(date +%s)}"
}

ntp_synchronized() {
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]
}

# Serialize the support window's mutations. The timer
# (support-window.sh enforce) and the CLI (gvpn-exit-support extend|close) both
# hold this lock while they read a recovery request, change the window and
# start or stop the tunnel, so a request the timer has already read cannot
# reopen a window that `close` just removed. Readers (check, status) do not
# take it: writes are atomic renames, and support-tunnel.service's
# ExecCondition runs `check` while the caller still holds the lock.
lock_support_window() {
  mkdir -p "${GVPN_RUN_DIR}"
  exec 9>"${GVPN_RUN_DIR}/support-window.lock"
  flock -x 9
}

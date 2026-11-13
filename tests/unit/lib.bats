#!/usr/bin/env bats
# Unit tests for the shared helpers in lib.sh.

load helpers

setup() {
  setup_sandbox
  LIB="${LIBEXEC}/lib.sh"
}

teardown() {
  teardown_sandbox
}

@test "the hoprd paths default to the v5 locations" {
  run bash -c 'unset GVPN_HOPRD_DATA GVPN_HOPRD_SNAPSHOTS GVPN_HOPRD_ENV_DIR GVPN_HOPRD_V4_ENV_DIR; source "$1"; printf "%s\n%s\n%s\n%s\n" "${GVPN_HOPRD_DATA}" "${GVPN_HOPRD_SNAPSHOTS}" "${GVPN_HOPRD_ENV_DIR}" "${GVPN_HOPRD_V4_ENV_DIR}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "/var/lib/hoprd-v5" ]
  [ "${lines[1]}" = "/var/lib/hoprd-v5.snapshots" ]
  [ "${lines[2]}" = "/etc/hoprd-v5/hoprd.env.d" ]
  [ "${lines[3]}" = "/etc/hoprd/hoprd.env.d" ]
}

@test "hoprd_env_file prefers the v5 provisioning file and falls back to v4" {
  mkdir -p "${SANDBOX}/v5" "${SANDBOX}/v4"
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/v5"
  export GVPN_HOPRD_V4_ENV_DIR="${SANDBOX}/v4"
  printf 'HOPRD_BLOKLI_URL=https://v4.example\n' > "${SANDBOX}/v4/10-provisioned.env"
  run in_script "${LIB}" hoprd_env_file
  [ "${output}" = "${SANDBOX}/v4/10-provisioned.env" ]
  printf 'HOPRD_BLOKLI_URL=https://v5.example\n' > "${SANDBOX}/v5/10-provisioned.env"
  run in_script "${LIB}" hoprd_env_file
  [ "${output}" = "${SANDBOX}/v5/10-provisioned.env" ]
}

@test "render_hoprd_config replaces every Blokli URL and keeps the rest" {
  export GVPN_HOPRD_CFG_TEMPLATE="${SHARE}/hoprd.cfg.yaml"
  run bash -c 'source "$1"; render_hoprd_config https://blokli.example.org "$2"' _ "${LIB}" "${SANDBOX}/hoprd.cfg.yaml"
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'blokli_url: https://blokli.example.org' "${SANDBOX}/hoprd.cfg.yaml")" -eq 2 ]
  grep -q '^    - Pix:$' "${SANDBOX}/hoprd.cfg.yaml"
  grep -q '^  announce: false' "${SANDBOX}/hoprd.cfg.yaml"
  run bash -c 'source "$1"; render_hoprd_config http://insecure.example "$2"' _ "${LIB}" "${SANDBOX}/hoprd.cfg.yaml"
  [ "${status}" -ne 0 ]
}

@test "load_exit_env reads the image defaults" {
  run bash -c 'source "$1"; load_exit_env; echo "${GVPN_PEER_RATE_KBIT} ${NETWORK_INTERFACE}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "10000 lan0" ]
}

# /etc survives a rollback and a broken override would otherwise fail the
# firewall unit, and with it sshd and both tunnels.
@test "a device override that does not parse is skipped, not fatal" {
  printf 'GVPN_PEER_RATE_KBIT="unterminated\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -c 'source "$1"; load_exit_env; echo "${GVPN_PEER_RATE_KBIT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"does not run cleanly"* ]]
  [ "${lines[${#lines[@]} - 1]}" = "10000" ]
}

# A file that parses but runs a failing command aborts `source` under `set -e`,
# which took the firewall down with it. It now costs the overrides, nothing else.
@test "a device override whose command fails is skipped whole, not fatal" {
  printf 'GVPN_PEER_RATE_KBIT=5000\nfalse\nGVPN_PEER_MIN_OCTET=10\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c 'source "$1"; load_exit_env; echo "${GVPN_PEER_RATE_KBIT} ${GVPN_PEER_MIN_OCTET}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"does not run cleanly"* ]]
  [ "${lines[${#lines[@]} - 1]}" = "10000 2" ]
}

# The file is read after the defaults, so it may build on them: extending a
# list that the image ships is the common case.
@test "a device override can build on a default value" {
  printf 'GVPN_BLOCKLIST_FEEDS="${GVPN_BLOCKLIST_FEEDS} https://mirror.example/list"\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c 'source "$1"; load_exit_env; echo "${GVPN_BLOCKLIST_FEEDS}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"firehol_level1.netset https://mirror.example/list"* ]]
}

# lib.sh's own variables are not exported, so the file only sees them because
# the loader hands the caller's variables over.
@test "a device override can build on a lib.sh directory" {
  printf 'GVPN_BLOCKLIST_CACHE_DIR="${GVPN_STATE_DIR}/bl"\n' > "${GVPN_EXIT_OVERRIDES}"
  # The sandbox exports its directories, and on a device they are plain shell
  # variables: unexport it, or the subshell would inherit the value anyway.
  run bash -euo pipefail -c 'source "$1"; export -n GVPN_STATE_DIR; load_exit_env; echo "${GVPN_BLOCKLIST_CACHE_DIR}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "${GVPN_STATE_DIR}/bl" ]
}

# Every way a shell file can set a variable counts, not just `NAME=value` at
# the start of a line.
@test "a device override may export, append and set two knobs on one line" {
  printf 'export GVPN_BLOCKLIST_CURL_TIMEOUT=9\nGVPN_BLOCKLIST_IPSET_NAME=gvpn-block\nGVPN_BLOCKLIST_IPSET_NAME+=x\nGVPN_BLOCKLIST_MAXELEM=64 GVPN_SELF_IPSET_MAXELEM=8\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c 'source "$1"; load_exit_env; echo "${GVPN_BLOCKLIST_CURL_TIMEOUT} ${GVPN_BLOCKLIST_IPSET_NAME} ${GVPN_BLOCKLIST_MAXELEM} ${GVPN_SELF_IPSET_MAXELEM}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "9 gvpn-blockx 64 8" ]
}

# The handover must not take over the shell's own variables: a lower-case name
# is not a knob, and the caller's shell state (SHLVL, IFS) has to survive.
@test "a device override does not take over the shell's own variables" {
  printf 'GVPN_PEER_RATE_KBIT=5000\nnotAKnob=1\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c '
    source "$1"
    IFS=:
    level="${SHLVL}"
    load_exit_env
    [[ "${SHLVL}" == "${level}" && "${IFS}" == : ]] \
      || { echo "shell state changed: SHLVL ${level}->${SHLVL}, IFS [${IFS}]"; exit 1; }
    echo "${GVPN_PEER_RATE_KBIT} ${notAKnob:-unset}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "5000 unset" ]
}

@test "a device override keeps the quoting and expansions of a sourced file" {
  printf 'GVPN_BLOCKLIST_FEEDS="https://a.example  https://b.example"\nGVPN_BLOCKLIST_CURL_TIMEOUT=$(( 7 + 1 ))\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -c 'source "$1"; load_exit_env; echo "${GVPN_BLOCKLIST_FEEDS} | ${GVPN_BLOCKLIST_CURL_TIMEOUT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://a.example  https://b.example | 8" ]
}

# A knob whose default lives in the script rather than in exit.env is still the
# device's to set: /etc/gvpn-exit/exit.env is the documented place for all of
# them, and the loader must not filter to the names exit.env happens to carry.
@test "a device override reaches a knob that exit.env does not define" {
  printf 'GVPN_LOOPBACK_IFACE=lo0\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c 'source "$1"; load_exit_env; echo "${GVPN_LOOPBACK_IFACE:-unset}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "lo0" ]
}

# `unset` and `readonly` are not taken over: a knob that is gone aborts every
# `set -u` reader of it, and /etc survives a rollback, so one such line would
# keep the device from booting green. The knob keeps its default instead, and the
# caller keeps working.
@test "an override that unsets or freezes a knob leaves its default in place" {
  printf 'unset GVPN_BLOCKLIST_FEEDS\ndeclare -r GVPN_PEER_RATE_KBIT=5000\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -euo pipefail -c '
    source "$1"; load_exit_env
    echo "${GVPN_BLOCKLIST_FEEDS} ${GVPN_PEER_RATE_KBIT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset 10000" ]
}

@test "load_exit_env lets /etc overrides win over the defaults" {
  echo "GVPN_PEER_RATE_KBIT=5000" > "${GVPN_EXIT_OVERRIDES}"
  run bash -c 'source "$1"; load_exit_env; echo "${GVPN_PEER_RATE_KBIT} ${GVPN_PEER_SHAPING_AGGREGATE_KBIT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "5000 7500" ]
}

# The capacity knobs as shaping, the server and the diagnostics see them:
# aggregate, pool end, per-peer ceiling, per-peer guarantee, slots, source.
capacity_values() {
  bash -c 'source "$1"; load_exit_env; printf "%s %s %s %s %s %s\n" \
    "${GVPN_PEER_SHAPING_AGGREGATE_KBIT}" "${GVPN_PEER_MAX_OCTET}" \
    "${GVPN_PEER_CEIL_KBIT}" "${GVPN_PEER_GUARANTEE_KBIT}" \
    "${GVPN_PEER_COUNT}" "${GVPN_CAPACITY_SOURCE}"' _ "${LIB}"
}

@test "without a measurement the capacity falls back to the supported floor" {
  run capacity_values
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

@test "a measurement of the 200 Mbit/s example yields ten 5 Mbit/s slots" {
  seed_capacity 200000 200000
  run capacity_values
  [ "${output}" = "50000 11 10000 5000 10 measured" ]
}

@test "the smaller direction sizes the aggregate" {
  seed_capacity 300000 120000
  run capacity_values
  [ "${output}" = "30000 7 10000 5000 6 measured" ]
}

@test "a link at the supported floor serves one peer at the whole aggregate" {
  seed_capacity 30000 30000
  run capacity_values
  [ "${output}" = "7500 2 7500 7500 1 measured" ]
}

@test "a link below the supported floor still serves one peer" {
  seed_capacity 8000 8000
  run capacity_values
  [ "${output}" = "2000 2 2000 2000 1 measured" ]
}

# A probe can complete on a link that is throttled to a trickle. Such a sample
# says nothing about the link the device normally has, so it is not shaped to.
@test "a sample below GVPN_CAPACITY_MIN_KBIT is not used" {
  seed_capacity 200000 400
  run capacity_values
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
  run bash -c 'source "$1"; load_exit_env; echo "down=${GVPN_CAPACITY_DOWN_KBIT} up=${GVPN_CAPACITY_UP_KBIT} at=${GVPN_CAPACITY_MEASURED_AT}"' _ "${LIB}"
  [ "${output}" = "down= up= at=" ]
}

@test "GVPN_CAPACITY_MIN_KBIT moves the bound for a usable sample" {
  echo "GVPN_CAPACITY_MIN_KBIT=400" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 400
  run capacity_values
  [ "${output}" = "100 2 100 100 1 measured" ]
}

@test "an invalid GVPN_CAPACITY_MIN_KBIT costs the sample, not the shaping" {
  echo "GVPN_CAPACITY_MIN_KBIT=none" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 200000
  run capacity_values_strict
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

# The pool is pinned and the aggregate follows the measurement: a slow sample
# must not leave the shaping values empty, because shaping then refuses the
# interface and the required greenboot checks go red on every deployment.
@test "a pinned pool the measured aggregate cannot serve falls back to the floor" {
  echo "GVPN_PEER_MAX_OCTET=254" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 1000 1000
  run capacity_values
  # 250 kbit/s over 253 slots is no share at all; 7500 kbit/s gives each 29.
  [ "${output}" = "7500 254 7500 29 253 fallback" ]
}

@test "a fast link is capped at the last usable address of the /24" {
  seed_capacity 2000000000 2000000000
  run capacity_values
  # 253 slots, and a guarantee above the per-peer ceiling is meaningless.
  [ "${output}" = "500000000 254 10000 10000 253 measured" ]
}

@test "the guarantee is the aggregate share when it fits under the ceiling" {
  seed_capacity 120000 120000
  run capacity_values
  # 30 Mbit/s aggregate over 6 slots: 5 Mbit/s each, under the 10 Mbit/s ceiling.
  [ "${output}" = "30000 7 10000 5000 6 measured" ]
}

@test "the pool follows GVPN_PEER_MIN_OCTET" {
  echo "GVPN_PEER_MIN_OCTET=10" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 200000
  run capacity_values
  [ "${output}" = "50000 19 10000 5000 10 measured" ]
}

@test "a pinned aggregate replaces the measurement" {
  echo "GVPN_PEER_SHAPING_AGGREGATE_KBIT=20000" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 200000
  run capacity_values
  [ "${output}" = "20000 5 10000 5000 4 pinned" ]
}

@test "a pinned pool keeps the guarantee honest for its size" {
  echo "GVPN_PEER_MAX_OCTET=5" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 200000
  run capacity_values
  [ "${output}" = "50000 5 10000 10000 4 measured" ]
}

@test "the ceiling never exceeds the aggregate" {
  echo "GVPN_PEER_RATE_KBIT=10000" > "${GVPN_EXIT_OVERRIDES}"
  echo "GVPN_PEER_SHAPING_AGGREGATE_KBIT=6000" >> "${GVPN_EXIT_OVERRIDES}"
  run capacity_values
  [ "${output}" = "6000 2 6000 6000 1 pinned" ]
}

@test "a corrupt cache falls back instead of changing shaping" {
  echo "GVPN_CAPACITY_SCHEMA=1" > "${GVPN_STATE_DIR}/capacity.env"
  echo "GVPN_CAPACITY_DOWN_KBIT=fast" >> "${GVPN_STATE_DIR}/capacity.env"
  echo "GVPN_CAPACITY_UP_KBIT=200000" >> "${GVPN_STATE_DIR}/capacity.env"
  echo "GVPN_CAPACITY_MEASURED_AT=2026-10-01T03:00:00Z" >> "${GVPN_STATE_DIR}/capacity.env"
  echo "GVPN_CAPACITY_ATTEMPT=ok" >> "${GVPN_STATE_DIR}/capacity.env"
  run capacity_values
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

@test "a cache from another schema is ignored" {
  seed_capacity 200000 200000
  sed -i 's/^GVPN_CAPACITY_SCHEMA=1/GVPN_CAPACITY_SCHEMA=2/' "${GVPN_STATE_DIR}/capacity.env"
  run capacity_values
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

@test "a cache with an unknown attempt value does not break load_exit_env" {
  printf 'GVPN_CAPACITY_SCHEMA=1\nGVPN_CAPACITY_ATTEMPT=nonsense\n' > "${GVPN_STATE_DIR}/capacity.env"
  run capacity_values
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

# The cache is read inside the firewall's ExecStartPre and the required greenboot
# checks, so every read failure has to cost the measurement, not the boot. These
# run under the scripts' own errexit, which a plain `bash -c` helper misses.
capacity_values_strict() {
  bash -euo pipefail -c 'source "$1"; load_exit_env; printf "%s %s %s %s %s %s\n" \
    "${GVPN_PEER_SHAPING_AGGREGATE_KBIT}" "${GVPN_PEER_MAX_OCTET}" \
    "${GVPN_PEER_CEIL_KBIT}" "${GVPN_PEER_GUARANTEE_KBIT}" \
    "${GVPN_PEER_COUNT}" "${GVPN_CAPACITY_SOURCE}"' _ "${LIB}"
}

@test "a cache path that is not a regular file falls back without failing the caller" {
  mkdir "${GVPN_STATE_DIR}/capacity.env"
  run capacity_values_strict
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

@test "an oversized cache is ignored instead of being parsed" {
  { echo "GVPN_CAPACITY_SCHEMA=1"; for _ in $(seq 1 400); do echo "GVPN_CAPACITY_DOWN_KBIT=200000"; done; } \
    > "${GVPN_STATE_DIR}/capacity.env"
  [ "$(stat -c %s "${GVPN_STATE_DIR}/capacity.env")" -gt 4096 ]
  run capacity_values_strict
  [ "${status}" -eq 0 ]
  [ "${output}" = "7500 2 7500 7500 1 fallback" ]
}

@test "an invalid peer rate is left for shaping to reject, not replaced" {
  echo "GVPN_PEER_RATE_KBIT=0" > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 200000 200000
  run bash -c 'source "$1"; load_exit_env; echo "aggregate=${GVPN_PEER_SHAPING_AGGREGATE_KBIT} ceiling=${GVPN_PEER_CEIL_KBIT} guarantee=${GVPN_PEER_GUARANTEE_KBIT} count=${GVPN_PEER_COUNT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "aggregate=50000 ceiling= guarantee= count=" ]
}

@test "a pool that cannot give every peer 1 kbit/s stays unresolved" {
  printf 'GVPN_PEER_SHAPING_AGGREGATE_KBIT=100\nGVPN_PEER_MAX_OCTET=254\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash -c 'source "$1"; load_exit_env; echo "ceiling=${GVPN_PEER_CEIL_KBIT} guarantee=${GVPN_PEER_GUARANTEE_KBIT} count=${GVPN_PEER_COUNT}"' _ "${LIB}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "ceiling= guarantee= count=" ]
}

@test "repeated loads derive the same capacity" {
  seed_capacity 200000 200000
  run bash -c 'source "$1"; load_exit_env; first="${GVPN_PEER_MAX_OCTET} ${GVPN_PEER_SHAPING_AGGREGATE_KBIT}"; load_exit_env; echo "${first} | ${GVPN_PEER_MAX_OCTET} ${GVPN_PEER_SHAPING_AGGREGATE_KBIT}"' _ "${LIB}"
  [ "${output}" = "11 50000 | 11 50000" ]
}

@test "load_exit_env derives the peer subnet prefix from WIREGUARD_CIDR" {
  run bash -c 'source "$1"; load_exit_env; echo "${GVPN_PEER_SUBNET_PREFIX}"' _ "${LIB}"
  [ "${output}" = "10.128.0" ]
}

@test "is_provisioned is false without the marker and true with it" {
  run in_script "${LIB}" is_provisioned
  [ "${status}" -ne 0 ]
  provision_sandbox
  run in_script "${LIB}" is_provisioned
  [ "${status}" -eq 0 ]
}

@test "booted_image_digest reads the booted digest from bootc status" {
  mock_cmd bootc '[[ "$*" = "status --format=json" ]] || exit 1; echo "{\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"sha256:aaa\"}}}}"'
  run in_script "${LIB}" booted_image_digest
  [ "${status}" -eq 0 ]
  [ "${output}" = "sha256:aaa" ]
}

@test "staged_image_digest is empty when nothing is staged" {
  mock_cmd bootc 'echo "{\"status\":{\"staged\":null,\"booted\":{\"image\":{\"imageDigest\":\"sha256:aaa\"}}}}"'
  run in_script "${LIB}" staged_image_digest
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "write_atomic replaces a file in one rename" {
  run bash -c 'source "$1"; echo hello | write_atomic "$2"' _ "${LIB}" "${SANDBOX}/state/out"
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/state/out")" = "hello" ]
  [ -z "$(ls "${SANDBOX}/state" | grep -v '^out$')" ]
}

@test "digest_rejected matches whole lines of the rejection record only" {
  printf 'sha256:bad\nsha256:worse\n' > "${GVPN_STATE_DIR}/rejected-digests"
  run in_script "${LIB}" digest_rejected sha256:bad
  [ "${status}" -eq 0 ]
  run in_script "${LIB}" digest_rejected sha256:ba
  [ "${status}" -ne 0 ]
  rm "${GVPN_STATE_DIR}/rejected-digests"
  run in_script "${LIB}" digest_rejected sha256:bad
  [ "${status}" -ne 0 ]
}

@test "peer_octet_range_ok accepts pools within 2..254 only" {
  for range in "2 2" "2 254" "10 20"; do
    run in_script "${LIB}" peer_octet_range_ok ${range}
    [ "${status}" -eq 0 ] || { echo "refused ${range}"; false; }
  done
  for range in "1 3" "2 255" "5 4" "2 04" "02 4" "2 0255" "2 99999999999999999999" "2 x"; do
    run in_script "${LIB}" peer_octet_range_ok ${range}
    [ "${status}" -ne 0 ] || { echo "accepted ${range}"; false; }
  done
}

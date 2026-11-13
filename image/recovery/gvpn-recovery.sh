#!/usr/bin/env bash
# Restore SSH access to a GnosisVPN exit appliance from the recovery stick.
#
# The stick boots image/recovery as a Unified Kernel Image, so this script runs
# in the initramfs with busybox, util-linux and the storage drivers, nothing
# else. Its dracut module calls the phases, each a separate initramfs process:
#
#   prepare  mount the stick, find the appliance, mount its root read-only
#   apply    mount the root read-write, add the operator keys, open the support
#            window, write the report to the stick, sync and unmount
#   finish   print the verdict for the person on site and power off
#   fail     print the failure verdict and power off, for a phase that ended
#            without a verdict of its own
#   run      prepare, apply and finish in one process (rehearsal and unit tests)
#
# Nothing on the stick is secret: it carries public keys only. What it does is
# grant access to a machine that is already physically in someone's hands. The
# expiry it writes keeps the device tidy after the work is done; it is not a
# security boundary, because whoever controls the stick controls the expiry it
# writes. The durable grant belongs on the bastion, whose device register
# records every access change.
#
# Every path and external command is overridable through the environment so the
# bats suite and the integration phase drive this same code:
#
#   GVPN_RECOVERY_ROOT           mount point of the appliance's root partition,
#                                the ostree physical root
#                                (/run/gvpn-recovery/root; /sysroot is the
#                                tmpfs that root=tmpfs gives the initrd)
#   GVPN_RECOVERY_STICK          stick mount point (/run/gvpn-recovery/stick)
#   GVPN_RECOVERY_STICK_LABEL    FAT label of the stick (GVPNRECOV)
#   GVPN_RECOVERY_RUN_DIR        state shared by the phases (/run/gvpn-recovery)
#   GVPN_RECOVERY_DAYS           support window the stick opens (7)
#   GVPN_RECOVERY_KEY_DAYS       validity of the injected keys (7)
#   GVPN_RECOVERY_WAIT           seconds to wait for the stick to show up (60)
#   GVPN_RECOVERY_HOLD           seconds the verdict stays on screen before the
#                                device turns off (600)
#   GVPN_RECOVERY_NOW            epoch seconds, pinned by the tests
#   GVPN_RECOVERY_CONSOLE        where the on-screen verdict goes (/dev/console)
#   GVPN_RECOVERY_ASSUME_MOUNTED the stick and the appliance root are already
#                                mounted at their paths, so nothing is
#                                identified, mounted or unmounted (tests)
#   GVPN_RECOVERY_NO_POWEROFF    print the verdict instead of powering off (tests)
set -euo pipefail

ROOT="${GVPN_RECOVERY_ROOT:-/run/gvpn-recovery/root}"
STICK="${GVPN_RECOVERY_STICK:-/run/gvpn-recovery/stick}"
STICK_LABEL="${GVPN_RECOVERY_STICK_LABEL:-GVPNRECOV}"
RUN_DIR="${GVPN_RECOVERY_RUN_DIR:-/run/gvpn-recovery}"
DAYS="${GVPN_RECOVERY_DAYS:-7}"
KEY_DAYS="${GVPN_RECOVERY_KEY_DAYS:-7}"
WAIT="${GVPN_RECOVERY_WAIT:-60}"
HOLD="${GVPN_RECOVERY_HOLD:-600}"
CONSOLE="${GVPN_RECOVERY_CONSOLE:-/dev/console}"
PAYLOAD="gvpn-recovery/authorized_keys"

log() {
  printf '%s\n' "$*" >&2
}

# One line of the screen the person on site reads. stderr is the serial console
# in the rehearsal; the console device is what is plugged into the appliance.
say() {
  printf '%s\n' "$*" >>"${CONSOLE}" 2>/dev/null || true
}

now() {
  printf '%s\n' "${GVPN_RECOVERY_NOW:-$(date +%s)}"
}

utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# screen TITLE LINE...
# One verdict per screen, one cause per screen, never a log.
screen() {
  local title="$1" line
  shift
  say "========================================"
  say " GnosisVPN recovery: ${title}"
  say "========================================"
  for line in "$@"; do
    say " ${line}"
  done
  say "========================================"
}

# Keep the verdict on screen long enough to read and photograph it, then
# power the appliance off so the stick cannot boot again by itself. The disk
# is synced and unmounted by now, so holding the power button meanwhile is
# safe. Returning from an initramfs hook would hand the person a root shell,
# so in the initramfs this never returns.
power_off() {
  sync
  if ((HOLD >= 60)); then
    say " The device turns off by itself in $((HOLD / 60)) minutes."
  fi
  sleep "${HOLD}"
  if [[ -n "${GVPN_RECOVERY_NO_POWEROFF:-}" ]]; then
    log "not powering off: GVPN_RECOVERY_NO_POWEROFF is set"
    return 0
  fi
  poweroff -f || true
  sleep 2
  echo o >/proc/sysrq-trigger 2>/dev/null || true
  while :; do
    sleep 3600
  done
}

# stop LINE...
# A refusal: nothing on the appliance was changed.
stop() {
  screen "STOPPED - nothing was changed" "$@"
  power_off
  exit 1
}

# abort LINE...
# A failure after the appliance may already have been changed.
abort() {
  screen "FAILED" "$@" "The device may be partly changed." "Call the support team."
  power_off
  exit 1
}

state_file() {
  printf '%s/%s\n' "${RUN_DIR}" "$1"
}

# warn TEXT
# Something the run could not do that does not undo the recovery; it ends up
# on the verdict screen and in the report.
warn() {
  log "warning: $*"
  mkdir -p "${RUN_DIR}"
  printf '%s\n' "$*" >>"$(state_file warnings)"
}

warnings() {
  cat "$(state_file warnings)" 2>/dev/null || true
}

read_state() {
  local file
  file="$(state_file "$1")"
  [[ -s "${file}" ]] || return 0
  head -n1 "${file}"
}

write_state() {
  mkdir -p "${RUN_DIR}"
  printf '%s\n' "$2" >"$(state_file "$1")"
}

# --- the stick ---------------------------------------------------------------

stick_device() {
  blkid -L "${STICK_LABEL}" 2>/dev/null || true
}

# Nothing in the initrd waits for storage (root=tmpfs names no device), so
# wait for the stick here: it sits on USB, which usually enumerates after the
# appliance's own disk, and udev then settles so every partition has its node.
wait_for_stick() {
  local waited=0
  until [[ -n "$(stick_device)" ]]; do
    ((waited < WAIT)) || return 1
    sleep 1
    waited=$((waited + 1))
  done
  udevadm settle --timeout=30 || true
}

stick_mount() {
  local dev
  if [[ -n "${GVPN_RECOVERY_ASSUME_MOUNTED:-}" ]]; then
    mkdir -p "${STICK}"
    return 0
  fi
  wait_for_stick || stop "This USB stick was not recognised." "Call the support team."
  dev="$(stick_device)"
  mkdir -p "${STICK}"
  mount -o rw "${dev}" "${STICK}" || stop "This USB stick could not be read." "Call the support team."
}

# The public keys the stick carries, as "type blob" lines in PAYLOAD_LINES.
# Comments and options in the file are ignored: what the stick grants is
# decided here, not by whatever else happens to sit on its FAT partition.
# It fills a variable instead of printing, so a refusal ends the script rather
# than a subshell.
payload_keys() {
  local file="${STICK}/${PAYLOAD}"
  PAYLOAD_LINES=""
  if [[ ! -s "${file}" ]]; then
    stop "This USB stick is incomplete." "Call the support team."
  fi
  # A keys file written on Windows can carry CRLF line endings, which would put
  # a stray \r inside the key blob: sshd then rejects the line while the run
  # reports success. Strip it before matching.
  PAYLOAD_LINES="$(awk '{ sub(/\r$/, "") }
    $1 ~ /^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)$/ && $2 ~ /^AAAA/ { print $1, $2 }' "${file}")"
  [[ -n "${PAYLOAD_LINES}" ]] || stop "This USB stick carries no usable key." "Call the support team."
}

# --- finding the appliance ---------------------------------------------------

partition_devices() {
  # -l: without it lsblk draws a tree, and the name field starts with |- or
  # the box-drawing characters instead of the device path.
  lsblk -lpno NAME,TYPE | awk '$2 == "part" { print $1 }'
}

parent_disk() {
  lsblk -no PKNAME "$1" 2>/dev/null | head -n1
}

# The appliance is an ostree system, and ROOT is its root partition, not the
# booted view of it: what the running appliance sees as /var lives in
# ostree/deploy/<stateroot>/var. Prints the one stateroot /var that carries a
# gvpn-exit identity; fails when there is none or more than one.
appliance_var() {
  local var found=()
  for var in "${ROOT}"/ostree/deploy/*/var; do
    [[ -s "${var}/lib/gvpn-exit/identity/serial" ]] && found+=("${var}")
  done
  ((${#found[@]} == 1)) || return 1
  printf '%s\n' "${found[0]}"
}

# The deployment whose /etc and /usr the report reads: the one deployed last,
# by the mtime of its .origin file. /etc carries local changes into every new
# deployment, so after a rollback only the reported image version can differ
# from the booted one.
appliance_deployment() {
  local origin newest=""
  for origin in "${VAR%/var}"/deploy/*.origin; do
    [[ -f "${origin}" && -d "${origin%.origin}" ]] || continue
    if [[ -z "${newest}" || "${origin}" -nt "${newest}" ]]; then
      newest="${origin}"
    fi
  done
  [[ -n "${newest}" ]] || return 1
  printf '%s\n' "${newest%.origin}"
}

# Set VAR and DEPLOY for the mounted root, or refuse.
locate_appliance() {
  VAR="$(appliance_var)" || stop "This is not a GnosisVPN device." "Call the support team."
  DEPLOY="$(appliance_deployment)" || DEPLOY=""
}

looks_like_appliance() {
  local dev="$1"
  mount -o ro,norecovery "${dev}" "${ROOT}" 2>/dev/null || return 1
  if appliance_var >/dev/null; then
    umount "${ROOT}"
    return 0
  fi
  umount "${ROOT}"
  return 1
}

# Exactly one XFS partition that carries an ostree stateroot with a gvpn-exit
# identity, never the stick the recovery runs from. Identification mounts
# read-only and without log recovery, so a disk that is not the appliance is
# never written to and never has its journal replayed.
identify_root() {
  local stick_parent="" dev candidates=()
  dev="$(stick_device)"
  [[ -n "${dev}" ]] && stick_parent="$(parent_disk "${dev}")"
  mkdir -p "${ROOT}"
  while IFS= read -r dev; do
    [[ -n "${dev}" ]] || continue
    if [[ -n "${stick_parent}" && "$(parent_disk "${dev}")" == "${stick_parent}" ]]; then
      continue
    fi
    [[ "$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)" == xfs ]] || continue
    looks_like_appliance "${dev}" || continue
    candidates+=("${dev}")
  done < <(partition_devices)

  if ((${#candidates[@]} == 0)); then
    stop "No GnosisVPN device found." "Check the stick is in a USB port and" "call the support team."
  fi
  if ((${#candidates[@]} > 1)); then
    stop "More than one disk looks like a device." "Call the support team."
  fi
  ROOT_DEV="${candidates[0]}"
}

# --- the appliance -----------------------------------------------------------

home_dir() {
  printf '%s/home/devops\n' "${VAR}"
}

key_file() {
  printf '%s/.ssh/authorized_keys\n' "$(home_dir)"
}

# sshd ignores a key file, .ssh or home directory that group or others can
# write, so refuse instead of installing a key that cannot work.
check_modes() {
  local path mode
  for path in "$(home_dir)" "$(home_dir)/.ssh" "$(key_file)"; do
    [[ -e "${path}" ]] || continue
    mode="$(stat -c %a "${path}")"
    if ((8#${mode} & 8#022)); then
      stop "The device's SSH key file is not secured." "Call the support team."
    fi
  done
}

# devops's uid and gid, as the installer created the home directory.
devops_owner() {
  stat -c %u:%g "$(home_dir)"
}

# The installer always leaves an authorized_keys behind; if one is missing we
# create it and copy the SELinux type from .ssh, because no policy is loaded in
# the initramfs and sshd cannot read a wrongly labelled file.
ensure_key_file() {
  local dir owner
  dir="$(home_dir)/.ssh"
  [[ -f "$(key_file)" ]] && return 0
  owner="$(devops_owner)"
  { mkdir -p "${dir}" &&
    : >"$(key_file)" &&
    chown "${owner}" "${dir}" "$(key_file)" &&
    chmod 0700 "${dir}" &&
    chmod 0600 "$(key_file)"; } ||
    abort "The device's SSH key file could not be written."
  if ! chcon --reference="${dir}" "$(key_file)" 2>/dev/null &&
    ! chcon -t ssh_home_t "${dir}" "$(key_file)" 2>/dev/null; then
    warn "the SSH key file has no SELinux label."
    return 0
  fi
  log "created $(key_file), labelled from ${dir}"
}

key_fingerprint() {
  printf '%s' "$1" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1 | cut -c1-16
}

# A line an earlier stick wrote: expiry, key type, key blob, marker.
RECOVERY_LINE='^expiry-time="([0-9]+)Z" ([^ ]+) ([^ ]+) gvpn-recovery-[0-9]+$'

# sshd stops accepting a key at its expiry-time, a UTC YYYYMMDD[HHMM[SS]]
# stamp here, so a line is live while its stamp is later than now at the same
# precision.
expiry_live() {
  local expiry="$1" current
  current="$(date -u -d "@$(now)" +%Y%m%d%H%M%S)"
  [[ "${expiry}" > "${current:0:${#expiry}}" ]]
}

# Rebuild the key file around the stick's keys and set ADDED and SKIPPED.
#
# Lines the installer or an operator wrote are kept verbatim, and their key
# counts as present only on a plain line: one with options or commented out
# may not let it in. Lines an earlier stick wrote are kept only while they are
# live and their key is still on this stick, so an expired grant is renewed
# and a key dropped from the inventory loses its recovery line. Every new line
# carries an expiry, which keeps stale grants from lingering; it does not bind
# a stick that was tampered with.
#
# The file is rewritten in place, never replaced, so its SELinux label stays as
# the installer left it; owner and mode are set from the devops home.
inject_keys() {
  local key_type key_blob expiry marker line tmp
  local -A wanted=() present=()
  ADDED=0
  SKIPPED=0
  while read -r key_type key_blob; do
    [[ -n "${key_type}" ]] && wanted["${key_blob}"]=1
  done <<<"${PAYLOAD_LINES}"
  expiry="$(date -u -d "@$(($(now) + KEY_DAYS * 86400))" +%Y%m%dZ)"
  marker="gvpn-recovery-$(date -u -d "@$(now)" +%Y%m%d)"
  mkdir -p "${RUN_DIR}"
  tmp="$(state_file authorized_keys)"
  : >"${tmp}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${RECOVERY_LINE} ]]; then
      key_blob="${BASH_REMATCH[3]}"
      if [[ -n "${wanted[${key_blob}]:-}" ]] && expiry_live "${BASH_REMATCH[1]}"; then
        present["${key_blob}"]=1
        printf '%s\n' "${line}" >>"${tmp}"
      else
        log "dropped recovery key $(key_fingerprint "${key_blob}")"
      fi
      continue
    fi
    printf '%s\n' "${line}" >>"${tmp}"
    read -r key_type key_blob _ <<<"${line}"
    if [[ "${key_type}" =~ ^(ssh-|ecdsa-|sk-) && -n "${key_blob}" ]]; then
      present["${key_blob}"]=1
    fi
  done <"$(key_file)"

  while read -r key_type key_blob; do
    [[ -n "${key_type}" ]] || continue
    if [[ -n "${present[${key_blob}]:-}" ]]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    printf 'expiry-time="%s" %s %s %s\n' "${expiry}" "${key_type}" "${key_blob}" "${marker}" >>"${tmp}"
    present["${key_blob}"]=1
    ADDED=$((ADDED + 1))
    log "added ${key_type} key $(key_fingerprint "${key_blob}")"
  done <<<"${PAYLOAD_LINES}"

  { cat "${tmp}" >"$(key_file)" &&
    chown "$(devops_owner)" "$(key_file)" &&
    chmod 0600 "$(key_file)"; } ||
    abort "The device's SSH key file could not be written."
  rm -f "${tmp}"
}

# The deadline written here comes from the appliance's own clock, which on a
# device that has been off is not trustworthy. state/recovery-request is the
# authoritative half: support-window.sh rewrites the deadline, and the expiry
# of the keys added above, from the trusted clock at the first NTP-synchronized
# run and only then drops the marker. Sets DEADLINE.
open_window() {
  local state
  state="${VAR}/lib/gvpn-exit/state"
  DEADLINE="$(utc $(($(now) + DAYS * 86400)))"
  { mkdir -p "${state}" &&
    printf '%s\n' "${DEADLINE}" >"${state}/support-until" &&
    printf '%s\n' "${DAYS}" >"${state}/recovery-request" &&
    chmod 0644 "${state}/support-until" "${state}/recovery-request"; } ||
    abort "The device's support window could not be written."
}

support_env_value() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' \
    "${DEPLOY}/etc/gvpn-exit/support.env" 2>/dev/null || true
}

support_public_key() {
  sed -n 's/.*"support_public_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${VAR}/lib/gvpn-exit/identity/node.json" 2>/dev/null | head -n1 || true
}

image_version() {
  local version
  version="$(awk -F= '$1 == "VERSION" { print $2; exit }' "${DEPLOY}/usr/lib/os-release" 2>/dev/null || true)"
  version="${version#\"}"
  printf '%s\n' "${version%\"}"
}

host_key_line() {
  head -n1 "${DEPLOY}/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null || true
}

report_body() {
  local serial="$1" added="$2" skipped="$3" deadline="$4" warning
  printf 'gvpn-recovery report\n'
  printf 'written: %s\n' "$(utc "$(now)")"
  printf 'stick kernel: %s\n' "$(uname -r)"
  printf 'device serial: %s\n' "${serial}"
  printf 'device image: %s\n' "$(image_version)"
  printf 'bastion: %s\n' "$(support_env_value BASTION)"
  printf 'support port: %s\n' "$(support_env_value SUPPORT_PORT)"
  printf 'support public key: %s\n' "$(support_public_key)"
  printf 'device host key: %s\n' "$(host_key_line)"
  printf 'keys added: %s\n' "${added}"
  printf 'keys already present: %s\n' "${skipped}"
  printf 'support window written: %s\n' "${deadline}"
  while IFS= read -r warning; do
    printf 'warning: %s\n' "${warning}"
  done < <(warnings)
  printf 'result: OK\n'
}

# What the support team needs to finish the job without a second trip: which
# device, which bastion and port, which support key to admit, and what was
# added. Written to the stick's FAT partition so the person can send it back;
# the keys are on the device by now, so a stick that refuses the report is a
# warning, not a failure. Sets REPORT, empty when nothing was saved.
write_report() {
  local stamp
  stamp="$(date -u -d "@$(now)" +%Y%m%dT%H%M%SZ)"
  REPORT="${STICK}/gvpn-recovery/report-$1-${stamp}.txt"
  if ! { mkdir -p "${STICK}/gvpn-recovery" &&
    report_body "$@" >"${REPORT}" &&
    cp "${REPORT}" "${STICK}/gvpn-recovery/report.txt"; }; then
    REPORT=""
    warn "the report could not be saved to the stick."
  fi
}

# --- phases ------------------------------------------------------------------

cmd_prepare() {
  local dev="" serial
  rm -f "$(state_file warnings)"
  stick_mount
  payload_keys
  if [[ -z "${GVPN_RECOVERY_ASSUME_MOUNTED:-}" ]]; then
    identify_root
    dev="${ROOT_DEV}"
    write_state dev "${dev}"
    mount -o ro,norecovery "${dev}" "${ROOT}" ||
      stop "The device's disk could not be read." "Do not continue. Call the support team."
  fi
  locate_appliance
  serial="$(head -n1 "${VAR}/lib/gvpn-exit/identity/serial" 2>/dev/null || true)"
  [[ -n "${serial}" ]] || stop "This is not a GnosisVPN device." "Call the support team."
  check_modes
  write_state serial "${serial}"
  log "appliance ${serial} on ${dev:-${ROOT}}: prepare done"
}

cmd_apply() {
  local dev serial previous window_was_open=0 already=0
  dev="$(read_state dev)"
  serial="$(read_state serial)"
  payload_keys
  if [[ -n "${dev}" ]]; then
    # prepare left the root mounted read-only and without log recovery; that
    # mount cannot be upgraded in place, so mount read-write afresh.
    umount "${ROOT}" 2>/dev/null || true
    mount "${dev}" "${ROOT}" ||
      stop "The device's disk could not be read." "Do not continue. Call the support team."
  fi
  locate_appliance
  previous="$(head -n1 "${VAR}/lib/gvpn-exit/state/support-until" 2>/dev/null || true)"
  if [[ -n "${previous}" ]] && (($(date -d "${previous}" +%s 2>/dev/null || echo 0) > $(now))); then
    window_was_open=1
  fi
  ensure_key_file
  check_modes
  inject_keys
  open_window
  write_report "${serial}" "${ADDED}" "${SKIPPED}" "${DEADLINE}"
  sync
  if [[ -n "${dev}" ]]; then
    umount "${ROOT}" || abort "The device's disk could not be unmounted."
  fi
  # The stick holds the report; unmount it before the person on site is told to
  # pull it, so nothing is lost to a yank.
  if [[ -z "${GVPN_RECOVERY_ASSUME_MOUNTED:-}" ]]; then
    umount "${STICK}" || warn "the USB stick could not be unmounted."
  fi
  if ((ADDED == 0 && SKIPPED > 0 && window_was_open == 1)); then
    already=1
  fi
  write_state added "${ADDED}"
  write_state deadline "${DEADLINE}"
  write_state report "${REPORT}"
  write_state already "${already}"
  log "apply done: ${ADDED} added, ${SKIPPED} present, window until ${DEADLINE}"
}

cmd_finish() {
  local serial added deadline report already warning lines=()
  serial="$(read_state serial)"
  added="$(read_state added)"
  deadline="$(read_state deadline)"
  report="$(read_state report)"
  already="$(read_state already)"
  lines=("Device serial: ${serial}")
  if [[ "${already}" == "1" ]]; then
    lines+=("")
  else
    lines+=("Keys added: ${added}" "Support window: until ${deadline}" "")
  fi
  while IFS= read -r warning; do
    lines+=("Warning: ${warning}")
  done < <(warnings)
  lines+=("1. Photograph this screen and send it"
    "   to the support team."
    "2. Remove the USB stick."
    "3. Hold the power button until the"
    "   device turns off.")
  if [[ "${already}" == "1" ]]; then
    screen "ALREADY APPLIED" "${lines[@]}"
  else
    screen "SUCCESS" "${lines[@]}"
  fi
  log "report on the stick: ${report:-none}"
  power_off
}

cmd_fail() {
  abort "Something unexpected went wrong."
}

cmd_run() {
  cmd_prepare
  cmd_apply
  cmd_finish
}

main() {
  case "${1:-}" in
    prepare) cmd_prepare ;;
    apply) cmd_apply ;;
    finish) cmd_finish ;;
    fail) cmd_fail ;;
    run) cmd_run ;;
    *)
      echo "usage: ${0} prepare|apply|finish|fail|run" >&2
      exit 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

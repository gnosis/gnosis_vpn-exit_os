#!/usr/bin/env bash
# Render a bootc-image-builder config from image/bib/<kind>.toml.in and print
# it on stdout. Runs on the host, before tools/builder.sh, so key files can
# live anywhere (the builder container only mounts the repo).
#
#   tools/render-bib-config.sh iso|qcow2 SSH_PUBKEY_FILE
#
# SSH_PUBKEY_FILE becomes the devops user's authorized key, which is how the
# device is reached from its LAN. With GVPN_CONSOLE_ACCESS=1 the file is not
# read and the ISO installs a devops user with an expired console password and
# no SSH key: first access is the console, a VM console or a hardware
# keyboard and monitor, where the operator adds their own key.
#   GVPN_INSTALL_DISK         the disk the installer ISO's kickstart wipes (auto)
#                             auto: the installer picks the only internal disk
#                             (image/bib/select-install-disk.sh) and refuses to
#                             install when there is not exactly one; a kernel
#                             name such as nvme0n1 or sda pins that disk
#   GVPN_CONSOLE_ACCESS       1: console-configured, no installer SSH key
# For a device administered through a support bastion the installer ISO also
# carries the first-access tunnel, written to /etc/gvpn-exit by the kickstart
# %post, from these four, given together or not at all:
#   GVPN_BASTION              user@host, or ssh://user@host:port
#   GVPN_SUPPORT_PORT         reverse port on the bastion's loopback (1024-65535)
#   GVPN_ENROLL_KEY           enrollment private key file (OpenSSH format)
#   GVPN_BASTION_KNOWN_HOSTS  the bastion's host key(s), known_hosts format
# Such an ISO contains a private key: build one per device and keep the stick
# as safe as the key. Without them the ISO carries no secret and installs a
# device that dials nowhere.
set -euo pipefail

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../image/bib" && pwd)"
# user@host, or ssh://user@host:port (ssh reads a bare host:port as a hostname).
BASTION_RE='^([a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+|ssh://[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+(:[0-9]+)?)$'
# Password of the console-configured devops user; the kickstart expires it, so
# the first console login must change it. SSH stays key-only.
# shellcheck disable=SC2016 # the $... crypt hash is literal
CONSOLE_PASSWORD_HASH='$6$gvpn-exit$j7xn4gZetDeh6pNrgXd18GpRvr7xK2BLHpuv51nmGRgtL1K4dUBEV15ePl7UPapwA1WYpTApHXlgCPGWVQOJK0'

die() {
  echo "$*" >&2
  exit 1
}

# The value of variable $1 for error messages, "(unset)" when unset or empty.
shown() {
  if [[ -n "${!1:-}" ]]; then
    echo "'${!1}'"
  else
    echo "(unset)"
  fi
}

console_access() {
  case "${GVPN_CONSOLE_ACCESS:-0}" in
    ""|0|false) return 1 ;;
    1|true) return 0 ;;
    *) die "GVPN_CONSOLE_ACCESS must be 0 or 1, got $(shown GVPN_CONSOLE_ACCESS)" ;;
  esac
}

# Whether the operator gave any of the bastion inputs. One is enough to mean
# "this device uses a bastion": validate_enrollment then names what is missing
# instead of silently building a device without its tunnel.
enrollment_requested() {
  [[ -n "${GVPN_BASTION:-}${GVPN_SUPPORT_PORT:-}${GVPN_ENROLL_KEY:-}${GVPN_BASTION_KNOWN_HOSTS:-}" ]]
}

validate_enrollment() {
  [[ "${GVPN_BASTION:-}" =~ ${BASTION_RE} ]] \
    || die "GVPN_BASTION must be user@host or ssh://user@host:port, got $(shown GVPN_BASTION)"
  # No leading zeros: bash reads a leading-zero number as octal, so "08080"
  # would slip through a plain range check and then fail in ssh.
  if [[ ! "${GVPN_SUPPORT_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] \
      || (( GVPN_SUPPORT_PORT < 1024 || GVPN_SUPPORT_PORT > 65535 )); then
    die "GVPN_SUPPORT_PORT must be a port in 1024-65535, got $(shown GVPN_SUPPORT_PORT)"
  fi
  if [[ ! -r "${GVPN_ENROLL_KEY:-}" ]] || ! grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' "${GVPN_ENROLL_KEY}"; then
    die "GVPN_ENROLL_KEY must name an OpenSSH private key file, got $(shown GVPN_ENROLL_KEY)"
  fi
  [[ -s "${GVPN_BASTION_KNOWN_HOSTS:-}" ]] \
    || die "GVPN_BASTION_KNOWN_HOSTS must name a non-empty known_hosts file, got $(shown GVPN_BASTION_KNOWN_HOSTS)"
}

main() {
  local kind="${1:-}" pubkey_file="${2:-}" key_type key_data console=0
  local substitutions=()
  INSTALL_DISK="${GVPN_INSTALL_DISK:-auto}"
  case "${kind}" in
    iso|qcow2) ;;
    *) echo "usage: render-bib-config.sh iso|qcow2 SSH_PUBKEY_FILE" >&2; exit 64 ;;
  esac
  console_access && console=1

  if (( console )); then
    substitutions+=(
      -e "s|@DEVOPS_USER@|user --name=devops --groups=wheel --iscrypted --password \"${CONSOLE_PASSWORD_HASH}\"|"
      -e "s|@DEVOPS_SSHKEY@|# no SSH key: log in on the console to install your own|"
      -e "s|@DEVOPS_SSH_KEY@||"
      -e '/^@CONSOLE_\(BEGIN\|END\)@$/d'
    )
  else
    # Type and key only: the comment is free text that sed, kickstart and TOML
    # would each need quoted, and authorized_keys does not need it.
    read -r key_type key_data _ <<< "$(head -1 "${pubkey_file}")"
    # The same key types the recovery stick accepts, security keys included:
    # they are ordinary public key lines to sshd and to the kickstart.
    [[ "${key_type}" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)$ \
        && "${key_data}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
      || die "${pubkey_file} is not an SSH public key"
    substitutions+=(
      -e "s|@DEVOPS_USER@|user --name=devops --groups=wheel --lock|"
      -e "s|@DEVOPS_SSHKEY@|sshkey --username=devops \"${key_type} ${key_data}\"|"
      -e "s|@DEVOPS_SSH_KEY@|${key_type} ${key_data}|"
      -e '/^@CONSOLE_BEGIN@$/,/^@CONSOLE_END@$/d'
    )
  fi

  if [[ "${kind}" == iso ]]; then
    [[ "${INSTALL_DISK}" =~ ^[a-z0-9]+$ ]] \
      || die "GVPN_INSTALL_DISK must be auto or a kernel disk name such as nvme0n1 or sda, got $(shown INSTALL_DISK)"
    if [[ "${INSTALL_DISK}" == auto ]]; then
      # The installer's %pre picks the disk; its body is the selection script,
      # read in after the marker line, which goes.
      substitutions+=(
        -e "s|@WIPED_DISK@|the only internal disk, picked at install time,|"
        -e '/^@DISK_AUTO_\(BEGIN\|END\)@$/d'
        -e '/^@DISK_PINNED_BEGIN@$/,/^@DISK_PINNED_END@$/d'
        -e "/^@SELECT_INSTALL_DISK@\$/r ${TEMPLATE_DIR}/select-install-disk.sh"
        -e '/^@SELECT_INSTALL_DISK@$/d'
      )
    else
      substitutions+=(
        -e "s|@WIPED_DISK@|/dev/${INSTALL_DISK}|"
        -e "s|@INSTALL_DISK@|${INSTALL_DISK}|g"
        -e '/^@DISK_PINNED_\(BEGIN\|END\)@$/d'
        -e '/^@DISK_AUTO_BEGIN@$/,/^@DISK_AUTO_END@$/d'
      )
    fi
    if enrollment_requested; then
      validate_enrollment
      # base64 keeps the contents clear of kickstart, TOML and sed quoting.
      substitutions+=(
        -e '/^@ENROLLMENT_\(BEGIN\|END\)@$/d'
        -e "s|@SUPPORT_ENV_B64@|$(printf 'SUPPORT_PORT=%s\nBASTION=%s\n' "${GVPN_SUPPORT_PORT}" "${GVPN_BASTION}" | base64_one_line)|"
        -e "s|@BASTION_KNOWN_HOSTS_B64@|$(base64_one_line "${GVPN_BASTION_KNOWN_HOSTS}")|"
        -e "s|@ENROLL_KEY_B64@|$(base64_one_line "${GVPN_ENROLL_KEY}")|"
      )
    else
      # No bastion: the device gets no tunnel config and no key, so the whole
      # enrollment block goes.
      substitutions+=(-e '/^@ENROLLMENT_BEGIN@$/,/^@ENROLLMENT_END@$/d')
    fi
  fi
  sed "${substitutions[@]}" "${TEMPLATE_DIR}/${kind}.toml.in"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

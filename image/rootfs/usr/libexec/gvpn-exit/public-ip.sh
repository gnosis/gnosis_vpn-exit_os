#!/usr/bin/env bash
# Shared IPv4 discovery helpers. Source after lib.sh for logging.

GVPN_PUBLIC_IP_URLS="${GVPN_PUBLIC_IP_URLS:-https://checkip.amazonaws.com https://api.ipify.org https://www.cloudflare.com/cdn-cgi/trace}"
IPV4_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

is_ipv4() {
  [[ "$1" =~ ${IPV4_RE} ]]
}

# Whether IPv4 address $1 lies in CIDR $2 (both dotted quad).
ipv4_in_cidr() {
  local ip="$1" net="${2%/*}" bits="${2#*/}" a b c d ip_n net_n mask
  IFS=. read -r a b c d <<< "${ip}"
  ip_n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  IFS=. read -r a b c d <<< "${net}"
  net_n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ip_n & mask) == (net_n & mask) ))
}

# Do not publish private, shared, documentation or other special-use addresses.
is_public_ipv4() {
  is_ipv4 "$1" || return 1
  local cidr
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
      169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 192.0.0.0/24 \
      192.0.2.0/24 192.88.99.0/24 198.18.0.0/15 198.51.100.0/24 \
      203.0.113.0/24 224.0.0.0/3; do
    if ipv4_in_cidr "$1" "${cidr}"; then
      return 1
    fi
  done
}

# The reporter accepts any IPv4; announcement callers require public IPv4.
# The first valid answer wins; a disagreement is logged.
public_ip() {
  local validate="${1:-is_ipv4}" url answer found=""
  for url in ${GVPN_PUBLIC_IP_URLS}; do
    answer="$(curl -4 -fsS --max-time 10 "${url}" 2>/dev/null)" || continue
    case "${url}" in
      */cdn-cgi/trace) answer="$(awk -F= '$1 == "ip" {print $2}' <<< "${answer}")" ;;
    esac
    answer="$(tr -d '[:space:]' <<< "${answer}")"
    "${validate}" "${answer}" || continue
    if [[ -z "${found}" ]]; then
      found="${answer}"
    elif [[ "${answer}" != "${found}" ]]; then
      log "WARN public IP services disagree: ${found} vs ${answer} (${url})"
    fi
  done
  [[ -n "${found}" ]] && echo "${found}"
}

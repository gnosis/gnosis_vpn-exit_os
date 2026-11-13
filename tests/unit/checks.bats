#!/usr/bin/env bats
# Pure functions behind the greenboot health checks (checks.sh).

load helpers

setup() {
  setup_sandbox
  CHECKS="${LIBEXEC}/checks.sh"
}

teardown() {
  teardown_sandbox
}

FORWARD_OK='-P FORWARD DROP
-A FORWARD -i wggvpn -j GVPN_PRIVATE
-A FORWARD -o wggvpn -m set --match-set gvpn-blocklist src -j DROP
-A FORWARD -i wggvpn -m set --match-set gvpn-blocklist dst -j DROP
-A FORWARD -i wggvpn -o lan0 -j ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE
-A FORWARD -o wggvpn -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'

@test "forward_isolation_ok accepts the private jump ahead of every ACCEPT" {
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${FORWARD_OK}"
  [ "${status}" -eq 0 ]
}

# `iptables -S` prints a rule with every match module it was installed with, so
# the same jump reads differently once it carries a comment. The check is about
# what the rule does, not about the text.
@test "forward_isolation_ok accepts the jump with an added comment" {
  rules='-P FORWARD DROP
-A FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE
-A FORWARD -i wggvpn -o lan0 -j ACCEPT'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

@test "forward_isolation_ok rejects a narrowed jump that only some traffic takes" {
  rules='-P FORWARD DROP
-A FORWARD -i wggvpn -s 10.128.0.2/32 -j GVPN_PRIVATE
-A FORWARD -i wggvpn -o lan0 -j ACCEPT'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

# A negated match selects the opposite traffic and `-f` only fragments: neither
# keeps clients away from private ranges, and the exact-line check this replaced
# rejected both.
@test "forward_isolation_ok rejects a negated or fragment-only jump" {
  for jump in '-A FORWARD ! -i wggvpn -j GVPN_PRIVATE' \
    '-A FORWARD -i wggvpn -f -j GVPN_PRIVATE'; do
    rules="-P FORWARD DROP
${jump}
-A FORWARD -i wggvpn -o lan0 -j ACCEPT"
    run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

@test "forward_isolation_ok rejects an ACCEPT ahead of the private jump" {
  rules='-P FORWARD DROP
-A FORWARD -i wggvpn -o lan0 -j ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

@test "forward_isolation_ok rejects a missing private jump" {
  rules='-P FORWARD DROP
-A FORWARD -o wggvpn -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

@test "forward_isolation_ok rejects an ACCEPT policy" {
  rules='-P FORWARD ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

@test "input_isolation_ok requires the wggvpn drop ahead of the p2p accepts" {
  good='-P INPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i wggvpn -j DROP
-A INPUT -p tcp -m tcp --dport 9091 -j ACCEPT'
  bad='-P INPUT DROP
-A INPUT -p tcp -m tcp --dport 9091 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${good}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${bad}"
  [ "${status}" -ne 0 ]
}

@test "input_isolation_ok rejects a negated or fragment-only client drop" {
  for drop in '-A INPUT ! -i wggvpn -j DROP' '-A INPUT -i wggvpn -f -j DROP'; do
    rules="-P INPUT DROP
${drop}
-A INPUT -p tcp -m tcp --dport 9091 -j ACCEPT"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

@test "input_vpn_ping_ok rejects a negated or fragment-only allowance" {
  for ping in '-A INPUT ! -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT' \
    '-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -f -p icmp -m icmp --icmp-type 8 -j ACCEPT'; do
    rules="-P INPUT DROP
${ping}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# A comment is printed verbatim, so its text must not be read as rule syntax: a
# rule for lan0 whose comment reads like the isolation rule is not isolation.
@test "a comment that reads like a rule does not count as one" {
  fake_drop='-P INPUT DROP
-A INPUT -i lan0 -m comment --comment " -i wggvpn -j DROP " -j ACCEPT'
  fake_jump='-P FORWARD DROP
-A FORWARD -i lan0 -m comment --comment " -i wggvpn " -j GVPN_PRIVATE
-A FORWARD -i lan0 -j ACCEPT'
  fake_ping='-P INPUT DROP
-A INPUT -i lan0 -p icmp -m icmp --icmp-type 8 -m comment --comment " -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -j ACCEPT" -j DROP
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${fake_drop}"
  [ "${status}" -ne 0 ]
  run bash -c 'source "$1"; load_exit_env; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${fake_jump}"
  [ "${status}" -ne 0 ]
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${fake_ping}"
  [ "${status}" -ne 0 ]
}

# iptables prints a comment with an escaped quote and an interface or set name
# with spaces as-is, so a crafted name can read like more rule syntax. None of
# these rules isolates anything, and none may pass.
@test "a crafted name or an escaped quote does not pass for rule syntax" {
  escaped_quote='-P INPUT DROP
-A INPUT -i wggvpn -m comment --comment "x\" -j DROP \"" -j ACCEPT'
  spaced_interface='-P INPUT DROP
-A INPUT -i x -i wggvpn -j DROP'
  spaced_set='-P INPUT DROP
-A INPUT -i wggvpn -s 10.128.0.0/24 -d 10.128.0.1/32 -m set --match-set a -p icmp --icmp-type 8 b src -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  for rules in "${escaped_quote}" "${spaced_interface}"; do
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${spaced_set}"
  [ "${status}" -ne 0 ]
}

# Ahead of the client drop the only rule that names the tunnel interface is the
# verification ping. An ACCEPT or a jump for client traffic there is a way past
# the drop, with or without a service port.
@test "input_isolation_ok rejects a client rule ahead of the drop" {
  for rule in '-A INPUT -i wggvpn -p tcp -j ACCEPT' \
    '-A INPUT -i wggvpn -j SOME_CHAIN' \
    '-A INPUT -i wggvpn -p udp --dport 51820 -j ACCEPT'; do
    rules="-P INPUT DROP
${rule}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# What a rule ahead of the drop is called does not matter, only whether it can
# hand a client's packet on: a rule without `-i` matches the tunnel interface
# too, and a jump hands the decision to a chain this check cannot see.
@test "input_isolation_ok rejects an ACCEPT without an interface ahead of the drop" {
  for rule in '-A INPUT -s 10.128.0.0/24 -j ACCEPT' \
    '-A INPUT -p udp --dport 9091 -j ACCEPT'; do
    rules="-P INPUT DROP
${rule}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# A jump hands the packet to a chain this check cannot see into, which may
# accept it.
@test "input_isolation_ok rejects a jump to another chain ahead of the drop" {
  for rule in '-A INPUT -s 10.128.0.0/24 -j SOME_CHAIN' \
    '-A INPUT -s 10.128.0.0/24 -g SOME_CHAIN'; do
    rules="-P INPUT DROP
${rule}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# A rule for another interface, a DROP and an established-connection ACCEPT
# cannot pass tunnel traffic, so an operator's own rule ahead of the drop is not
# a finding.
@test "input_isolation_ok accepts rules ahead of the drop that cannot pass tunnel traffic" {
  rules='-P INPUT DROP
-A INPUT -i lan0 -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -s 203.0.113.0/24 -j DROP
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

# Logging what the drop catches means putting the LOG rule in front of it. A
# target that only logs, marks or clamps returns to the next rule and decides
# nothing, so it is not a way past the drop.
@test "input_isolation_ok accepts a logging rule ahead of the drop" {
  rules='-P INPUT DROP
-A INPUT -i wggvpn -j LOG --log-prefix "client: "
-A INPUT -i wggvpn -m limit --limit 5/min -j LOG --log-prefix "client: "
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

# QUEUE hands the packet to a program outside the ruleset, which can accept it.
@test "input_isolation_ok rejects a queue ahead of the drop" {
  rules='-P INPUT DROP
-A INPUT -i wggvpn -j NFQUEUE --queue-num 0
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

# An interface with a `+` wildcard covers every name it starts with, and a state
# list that also names NEW opens connections. Neither may pass for an allowance
# that cannot reach the tunnel.
@test "input_isolation_ok rejects a wildcard interface or a state list with NEW" {
  for rule in '-A INPUT -i wg+ -j ACCEPT' \
    '-A INPUT -i + -j ACCEPT' \
    '-A INPUT -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT' \
    '-A INPUT -m conntrack --ctstate INVALID,RELATED -j ACCEPT'; do
    rules="-P INPUT DROP
${rule}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# A set name is printed unquoted and a comment verbatim, so both can read like
# rule syntax: a fake interface, or a fake target in front of the real one.
@test "a set name cannot supply an interface or hide the real target" {
  fake_interface='-P INPUT DROP
-A INPUT -m set --match-set x -i lo src -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  hidden_target='-P INPUT DROP
-A INPUT -m set --match-set s -j DROP src -g GVPN_PRIVATE
-A INPUT -i wggvpn -j DROP'
  for rules in "${fake_interface}" "${hidden_target}"; do
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# iptables installs an interface name with spaces in it with only a warning and
# prints it back unquoted, so a rule that matches no interface can print like the
# client drop. Counting it as the drop would switch off the rest of the check.
@test "a fake client drop with a crafted interface name is not the drop" {
  for drop in '-A INPUT -i wggvpn -j DROP -j ACCEPT' \
    '-A INPUT -i wggvpn -g SOME_CHAIN -j DROP'; do
    rules="-P INPUT DROP
${drop}
-A INPUT -j ACCEPT"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# A name that ends in a space or in a word also reads like the drop, and such a
# rule matches no interface at all. The drop is the exact rule or it is not.
@test "a drop with a padded or extended interface name is not the drop" {
  for drop in '-A INPUT -i wggvpn  -j DROP' '-A INPUT -i wggvpn x -j DROP'; do
    rules="-P INPUT DROP
${drop}
-A INPUT -j ACCEPT"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
  for jump in '-A FORWARD -i wggvpn  -j GVPN_PRIVATE' '-A FORWARD -i wggvpn x -j GVPN_PRIVATE'; do
    rules="-P FORWARD DROP
${jump}
-A FORWARD -j ACCEPT"
    run bash -c 'source "$1"; load_exit_env; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# The verification ping is recognized by its fields, and its interface has to be
# the tunnel: a name that starts with it is a different interface.
@test "input_vpn_ping_ok rejects a padded interface name" {
  rules='-P INPUT DROP
-A INPUT -i wggvpn  -s 10.128.0.0/24 -d 10.128.0.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

# A set name is printed unquoted, so it can carry the words of a conntrack match
# into a rule that has none. The states are read from a match of the rule's own.
@test "a set name cannot pass for the conntrack match" {
  rules='-P INPUT DROP
-A INPUT -m set --match-set s -m conntrack --ctstate RELATED src -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

# An interface wildcard that does not cover the tunnel selects other traffic and
# is not a finding.
@test "an interface wildcard that misses the tunnel is allowed ahead of the drop" {
  for rule in '-A INPUT -i lan+ -j ACCEPT' '-A INPUT -i wggvpn0+ -j ACCEPT'; do
    rules="-P INPUT DROP
${rule}
-A INPUT -i wggvpn -j DROP"
    run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -eq 0 ]
  done
}

# In FORWARD an established-connection ACCEPT ahead of the private-range jump
# would carry a client's replies to a LAN host that connected to it.
@test "forward_isolation_ok rejects an established-connection ACCEPT ahead of the jump" {
  rules='-P FORWARD DROP
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE'
  run bash -c 'source "$1"; load_exit_env; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

@test "forward_isolation_ok rejects a rule without an interface ahead of the private jump" {
  for rule in '-A FORWARD -s 10.128.0.0/24 -j ACCEPT' \
    '-A FORWARD -s 10.128.0.0/24 -j SOME_CHAIN' \
    '-A FORWARD -s 10.128.0.0/24 -g SOME_CHAIN'; do
    rules="-P FORWARD DROP
${rule}
-A FORWARD -i wggvpn -j GVPN_PRIVATE"
    run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

@test "forward_isolation_ok rejects an interface wildcard ahead of the private jump" {
  rules='-P FORWARD DROP
-A FORWARD -i wg+ -j ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -ne 0 ]
}

@test "forward_isolation_ok accepts a rule for another interface ahead of the private jump" {
  rules='-P FORWARD DROP
-A FORWARD -i lan0 -o wggvpn -j ACCEPT
-A FORWARD -i wggvpn -j GVPN_PRIVATE'
  run bash -c 'source "$1"; forward_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

@test "input_isolation_ok accepts the verification ping ahead of the drop" {
  rules='-P INPUT DROP
-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP
-A INPUT -i lan0 -p tcp -m tcp --dport 22 -j ACCEPT'
  run bash -c 'source "$1"; load_exit_env; input_isolation_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

@test "input_vpn_ping_ok requires the verification ping ahead of the wggvpn drop" {
  good='-P INPUT DROP
-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  behind='-P INPUT DROP
-A INPUT -i wggvpn -j DROP
-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT'
  missing='-P INPUT DROP
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${good}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${behind}"
  [ "${status}" -ne 0 ]
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${missing}"
  [ "${status}" -ne 0 ]
}

# The check reads the fields that decide what the rule does, so a new match
# module, an added comment or a different field order does not read as "missing"
# and turn every provisioned boot red.
@test "input_vpn_ping_ok reads the rule's fields, not its printed text" {
  commented='-P INPUT DROP
-A INPUT -i wggvpn -s 10.128.0.0/24 -d 10.128.0.1/32 -p icmp -m icmp --icmp-type 8 -m comment --comment "client verification ping" -j ACCEPT
-A INPUT -i wggvpn -m comment --comment "clients never reach the host" -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${commented}"
  [ "${status}" -eq 0 ]
}

@test "input_vpn_ping_ok rejects an echo request for another address or type" {
  wrong_destination='-P INPUT DROP
-A INPUT -s 10.128.0.0/24 -d 10.128.0.2/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  wrong_type='-P INPUT DROP
-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 0 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  any_source='-P INPUT DROP
-A INPUT -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  for rules in "${wrong_destination}" "${wrong_type}" "${any_source}"; do
    run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${rules}"
    [ "${status}" -ne 0 ]
  done
}

# iptables prints a bare address as a /32, so an operator who leaves the prefix
# off WIREGUARD_ADDRESS must not make the check disagree with the live rule.
@test "input_vpn_ping_ok accepts the address without a prefix length" {
  printf 'WIREGUARD_ADDRESS=10.9.0.1\n' > "${GVPN_EXIT_OVERRIDES}"
  rules='-P INPUT DROP
-A INPUT -s 10.128.0.0/24 -d 10.9.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
}

# The rule is built from the same knobs render-wg-conf.sh renders the interface
# with, so a changed pool does not leave the client's ping behind the drop.
@test "input_vpn_ping_ok follows a changed WIREGUARD_CIDR and WIREGUARD_ADDRESS" {
  printf 'WIREGUARD_CIDR=10.9.0.0/24\nWIREGUARD_ADDRESS=10.9.0.1/32\n' > "${GVPN_EXIT_OVERRIDES}"
  rules='-P INPUT DROP
-A INPUT -s 10.9.0.0/24 -d 10.9.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -i wggvpn -j DROP'
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "${rules}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; load_exit_env; input_vpn_ping_ok <<< "$2"' _ "${CHECKS}" "$(printf '%s\n' '-P INPUT DROP' '-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT' '-A INPUT -i wggvpn -j DROP')"
  [ "${status}" -ne 0 ]
}

@test "self_ipset_rule_ok requires the static self-address drop" {
  present='-A GVPN_PRIVATE -d 10.0.0.0/8 -j DROP
-A GVPN_PRIVATE -m set --match-set gvpn-self dst -j DROP'
  absent='-A GVPN_PRIVATE -d 10.0.0.0/8 -j DROP'
  other_set='-A GVPN_PRIVATE -m set --match-set gvpn-blocklist dst -j DROP'
  run bash -c 'source "$1"; load_exit_env; self_ipset_rule_ok <<< "$2"' _ "${CHECKS}" "${present}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; load_exit_env; self_ipset_rule_ok <<< "$2"' _ "${CHECKS}" "${absent}"
  [ "${status}" -ne 0 ]
  run bash -c 'source "$1"; load_exit_env; self_ipset_rule_ok <<< "$2"' _ "${CHECKS}" "${other_set}"
  [ "${status}" -ne 0 ]
}

@test "ip6_policies_drop requires DROP on all three chains" {
  good='-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A INPUT -i lo -j ACCEPT'
  bad='-P INPUT DROP
-P FORWARD DROP
-P OUTPUT ACCEPT'
  run bash -c 'source "$1"; ip6_policies_drop <<< "$2"' _ "${CHECKS}" "${good}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; ip6_policies_drop <<< "$2"' _ "${CHECKS}" "${bad}"
  [ "${status}" -ne 0 ]
}

@test "wait_units_active returns once all units are active" {
  mock_cmd systemctl 'exit 0'
  run bash -c 'source "$1"; wait_units_active 5 a.service b.service' _ "${CHECKS}"
  [ "${status}" -eq 0 ]
}

@test "wait_units_active names the units that never came up" {
  mock_cmd systemctl '[[ "$*" == *b.service* ]] && exit 3; exit 0'
  mock_cmd sleep
  run bash -c 'source "$1"; wait_units_active 2 a.service b.service' _ "${CHECKS}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"b.service"* ]]
  [[ "${output}" != *"a.service"* ]]
}

@test "snapshots_to_prune keeps the deployments bootc still has" {
  mkdir -p "${SANDBOX}/snaps/sha256:booted" "${SANDBOX}/snaps/sha256:rollback" "${SANDBOX}/snaps/sha256:gone" "${SANDBOX}/snaps/sha256:older"
  run bash -c 'source "$1"; snapshots_to_prune "$2" sha256:booted sha256:rollback ""' _ "${CHECKS}" "${SANDBOX}/snaps"
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | sort | xargs -n1 basename | xargs)" = "sha256:gone sha256:older" ]
}

@test "record_rejected_digest appends and keeps the last ten" {
  for i in $(seq 1 12); do
    bash -c 'source "$1"; record_rejected_digest "sha256:d$2"' _ "${CHECKS}" "${i}"
  done
  [ "$(wc -l < "${GVPN_STATE_DIR}/rejected-digests")" -eq 10 ]
  [ "$(head -1 "${GVPN_STATE_DIR}/rejected-digests")" = "sha256:d3" ]
  [ "$(tail -1 "${GVPN_STATE_DIR}/rejected-digests")" = "sha256:d12" ]
}

@test "record_rejected_digest does not duplicate an entry" {
  bash -c 'source "$1"; record_rejected_digest sha256:x; record_rejected_digest sha256:x' _ "${CHECKS}"
  [ "$(wc -l < "${GVPN_STATE_DIR}/rejected-digests")" -eq 1 ]
}

@test "unit_stays_up passes when the unit stays active without restarting" {
  mock_cmd systemctl '[[ "$1" == show ]] && echo 3; exit 0'
  mock_cmd sleep
  run bash -c 'source "$1"; unit_stays_up a.service 60' _ "${CHECKS}"
  [ "${status}" -eq 0 ]
  grep -qx 'sleep 60' "${MOCK_LOG}"
}

@test "unit_stays_up fails when the unit restarts meanwhile" {
  echo 3 > "${SANDBOX}/restarts"
  mock_cmd systemctl "[[ \"\$1\" == show ]] || exit 0; n=\"\$(cat '${SANDBOX}/restarts')\"; echo \"\${n}\"; echo \$((n + 1)) > '${SANDBOX}/restarts'"
  mock_cmd sleep
  run bash -c 'source "$1"; unit_stays_up a.service 60' _ "${CHECKS}"
  [ "${status}" -ne 0 ]
}

@test "unit_stays_up fails when the unit is down afterwards" {
  mock_cmd systemctl '[[ "$1" == show ]] && echo 0; [[ "$1" != is-active ]]'
  mock_cmd sleep
  run bash -c 'source "$1"; unit_stays_up a.service 60' _ "${CHECKS}"
  [ "${status}" -ne 0 ]
}

@test "provisioned_blokli_url reads the URL hoprd is provisioned with" {
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc"
  printf 'HOPRD_SAFE_ADDRESS=0xaa\nHOPRD_BLOKLI_URL=https://blokli.example\n' > "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  run bash -c 'source "$1"; provisioned_blokli_url' _ "${CHECKS}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://blokli.example" ]
}

@test "provisioned_blokli_url falls back to the v4 file until the v5 one exists" {
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc/hoprd-v5"
  export GVPN_HOPRD_V4_ENV_DIR="${SANDBOX}/etc/hoprd"
  mkdir -p "${GVPN_HOPRD_V4_ENV_DIR}"
  printf 'HOPRD_SAFE_ADDRESS=0xaa\nHOPRD_BLOKLI_URL=https://blokli-v4.example\n' > "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env"
  run bash -c 'source "$1"; provisioned_blokli_url' _ "${CHECKS}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://blokli-v4.example" ]
  mkdir -p "${GVPN_HOPRD_ENV_DIR}"
  printf 'HOPRD_SAFE_ADDRESS=0xbb\nHOPRD_BLOKLI_URL=https://blokli-v5.example\n' > "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  run bash -c 'source "$1"; provisioned_blokli_url' _ "${CHECKS}"
  [ "${output}" = "https://blokli-v5.example" ]
}

@test "blokli_answers sends hoprd's startup request: a GraphQL query to URL/graphql" {
  mock_cmd curl
  run bash -c 'source "$1"; blokli_answers https://blokli.example/' _ "${CHECKS}"
  [ "${status}" -eq 0 ]
  grep -q -- '-f' "${MOCK_LOG}"
  grep -q -- '--data {"query":"{__typename}"} https://blokli.example/graphql$' "${MOCK_LOG}"
}

@test "blokli_answers fails on an HTTP error, not only on no connection" {
  mock_cmd curl 'exit 22'
  run bash -c 'source "$1"; blokli_answers https://blokli.example' _ "${CHECKS}"
  [ "${status}" -ne 0 ]
}

# The device pipes `iptables -S <chain>` into these readers under pipefail. A
# chain longer than one pipe buffer (64 KiB) leaves the writer mid-write when a
# reader answers on its first lines; without draining, the writer dies of
# SIGPIPE and its 141 becomes the check's answer, which turns a healthy boot red.
long_listing() {
  local file="$1" i
  shift
  {
    printf '%s\n' "$@"
    for i in $(seq 1 3000); do
      printf '%s\n' '-A INPUT -i lan0 -s 10.0.0.0/8 -p tcp -m tcp --dport 22 -j ACCEPT'
    done
  } > "${file}"
  [ "$(stat -c %s "${file}")" -gt 65536 ]
}

@test "input_vpn_ping_ok drains a listing longer than one pipe buffer" {
  long_listing "${SANDBOX}/input.rules" '-P INPUT DROP' \
    '-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT' \
    '-A INPUT -i wggvpn -j DROP'
  run bash -c 'set -euo pipefail; source "$1"; load_exit_env; cat "$2" | input_vpn_ping_ok' \
    _ "${CHECKS}" "${SANDBOX}/input.rules"
  [ "${status}" -eq 0 ]
}

@test "self_ipset_rule_ok drains a listing longer than one pipe buffer" {
  long_listing "${SANDBOX}/private.rules" '-A GVPN_PRIVATE -m set --match-set gvpn-self dst -j DROP'
  run bash -c 'set -euo pipefail; source "$1"; load_exit_env; cat "$2" | self_ipset_rule_ok' \
    _ "${CHECKS}" "${SANDBOX}/private.rules"
  [ "${status}" -eq 0 ]
}

#!/bin/bash
# dracut pre-pivot hook: add the keys, open the support window and power off.
#
# This hook must not return normally: dracut would go on to switch into the
# empty root, fail and power off without a verdict for the person on site.
# `apply` mounts the appliance read-write; only once it succeeded does
# `finish` print the verdict. Anything else prints a failure. Both power off
# and never return.
gvpn_recovery="${GVPN_RECOVERY_SCRIPT:-/usr/libexec/gvpn-recovery.sh}"
if "${gvpn_recovery}" apply; then
  "${gvpn_recovery}" finish
else
  "${gvpn_recovery}" fail
fi

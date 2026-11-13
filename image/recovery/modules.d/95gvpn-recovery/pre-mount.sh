#!/bin/bash
# dracut pre-mount hook: find the appliance and mount its root read-only.
#
# dracut sources this hook from /bin/sh without errexit and ignores how it
# ends, so a failure the script did not turn into a verdict itself is shown
# here. The script powers the appliance off on every refusal and failure, so
# this hook never returns with the person on site staring at an error.
gvpn_recovery="${GVPN_RECOVERY_SCRIPT:-/usr/libexec/gvpn-recovery.sh}"
"${gvpn_recovery}" prepare || "${gvpn_recovery}" fail

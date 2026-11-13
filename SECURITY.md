# Security policy

## Supported versions

This project is under development. Security fixes target the latest code on
the default branch; older revisions and deployed images have no guaranteed
security maintenance. Publication does not imply production readiness. See
the [roadmap](docs/roadmap.md) and [acceptance gate](docs/first-install.md#7-acceptance-gate)
for acceptance gaps.

## Reporting a vulnerability

Do not disclose vulnerabilities in public issues, pull requests or discussions.
Use this repository's **Security > Advisories > Report a vulnerability** action
on GitHub to submit a private report; GitHub keeps it visible only to the
maintainers.

If that action is unavailable, open a public issue that asks for a private
channel and says nothing about the vulnerability: no affected version, no
component, no impact. A maintainer will reply with a private route. Never put
the details in that issue.

Include the affected commit or image version, expected and observed behavior,
impact, and minimal reproduction steps. Use disposable test environments and
redact credentials, device identities and operator information. Do not attach
private keys, enrollment ISOs or unredacted device logs.

Test only systems you own or are explicitly authorized to assess. Coordinate
public disclosure with the maintainers after remediation. Response times are
not guaranteed.

The support bastion and upstream dependencies are maintained outside this
repository. Report vulnerabilities specific to those systems to their
respective maintainers through private reporting channels. The fleet backend
is not implemented, part of the [roadmap](docs/roadmap.md#fleet-and-onboarding).

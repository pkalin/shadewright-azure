# Security policy

This repository holds the Terraform for the Shadewright reference lab. Shadewright is pre-release (0.x); the
`main` branch is the only supported version.

## Reporting a vulnerability

Report privately through GitHub: [open a security advisory for this repository](https://github.com/pkalin/shadewright-azure/security/advisories/new).
The form is private: only the maintainer sees it. Do not open a public issue or pull request for a vulnerability.

A problem in the operator or its images belongs in the [operator's advisory form](https://github.com/pkalin/shadewright/security/advisories/new);
its [security policy](https://github.com/pkalin/shadewright/blob/main/SECURITY.md) describes scope, timelines and
what counts as a vulnerability.

In scope here: an identity, role, firewall or network setting that grants more than the design says (for
example an executor identity that can do more than sign one key, or an analyzer identity that can read or
overwrite analysis records), and anything that would leak a secret or state into Git or logs. A lab that costs
more than it should is a bug, not a vulnerability: open an issue.

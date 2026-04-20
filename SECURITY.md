# Security Policy

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, use GitHub's private vulnerability reporting:

1. Go to the [Security Advisories](https://github.com/ibis-coordination/Harmonic/security/advisories) page
2. Click **"Report a vulnerability"**
3. Fill in the details and submit

This creates a private channel between you and the maintainers. We will:

- **Acknowledge receipt** within 48 hours
- **Confirm the vulnerability** and provide an estimated fix timeline within 7 days
- **Release a fix** within 90 days of confirmation (sooner for critical issues)
- **Publish a security advisory** once the fix is deployed, crediting the reporter unless they prefer anonymity

We ask that reporters give us reasonable time to patch before public disclosure.

If private vulnerability reporting is not available, email **dan.allison@protonmail.com** with the subject line `[SECURITY] Harmonic` and include:

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Any potential mitigations you've identified

## Security Hotfix Process

For maintainers responding to a reported vulnerability, see the [Security Hotfix Workflow](docs/DEPLOYMENT.md#security-hotfix-workflow) in the deployment guide.

## Supported Versions

Only the latest release is actively supported with security updates.

## Scope

The following are in scope for security reports:

- The Harmonic Rails application
- The agent-runner service
- The MCP server
- Authentication and authorization flows
- Multi-tenancy isolation
- API token handling and billing

The following are out of scope:

- Third-party dependencies (report upstream; if the issue affects Harmonic specifically, report here)
- Issues requiring physical access to the server
- Social engineering attacks

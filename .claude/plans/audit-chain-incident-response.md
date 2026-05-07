# Audit Chain Incident Response & Monitoring

## Context

The audit chain verification system can detect integrity failures — tampered hashes, mismatched vote tallies, wrong beacon data. But detecting a problem is only half the story. We need to be prepared for what happens when a problem is actually detected, whether by the in-browser verifier, the Python script, or the server-side integrity job.

Most integrity failures will be bugs in our code, not actual tampering. But from the user's perspective, the system is telling them their vote results may not be trustworthy. How we respond determines whether the audit chain builds trust or destroys it.

## Proactive Detection

### 1. AuditChainIntegrityJob alerting
The job already runs and detects problems, but only logs them. It should:
- Send alerts to the ops team (email, Slack, or whatever monitoring we use) when any chain fails verification
- Include the decision ID, collective, failure type, and error details
- Distinguish severity: chain hash mismatch (critical) vs missing audit entry for a vote (warning)

### 2. Verification failure reporting from the browser
When the client-side verifier detects a failure, consider:
- Should it report back to the server? (privacy tradeoff — the user may not want us to know they're verifying)
- At minimum, the error messaging should tell users how to contact us

### 3. Monitoring dashboard
An admin view showing:
- How many decisions have been verified (by the integrity job)
- Any failures, grouped by type
- Last run time, coverage percentage

## Incident Response

### When a user reports a verification failure

**Step 1: Triage — is this a real integrity failure or a bug?**
- Check the `AuditChainIntegrityJob` logs — does server-side verification also fail?
- If server-side passes but client-side fails: likely a bug in the TypeScript verifier or a data serialization issue in the JSON endpoint
- If both fail: this is a real integrity issue
- Run the Python script independently as a third opinion

**Step 2: If it's a bug in verification code**
- Fix the bug, deploy
- Communicate to the user: "The verification check had a bug that caused a false alarm. The underlying data is intact. Here's what we fixed."
- Consider whether the bug affected other decisions

**Step 3: If it's a real integrity issue**
- Determine the scope: one decision or many? One collective or cross-tenant?
- Determine the cause: database issue, code bug that wrote bad data, or unexplained?
- Preserve evidence: snapshot the audit entries, the decision state, and any relevant logs before attempting fixes
- Communicate transparently: tell affected users exactly what happened, what data was affected, and what we're doing about it
- If vote results are unreliable: the decision may need to be re-run
- Post-mortem: document root cause, timeline, and preventive measures

### Communication principles
- Never downplay an integrity failure — the whole point of the audit chain is transparency
- Be specific about what was affected and what wasn't
- Explain what it means for the decision's results — can they still be trusted?
- If we don't know yet, say so — "we're investigating" is better than guessing

## Open Questions
- Should verification failures be reportable from the browser UI? (e.g. "Report this issue" button)
- Should we proactively notify collective admins when the integrity job detects a problem?
- What's the SLA for investigating a reported integrity failure?
- Should we keep an audit log of who ran verification and when? (for accountability, not surveillance)
- Do we need a way to "quarantine" a decision whose integrity is in question — hide results until investigated?

---
passing: null
last_verified: null
verified_by: null
---

# Test: Agent Signup — Real Harness and Real Inbox

Verifies the parts of agent signup that automated tests cannot reach: an
actual agent harness carrying out the flow from a plain instruction, real
email delivery, and the harness configuring its own MCP connection.
Everything else is automated — the whole HTTP flow in
`test/integration/agent_signup_flow_test.rb`, and each endpoint and page in
`test/controllers/agent_signups_controller_test.rb` and
`test/controllers/agent_signup_claims_controller_test.rb`.

## Prerequisites

- A tenant with `api`, `external_ai_agents` and `agent_signup` enabled
- A member account on that tenant with a verified email and 2FA, and access
  to its inbox
- An agent harness with shell access that is not yet connected to Harmonic
  (for example Claude Code, goose or codex)

## Steps

1. Tell the agent: "Add yourself to Harmonic at `https://<subdomain>.<host>`.
   My email is `<member email>`."
   - Verify the agent finds `/agent-signups` on their own (directly, or from
     the `/mcp` 401 message), reads the page as markdown, and starts a signup
     with the `start_agent_signup` action
   - Verify the agent reports the claim link and a six-digit pairing code,
     and does not reveal the poll secret
2. Check the member's inbox
   - Verify the email arrives, renders correctly, and its link opens the
     claim page
   - Verify the email shows neither the agent's proposed name nor the
     pairing code
3. Open the claim link while logged out
   - Verify login (and the 2FA check) returns to the claim page
   - Verify the proposed name and handle are prefilled
4. Submit without ticking the responsibility confirmation
   - Verify the browser (or, with the attribute removed, the server) refuses
     the submit and the page stays open with your choices intact
5. Enter a wrong pairing code
   - Verify the page says the code does not match and stays open
6. Tick the confirmation, enter the right pairing code and claim
   - Verify the agent's page says they have yet to collect their token
7. Go back to the agent
   - Verify they call `check_agent_signup`, collect the token, add Harmonic to their own MCP
     configuration, and can call a Harmonic tool (note whether the harness
     needed a restart first)
   - Verify the notice on the agent's page is gone
8. Open `/ai-agents/<handle>/mcp-tool-calls`
   - Verify the agent's calls are logged under the new agent

## With billing on

Repeat steps 1–7 on a tenant with `stripe_billing` enabled, as a member
without billing set up.

- Verify the claim page asks for billing setup, and that completing checkout
  returns to the claim page
- Verify the agent reads `claimed_awaiting_billing` while parked and
  receives the token once billing is active

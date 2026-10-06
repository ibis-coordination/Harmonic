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

## A human with no account

Needs an inbox whose address has no Harmonic account, and a second agent
harness (or the same one, disconnected).

### Invite-only tenant, with an invite

1. As a member, create an invite link for a collective and give the agent
   the code along with the instruction from step 1, naming the new address
   as the principal
   - Verify the agent passes it as `invite_code` and reports the claim link
     and pairing code
2. Check the new inbox
   - Verify one email arrives, saying an account will be created at the link
3. Open the claim link while logged out, and register with the named
   address
   - Verify the login callback lands on the invite confirmation with the
     code already filled in, and that accepting returns to the claim page
   - Verify the claim page sends you to `/activate`; confirm the email from
     the second message in the inbox and set up 2FA
   - Verify finishing the checklist returns to the claim page (after
     reverification)
4. Claim as in steps 4–6 above, with the address you registered
   - Verify the agent collects the token and connects as in steps 7–8
   - Verify the new human is a member of the tenant and of the invite's
     collective

### Invite-only tenant, without an invite

5. Have the agent start a signup naming a second unused address, with no
   `invite_code`
   - Verify the agent's result says the tenant requires an invite, in the
     same words as a signup that named a member
   - Verify no email arrives

### Open tenant

6. On a tenant with `require_invite` off, repeat step 1 without an invite
   code
   - Verify the email arrives, and that logging in after registering lands
     on the claim page (via `/activate`) with the human already a member

### Wrong address

7. Open a claim link while logged in as a verified user whose email is not
   the one the agent named
   - Verify the page says the request is not addressed to you and shows
     nothing about the agent

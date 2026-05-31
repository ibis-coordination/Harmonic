# Turbo + action endpoint silent-fail fix

## Problem

`render_action_success` / `render_action_error` in `ApplicationController` (shipped pre-Turbo) return **200 OK with HTML**. Turbo Drive (enabled in v1.20) expects form submissions to return:

- **3xx** — follows the redirect
- **422** — re-renders the form with errors
- **200 with `<turbo-stream>`** — applies the stream

A plain 200-with-HTML response is silently dropped: Turbo intercepts the form submit, gets the 200, and does nothing. **The browser stays on the form, no error, no feedback** — both on the success AND failure paths.

We hit this on the automation create form. Fixed it locally with `data-turbo="false"` on the form ([app/views/collective_automations/new.html.erb](app/views/collective_automations/new.html.erb), [edit.html.erb](app/views/collective_automations/edit.html.erb), [show.html.erb](app/views/collective_automations/show.html.erb)). The underlying problem is in the shared `render_action_*` helpers, which are used across ~14 controllers.

## Fix approaches

**Option A — Make `render_action_*` Turbo-compatible (preferred long-term).**

In `ApplicationController#render_action_success` / `render_action_error`, detect HTML format and redirect with flash; keep markdown/JSON behavior unchanged so the action API contract stays the same.

```ruby
def render_action_success(locals)
  respond_to do |format|
    format.html do
      flash[:notice] = locals[:result]
      redirect_to(locals[:redirect_to] || request.referrer || "/")
    end
    format.md  { render "shared/action_success", locals: ... }
    format.json { render "shared/action_success", locals: ... }
  end
end

def render_action_error(locals)
  respond_to do |format|
    format.html do
      flash[:error] = locals[:error]
      redirect_to(locals[:redirect_to] || request.referrer || "/")
    end
    format.md  { render "shared/action_error", locals: ..., status: :unprocessable_entity }
    format.json { render "shared/action_error", locals: ..., status: :unprocessable_entity }
  end
end
```

Already-passed `redirect_to:` locals are currently ignored — this would activate them. Audit callers for stale or wrong paths first.

**Option B — Opt out per-form (what we did for automations).**

Add `data-turbo="false"` to forms that target action endpoints. Cheap, local. But leaves the next person who adds a form with the same broken default. And conflicts with `data-turbo-confirm` (see "Confirm dialogs" below).

Recommendation: do Option A, then remove the per-form opt-outs.

## Confirm dialogs (`data-turbo-confirm`)

`data-turbo-confirm` requires Turbo to intercept the submit — it can't coexist with `data-turbo="false"`. We left the Delete button on automation show with `data-turbo-confirm` and Turbo enabled (so the user gets a confirm prompt but the response is dropped — pre-existing issue).

After Option A lands, `data-turbo-confirm` works fine on action-endpoint forms because the response is a real redirect.

Alternative if we keep Option B somewhere: a `confirm-submit` Stimulus controller (mentioned in the v1.20 CHANGELOG but not actually present in the codebase) that fires `window.confirm` before submission and lets the browser handle the post natively.

## Audit checklist

Controllers using `render_action_*` (any HTML form pointing here is suspect):

- agent_automations
- ai_agents
- api_tokens
- chats
- collective_automations (fixed locally for new/edit/show — except Delete)
- collectives
- commitments
- concerns/attachment_actions
- decisions
- heartbeats
- notes
- notifications
- trustee_grants
- whoami

For each: find any HTML view that POSTs to one of its `/actions/<name>` endpoints. Confirm whether the form is intercepted by Turbo and whether the response is rendered or silently dropped. Quickest sanity check: submit each form in a browser; if the user lands on a page that says "Action Success:" / "Action Error:", Turbo's not catching it (rare — usually means the form had `data-turbo="false"` already or no Turbo on the page). If the form appears to do nothing, it's broken.

## Out of scope

- The `render_action_*` templates themselves (`shared/action_success.html.erb`, `shared/action_error.html.erb`) — they're fine as content; the issue is the response status + Turbo's behavior.
- Markdown/JSON action API behavior — keep unchanged. The action API contract is "200 with structured response describing success or failure"; only the HTML browser path needs Turbo-compatible plumbing.
- The Delete-confirm Stimulus controller — write only if Option A doesn't land and we keep `data-turbo="false"` on confirm-dialog forms.

## Related: cross-origin redirects (already fixed locally)

Turbo Drive also silently blocks **cross-origin redirects**. A form POST that returns a 302 to a different host (e.g., our Upgrade flow's `BillingRequired` → redirect to `checkout.stripe.com`) does nothing: Turbo intercepts the submission, gets the cross-origin location, refuses to navigate, and leaves the user on the form.

Fixed locally on the collective/workspace/automations-index Upgrade buttons by adding `data: { turbo: "false" }` to their forms ([collectives/settings.html.erb](app/views/collectives/settings.html.erb), [users/settings.html.erb](app/views/users/settings.html.erb), [collective_automations/index.html.erb](app/views/collective_automations/index.html.erb)). Side effect: had to drop the `data-turbo-confirm` dialog on those buttons (Turbo Confirm requires Turbo to intercept; can't coexist with `data-turbo="false"`). Stripe Checkout is the real confirmation step anyway.

Audit any other form that posts to an action that might redirect cross-origin — known candidates:

- `BillingController#setup` (POST `/billing/setup`) — redirects to `checkout.stripe.com` (the "Set up billing" button on `/billing` and the post-signup billing-gate flow)
- `BillingController#portal` — redirects to Stripe's billing portal (cross-origin)
- `BillingController#reactivate_collective` (POST `/billing/reactivate_collective/:handle`) — when payment confirmation is required, may redirect to Stripe Checkout
- `AiAgentsController#create` — when no active subscription, may redirect to `/billing` (same origin, fine) — but verify
- Any other form that ultimately leads to Stripe Checkout

Same fix: `data: { turbo: "false" }` on the form, drop Turbo-Confirm there. Or write a generic Stimulus controller (`browser-form`) that opts out of Turbo at the form level so it can be applied uniformly.

## Suggested execution

1. Audit callers of `render_action_success` / `render_action_error` — write down the `redirect_to:` value each caller currently passes (many ignore it / pass nothing).
2. Decide the default redirect target when `redirect_to:` is absent (probably `request.referrer || current_collective.path`).
3. Implement Option A in `ApplicationController`.
4. Remove the per-form `data-turbo="false"` workarounds from collective_automations views.
5. Manual-test a representative form per affected controller.
6. Add an integration test that exercises the HTML form path on at least one action endpoint to catch this class of regression in CI.

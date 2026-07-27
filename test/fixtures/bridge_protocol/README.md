# bridge_protocol fixtures

Canonical request/response shapes for the `harmonic-bridge` ↔ Harmonic
protocol. Both the Ruby controller tests
([test/controllers/harmonic_bridge_setups_controller_test.rb](../../controllers/harmonic_bridge_setups_controller_test.rb))
and the TypeScript bridge tests
([harmonic-bridge/src/add.test.ts](../../../harmonic-bridge/src/add.test.ts))
load fixtures from this directory and assert structural conformance.

The point: if someone renames a field on one side, the OTHER side's tests
fail at the fixture-shape check. The two implementations validate against
the same source of truth instead of stubbing each other with hand-rolled
shapes.

Values in the fixtures are illustrative — the helpers assert TYPE and key
PRESENCE, not literal equality. So `"harmonic_token": "tok_example"`
documents "this field is a string"; the actual response value is anything
non-empty.

| Fixture | Direction | When |
|---|---|---|
| `redeem_response.json` | Harmonic → bridge | `POST /bridge-setups/:public_id` success body |
| `redeem_response_with_llm.json` | Harmonic → bridge | Same, when the setup opted into an LLM gateway token and one was minted: base shape + `harmonic_llm_endpoint` and `harmonic_llm_token`. (Opted in but not mintable → base shape + a `harmonic_llm_status` string instead. The model is not on the wire — it's the bridge's `--model` flag, defaulting to the `"default"` sentinel the gateway resolves.) |
| `post_request.json` | bridge → Harmonic | `POST /bridge-setups/:public_id/webhook` request body |
| `post_response.json` | Harmonic → bridge | `POST /bridge-setups/:public_id/webhook` success body |
| `post_error_webhook_unreachable.json` | Harmonic → bridge | `POST` 422 body when verification fails |

To add a new field, update the fixture and at least one test on each
side will fail until both implementations are updated.

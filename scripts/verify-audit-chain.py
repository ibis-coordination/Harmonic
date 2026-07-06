#!/usr/bin/env python3
"""Verify a Harmonic decision's audit chain, vote totals, and sort keys.

Usage: python3 verify.py verify.json

Exit code 0 = all checks passed, 1 = verification failed.
"""
import hashlib, json, math, sys, unicodedata, urllib.request
from datetime import datetime, timezone

# drand quicknet chain parameters (public, independently verifiable)
DRAND_BASE_URL = "https://api.drand.sh"
DRAND_CHAIN_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
DRAND_GENESIS_TIME = 1692803367
DRAND_PERIOD = 3

data = json.load(open(sys.argv[1]))
ok = True

# 1. Verify audit chain: replay each hash and check the links.
#    Each entry's hash covers all its fields plus the previous entry's hash,
#    forming a chain. If any entry was altered, all subsequent hashes break.
#    Identity is bound via `actor_token`, a SHA256 commitment that lets PII
#    be scrubbed without invalidating the chain (see step 1b).
#    v3 entries additionally commit to the representation dimension:
#    representative_token and representation_kind sit right after actor_token
#    (both empty for direct actions). Entries recorded before v3 do not carry
#    representation data — for those, "who acted" and "on whose behalf" are
#    indistinguishable in the chain.
prev = ""
for e in data.get("audit_chain", []):
    version = e.get("schema_version", 2)
    fields = [
        f"v{version}", prev, str(e["sequence_number"]), e["action"],
        e["actor_token"],
    ]
    if version >= 3:
        fields += [e.get("representative_token", ""), e.get("representation_kind", "")]
    fields += [
        unicodedata.normalize("NFC", e["option_title"]),
        e["accepted"], e["preferred"], e["metadata"],
        e["created_at"],
    ]
    computed = hashlib.sha256("|".join(fields).encode()).hexdigest()
    if computed != e["entry_hash"]:
        print(f"FAIL: entry #{e['sequence_number']} hash mismatch")
        ok = False
    if e["previous_hash"] != prev:
        print(f"FAIL: entry #{e['sequence_number']} broken chain link")
        ok = False
    prev = e["entry_hash"]

# 1b. Verify the actor token binding when identity is present.
#     If actor_id and actor_token_salt are populated, the recomputed token
#     must match the stored token — this proves the identity hasn't been
#     swapped without also forging the token.
#     If either has been scrubbed (NULL), the binding is unverifiable. Two
#     legitimate cases produce this state:
#       - PII scrub on account closure (binding becomes unattributable by design)
#       - Cross-instance import (metadata.imported=true; binding can't validate
#         against remapped target IDs, but the entry isn't tampered)
#     Anything else with mismatching binding is a real failure.
decision_id = data.get("decision", {}).get("id", "")
for e in data.get("audit_chain", []):
    if not e.get("actor_token"):
        continue  # system entries (no actor) — nothing to bind
    actor_id = e.get("actor_id", "")
    salt = e.get("actor_token_salt", "")
    if not actor_id or not salt:
        # Skip: either PII scrubbed (account closure) or imported (cross-instance).
        # Both are intentional states; binding is not expected to validate.
        continue
    expected_token = hashlib.sha256(
        f"{decision_id}|{actor_id}|{e.get('actor_handle', '')}|{salt}".encode()
    ).hexdigest()
    if expected_token != e["actor_token"]:
        print(f"FAIL: entry #{e['sequence_number']} actor binding mismatch (token doesn't derive from stored identity)")
        ok = False

# 1c. Verify the representative token binding (v3 represented actions).
#     Same derivation and same scrub/import caveats as the actor binding,
#     applied to the user who performed the action on the actor's behalf.
for e in data.get("audit_chain", []):
    if not e.get("representative_token"):
        continue  # direct action or pre-v3 entry — nothing to bind
    rep_id = e.get("representative_id", "")
    rep_salt = e.get("representative_token_salt", "")
    if not rep_id or not rep_salt:
        continue  # PII scrubbed or imported; binding is not expected to validate
    expected_token = hashlib.sha256(
        f"{decision_id}|{rep_id}|{e.get('representative_handle', '')}|{rep_salt}".encode()
    ).hexdigest()
    if expected_token != e["representative_token"]:
        print(f"FAIL: entry #{e['sequence_number']} representative binding mismatch (token doesn't derive from stored identity)")
        ok = False

# The decision stores the final chain hash — verify it matches the last entry
chain_hash = data.get("decision", {}).get("audit_chain_hash")
if chain_hash and chain_hash != prev:
    print("FAIL: final chain hash mismatch")
    ok = False

# 2. Replay votes from the audit chain and verify totals match results.
#    Each vote_cast/vote_updated entry records a single voter's choice on one option.
#    We replay all votes to independently compute the acceptance and preference counts,
#    then compare against the results the server is showing.
#    Votes are deduped by actor_token so the count stays correct even if the
#    voter's PII has since been scrubbed (actor_id may be NULL post-scrub).
votes = {}
for e in data.get("audit_chain", []):
    if e["action"] in ("vote_cast", "vote_updated"):
        votes[(e.get("actor_token"), e["option_title"])] = (e["accepted"], e["preferred"])

if len(votes) > 0:
    # Sum up totals per option
    totals = {}
    for (actor, option), (accepted, preferred) in votes.items():
        if option not in totals:
            totals[option] = [0, 0]
        totals[option][0] += int(accepted)
        totals[option][1] += int(preferred)

    for r in data.get("results", []):
        title = r["option_title"]
        expected_accepted, expected_preferred = totals.get(title, [0, 0])
        if r["accepted_yes"] != expected_accepted:
            print(f"FAIL: '{title}' acceptance count is {r['accepted_yes']}, audit chain shows {expected_accepted}")
            ok = False
        if r["preferred"] != expected_preferred:
            print(f"FAIL: '{title}' preference count is {r['preferred']}, audit chain shows {expected_preferred}")
            ok = False

# 3. Fetch beacon from drand and verify sort keys
#    The beacon round is derived from the decision deadline — we don't trust the
#    server's claimed round number. We fetch the randomness value directly from
#    drand and use it to recompute every sort key.
beacon = data.get("beacon")
if beacon:
    # Derive the expected round from the deadline (first round after deadline)
    deadline_str = data["decision"]["deadline"]
    deadline_unix = int(datetime.fromisoformat(deadline_str).replace(tzinfo=timezone.utc).timestamp())
    expected_round = math.floor((deadline_unix - DRAND_GENESIS_TIME) / DRAND_PERIOD) + 2

    if beacon["round"] != expected_round:
        print(f"FAIL: server claims round {beacon['round']}, deadline implies round {expected_round}")
        ok = False

    # Fetch the beacon value directly from drand (not from the server)
    drand_url = f"{DRAND_BASE_URL}/{DRAND_CHAIN_HASH}/public/{expected_round}"
    drand = json.loads(urllib.request.urlopen(drand_url).read())
    randomness = drand["randomness"]

    if randomness != beacon["randomness"]:
        print(f"FAIL: beacon randomness does not match drand")
        print(f"  server says: {beacon['randomness']}")
        print(f"  drand says:  {randomness}")
        ok = False

    # Recompute each sort key from the drand-fetched randomness
    for r in data.get("results", []):
        computed = hashlib.sha256(
            (randomness + unicodedata.normalize("NFC", r["option_title"])).encode()
        ).hexdigest()
        if computed != r.get("lottery_sort_key"):
            print(f"FAIL: sort key mismatch for '{r['option_title']}'")
            ok = False

print("All checks passed." if ok else "VERIFICATION FAILED.")
sys.exit(0 if ok else 1)

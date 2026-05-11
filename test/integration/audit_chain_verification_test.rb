# typed: false

require "test_helper"

# Cross-language verification and integrity tests for the audit chain.
# These tests ensure:
# 1. The Python verification script correctly validates all 9 event types
# 2. DB triggers enforce immutability and vote-after-close protection
# 3. The JSON endpoint returns complete, correctly structured data
class AuditChainVerificationTest < ActionDispatch::IntegrationTest

  # Helper to run the Python verification script against JSON data.
  # Patches urllib to return a mock drand response instead of hitting the real API.
  def run_python_verifier(json_data, expected_round:, randomness:)
    Dir.mktmpdir do |dir|
      drand_path = File.join(dir, "drand_response.json")
      File.write(drand_path, JSON.generate({ round: expected_round, randomness: randomness }))

      json_path = File.join(dir, "verify.json")
      File.write(json_path, JSON.generate(json_data))

      wrapper_path = File.join(dir, "verify_wrapper.py")
      File.write(wrapper_path, <<~PYTHON)
        import unittest.mock, json, sys, io
        sys.argv = ["verify.py", #{json_path.inspect}]
        mock_response = io.BytesIO(open(#{drand_path.inspect}, "rb").read())
        with unittest.mock.patch("urllib.request.urlopen", return_value=mock_response):
            exec(open(#{Rails.root.join('scripts', 'verify-audit-chain.py').to_s.inspect}).read())
      PYTHON

      output = `python3 #{wrapper_path} 2>&1`
      exit_code = $?.exitstatus
      { output: output, exit_code: exit_code }
    end
  end

  # Compute the expected drand round from a deadline
  def expected_round_for(deadline)
    ((deadline.to_i - 1_692_803_367) / 3) + 2
  end

  # === Cross-language verification: all 9 event types ===

  test "Python script verifies all 9 event types in a complete lifecycle" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # 1. decision_created
    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "All Events Test?", description: "Testing all 9 event types",
      deadline: 1.week.from_now, options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant

    # 2. option_added (x3)
    option_a = Option.new(decision: decision, decision_participant: participant, title: "Alpha")
    DecisionActionService.add_option!(decision: decision, option: option_a, actor: user)
    option_b = Option.new(decision: decision, decision_participant: participant, title: "Beta")
    DecisionActionService.add_option!(decision: decision, option: option_b, actor: user)
    option_c = Option.new(decision: decision, decision_participant: participant, title: "Gamma")
    DecisionActionService.add_option!(decision: decision, option: option_c, actor: user)

    # 3. option_updated
    option_c.title = "Gamma (revised)"
    DecisionActionService.update_option!(option: option_c, actor: user)

    # 4. option_removed
    DecisionActionService.remove_option!(decision: decision, option: option_c, actor: user)

    # 5. decision_updated
    decision.description = "Updated description"
    DecisionActionService.update_decision!(decision: decision, actor: user)

    # 6. vote_cast (x2)
    vote_a = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option_a, decision_participant: participant,
      accepted: 1, preferred: 1,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: user)

    vote_b = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option_b, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_b, actor: user)

    # 7. vote_updated
    vote_a.accepted = 0
    vote_a.preferred = 0
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: user, is_update: true)

    # 8. decision_closed
    DecisionActionService.close_decision!(decision: decision, actor: user)

    # 9. beacon_drawn
    randomness = "deadbeef1234567890abcdef"
    round = expected_round_for(decision.deadline)
    DecisionActionService.draw_beacon!(decision: decision, round: round, randomness: randomness)

    # Verify all 9 action types are present in the chain
    actions = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).pluck(:action)
    assert_includes actions, "decision_created"
    assert_includes actions, "decision_updated"
    assert_includes actions, "option_added"
    assert_includes actions, "option_removed"
    assert_includes actions, "option_updated"
    assert_includes actions, "vote_cast"
    assert_includes actions, "vote_updated"
    assert_includes actions, "decision_closed"
    assert_includes actions, "beacon_drawn"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Fetch verify.json and run the Python script
    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json_data = JSON.parse(response.body)
    result = run_python_verifier(json_data, expected_round: round, randomness: randomness)

    assert_equal 0, result[:exit_code], "Python verification failed:\n#{result[:output]}"
    assert_match(/All checks passed/, result[:output])
    assert_no_match(/FAIL/, result[:output])
  end

  test "Python script verifies executive decision with selection" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Executive Test?", description: "Testing executive selection",
      deadline: 1.week.from_now, options_open: true, subtype: "executive",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "The Only Option")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    # Cast selection votes through the audit chain (same as regular votes)
    vote = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)

    actions = DecisionAuditEntry.where(decision_id: decision.id).pluck(:action)
    assert_includes actions, "decision_created"
    assert_includes actions, "option_added"
    assert_includes actions, "vote_cast"
    assert_includes actions, "decision_closed"
    assert_not_includes actions, "executive_selection"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Executive decisions have no beacon but should have results
    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json_data = JSON.parse(response.body)
    assert_nil json_data["beacon"], "Executive decisions should not have beacon data"
    assert json_data["results"].is_a?(Array), "Executive decisions should have results after close"
    assert json_data["results"].length == 1
    assert_equal "The Only Option", json_data["results"].first["option_title"]

    Dir.mktmpdir do |dir|
      json_path = File.join(dir, "verify.json")
      File.write(json_path, JSON.generate(json_data))

      # No drand mock needed — executive decisions have no beacon
      script_path = Rails.root.join("scripts", "verify-audit-chain.py")
      output = `python3 #{script_path} #{json_path} 2>&1`
      exit_code = $?.exitstatus

      assert_equal 0, exit_code, "Python verification failed:\n#{output}"
      assert_match(/All checks passed/, output)
    end
  end

  test "Python script verifies lottery decision with beacon" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Lottery Test?", description: "Testing lottery verification",
      deadline: 1.week.from_now, options_open: true, subtype: "lottery",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    entry_a = Option.new(decision: decision, decision_participant: participant, title: "Entry A")
    DecisionActionService.add_option!(decision: decision, option: entry_a, actor: user)
    entry_b = Option.new(decision: decision, decision_participant: participant, title: "Entry B")
    DecisionActionService.add_option!(decision: decision, option: entry_b, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)

    randomness = "lottery_randomness_hex_value_1234"
    round = expected_round_for(decision.deadline)
    DecisionActionService.draw_beacon!(decision: decision, round: round, randomness: randomness)

    actions = DecisionAuditEntry.where(decision_id: decision.id).pluck(:action)
    assert_includes actions, "decision_created"
    assert_includes actions, "option_added"
    assert_includes actions, "decision_closed"
    assert_includes actions, "beacon_drawn"
    # Lotteries have no votes
    assert_not_includes actions, "vote_cast"

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json_data = JSON.parse(response.body)

    # Lottery results should have sort keys but 0 votes
    assert json_data["results"].is_a?(Array)
    assert json_data["results"].length == 2
    json_data["results"].each do |r|
      assert_equal 0, r["accepted_yes"]
      assert_equal 0, r["preferred"]
      assert r["lottery_sort_key"].present?
    end

    result = run_python_verifier(json_data, expected_round: round, randomness: randomness)

    assert_equal 0, result[:exit_code], "Python verification failed for lottery:\n#{result[:output]}"
    assert_match(/All checks passed/, result[:output])
    assert_no_match(/FAIL/, result[:output])
  end

  # === DB trigger tests ===

  test "DB trigger prevents UPDATE on audit entries" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Trigger Test?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    entry = DecisionAuditEntry.where(decision_id: decision.id).first

    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql(
          ["UPDATE decision_audit_entries SET entry_hash = 'tampered' WHERE id = ?", entry.id]
        )
      )
    end

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "DB trigger allows DELETE on audit entries (for data deletion)" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Delete Trigger Test?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    entry_count = DecisionAuditEntry.where(decision_id: decision.id).count
    assert entry_count > 0

    # DELETE should succeed (trigger only blocks UPDATE)
    DecisionAuditEntry.where(decision_id: decision.id).delete_all
    assert_equal 0, DecisionAuditEntry.where(decision_id: decision.id).count

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "DB trigger prevents vote INSERT after decision closes" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Vote After Close Test?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Option")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)
    # Ensure the deadline is clearly in the past so the trigger fires
    decision.update_columns(deadline: 1.minute.ago)
    assert decision.closed?

    # Attempting to insert a vote after close should fail at DB level
    assert_raises(ActiveRecord::StatementInvalid) do
      Vote.create!(
        tenant: tenant, collective: collective, decision: decision,
        option: option, decision_participant: participant,
        accepted: 1, preferred: 0,
      )
    end

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "DB trigger prevents vote UPDATE after decision closes" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Vote Update After Close?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Option")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    vote = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)
    decision.update_columns(deadline: 1.minute.ago)

    # Attempting to update a vote after close should fail at DB level
    assert_raises(ActiveRecord::StatementInvalid) do
      vote.update!(accepted: 0)
    end

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "DB trigger allows vote DELETE after decision closes (for data deletion)" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Vote Delete After Close?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Option")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    vote = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)

    # DELETE should succeed (trigger only blocks INSERT/UPDATE)
    Vote.where(decision_id: decision.id).delete_all
    assert_equal 0, Vote.where(decision_id: decision.id).count

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === JSON endpoint tests ===

  test "verify.json contains all audit chain fields with correct types" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "JSON Schema Test?", description: "desc", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Opt")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    vote = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)
    DecisionActionService.close_decision!(decision: decision, actor: user)

    round = expected_round_for(decision.deadline)
    DecisionActionService.draw_beacon!(decision: decision, round: round, randomness: "abc123")

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json = JSON.parse(response.body)

    # Timestamp
    assert json["generated_at"].is_a?(String)
    assert_match(/\d{4}-\d{2}-\d{2}T/, json["generated_at"])

    # Decision section
    d = json["decision"]
    assert d.is_a?(Hash)
    assert_equal decision.id, d["id"]
    assert_equal "JSON Schema Test?", d["question"]
    assert_equal "vote", d["subtype"]
    assert d["deadline"].is_a?(String)
    assert_match(/\d{4}-\d{2}-\d{2}T/, d["deadline"])
    assert_equal round, d["lottery_beacon_round"]
    assert_equal "abc123", d["lottery_beacon_randomness"]
    assert d["audit_chain_hash"].is_a?(String)
    assert_equal 64, d["audit_chain_hash"].length

    # Beacon section
    b = json["beacon"]
    assert b.is_a?(Hash)
    assert_equal round, b["round"]
    assert_equal "abc123", b["randomness"]
    assert b["verification_url"].is_a?(String)

    # Audit chain
    chain = json["audit_chain"]
    assert chain.is_a?(Array)
    assert chain.length >= 5 # created + option_added + vote_cast + closed + beacon

    # Verify every entry has all required fields as strings (hash-ready)
    chain.each_with_index do |entry, i|
      assert entry["sequence_number"].is_a?(Integer), "entry #{i}: sequence_number should be integer"
      assert entry["schema_version"].is_a?(Integer), "entry #{i}: schema_version should be integer"
      assert_equal 2, entry["schema_version"], "entry #{i}: schema_version should be 2 for new entries"
      assert entry["action"].is_a?(String), "entry #{i}: action should be string"
      assert entry["actor_id"].is_a?(String), "entry #{i}: actor_id should be string"
      assert entry["actor_handle"].is_a?(String), "entry #{i}: actor_handle should be string"
      assert entry["actor_token"].is_a?(String), "entry #{i}: actor_token should be string"
      assert entry["actor_token_salt"].is_a?(String), "entry #{i}: actor_token_salt should be string"
      assert entry["option_title"].is_a?(String), "entry #{i}: option_title should be string"
      assert entry["accepted"].is_a?(String), "entry #{i}: accepted should be string"
      assert entry["preferred"].is_a?(String), "entry #{i}: preferred should be string"
      assert entry["metadata"].is_a?(String), "entry #{i}: metadata should be string"
      assert entry["previous_hash"].is_a?(String), "entry #{i}: previous_hash should be string"
      assert entry["entry_hash"].is_a?(String), "entry #{i}: entry_hash should be string"
      assert_equal 64, entry["entry_hash"].length, "entry #{i}: entry_hash should be 64-char hex"
      assert entry["created_at"].is_a?(String), "entry #{i}: created_at should be string"
      assert_match(/\d{4}-\d{2}-\d{2}T/, entry["created_at"], "entry #{i}: created_at should be ISO8601")

      # Entries with an actor must have a derived token + 64-hex salt; entries
      # without (e.g., beacon_drawn) must have empty strings for both.
      if entry["actor_id"].empty?
        assert_equal "", entry["actor_token"], "entry #{i}: system entry must have empty actor_token"
        assert_equal "", entry["actor_token_salt"], "entry #{i}: system entry must have empty actor_token_salt"
      else
        assert_equal 64, entry["actor_token"].length, "entry #{i}: actor_token should be 64-char hex"
        assert_match(/\A[0-9a-f]{64}\z/, entry["actor_token"], "entry #{i}: actor_token should be hex")
        assert_equal 64, entry["actor_token_salt"].length, "entry #{i}: actor_token_salt should be 64-char hex"
        assert_match(/\A[0-9a-f]{64}\z/, entry["actor_token_salt"], "entry #{i}: actor_token_salt should be hex")
      end
    end

    # Verify chain linking in JSON
    chain.each_with_index do |entry, i|
      if i == 0
        assert_equal "", entry["previous_hash"], "first entry should have empty previous_hash"
      else
        assert_equal chain[i - 1]["entry_hash"], entry["previous_hash"],
          "entry #{i}: previous_hash should match prior entry's hash"
      end
    end

    # Results section
    results = json["results"]
    assert results.is_a?(Array)
    results.each do |r|
      assert r["option_title"].is_a?(String)
      assert r["accepted_yes"].is_a?(Integer)
      assert r["preferred"].is_a?(Integer)
      assert r["lottery_sort_key"].is_a?(String)
      assert_equal 64, r["lottery_sort_key"].length
    end
  end

  test "Python script verifies open decision with votes (pre-close)" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Open Decision?", description: "Still accepting votes",
      deadline: 1.week.from_now, options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Alpha")
    DecisionActionService.add_option!(decision: decision, option: option, actor: user)

    vote = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 1,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)

    assert_not decision.closed?

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json_data = JSON.parse(response.body)

    # Pre-close: no beacon, but results are included (votes exist)
    assert_nil json_data["beacon"]
    assert json_data["results"].is_a?(Array)
    assert json_data["results"].length >= 1
    assert json_data["audit_chain"].length >= 3  # created + option_added + vote_cast

    Dir.mktmpdir do |dir|
      json_path = File.join(dir, "verify.json")
      File.write(json_path, JSON.generate(json_data))

      script_path = Rails.root.join("scripts", "verify-audit-chain.py")
      output = `python3 #{script_path} #{json_path} 2>&1`
      exit_code = $?.exitstatus

      assert_equal 0, exit_code, "Python verification failed for open decision:\n#{output}"
      assert_match(/All checks passed/, output)
    end
  end

  # === Cross-implementation consistency ===

  test "Ruby verifier agrees with Python on complete lifecycle" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Cross-impl Test?", description: "Testing Ruby and Python agree",
      deadline: 1.week.from_now, options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option_a = Option.new(decision: decision, decision_participant: participant, title: "Alpha")
    DecisionActionService.add_option!(decision: decision, option: option_a, actor: user)
    option_b = Option.new(decision: decision, decision_participant: participant, title: "Beta")
    DecisionActionService.add_option!(decision: decision, option: option_b, actor: user)

    vote_a = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option_a, decision_participant: participant,
      accepted: 1, preferred: 1,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: user)

    vote_b = Vote.new(
      tenant: tenant, collective: collective, decision: decision,
      option: option_b, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_b, actor: user)

    DecisionActionService.close_decision!(decision: decision, actor: user)

    randomness = "crossimpl_test_randomness_value"
    round = expected_round_for(decision.deadline)
    DecisionActionService.draw_beacon!(decision: decision, round: round, randomness: randomness)

    # Ruby verifier
    ruby_result = DecisionAuditVerifier.verify_all(decision, fetched_randomness: randomness)
    assert ruby_result[:valid], "Ruby verifier failed: #{ruby_result.inspect}"
    assert ruby_result[:chain][:valid]
    assert ruby_result[:vote_tallies][:valid]
    assert ruby_result[:beacon][:valid]

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Python verifier (same data via JSON endpoint)
    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success
    json_data = JSON.parse(response.body)

    python_result = run_python_verifier(json_data, expected_round: round, randomness: randomness)
    assert_equal 0, python_result[:exit_code], "Python verification failed:\n#{python_result[:output]}"
    assert_match(/All checks passed/, python_result[:output])
  end

  test "verify.json omits beacon and results before decision closes" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = Decision.new(
      tenant: tenant, collective: collective, created_by: user,
      question: "Pre-close JSON?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: user)

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json = JSON.parse(response.body)
    assert json["audit_chain"].is_a?(Array)
    assert json["audit_chain"].length >= 1
    assert_nil json["beacon"]
    assert_nil json["results"]
  end
end

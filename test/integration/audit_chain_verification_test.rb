# typed: false

require "test_helper"

# Cross-language verification test.
# Creates a decision with votes, closes it, draws the beacon, then
# runs the Python verification script against the verify.json output.
# This ensures the documented hash formula matches the Ruby implementation.
class AuditChainVerificationTest < ActionDispatch::IntegrationTest
  test "Python verification script passes for a complete decision lifecycle" do
    tenant = @global_tenant
    collective = @global_collective
    user = @global_user

    sign_in_as(user, tenant: tenant)

    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create decision with options
    decision = Decision.create!(
      tenant: tenant, collective: collective, created_by: user,
      question: "Python Verify Test?", description: "Testing cross-language verification",
      deadline: 1.week.from_now, options_open: true,
    )
    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    option_a = Option.create!(decision: decision, decision_participant: participant, title: "Alpha")
    option_b = Option.create!(decision: decision, decision_participant: participant, title: "Beta")

    # Cast votes
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

    # Update a vote
    vote_a.accepted = 0
    vote_a.preferred = 0
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: user, is_update: true)

    # Close the decision
    DecisionActionService.close_decision!(decision: decision, actor: user)

    # Compute the correct drand round from the deadline (same formula the script uses)
    deadline_unix = decision.deadline.to_i
    genesis_time = 1_692_803_367
    period = 3
    expected_round = ((deadline_unix - genesis_time) / period) + 2
    randomness = "deadbeef1234567890abcdef"

    # Draw beacon with the correct round
    DecisionActionService.draw_beacon!(
      decision: decision, round: expected_round, randomness: randomness,
    )

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Fetch the verify.json
    get "/collectives/#{collective.handle}/d/#{decision.truncated_id}/verify.json"
    assert_response :success

    json_data = JSON.parse(response.body)

    Dir.mktmpdir do |dir|
      # Write mock drand response at the URL the script will compute
      # (the script hardcodes the drand base URL but we override it via env for testing)
      drand_path = File.join(dir, "drand_response.json")
      File.write(drand_path, JSON.generate({ round: expected_round, randomness: randomness }))

      json_path = File.join(dir, "verify.json")
      File.write(json_path, JSON.generate(json_data))

      # Write a thin wrapper that patches urllib to return our mock drand response
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

      assert_equal 0, exit_code, "Python verification failed:\n#{output}"
      assert_match(/All checks passed/, output)
      assert_no_match(/FAIL/, output)
    end
  end
end

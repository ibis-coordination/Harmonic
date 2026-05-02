# typed: false

require "test_helper"

class DeadlineEventJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
  end

  def create_decision(deadline:, subtype: "vote")
    Decision.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      question: "Test?", description: "",
      deadline: deadline,
      subtype: subtype
    )
  end

  def create_commitment(deadline:)
    Commitment.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      title: "Test commitment", description: "",
      deadline: deadline,
      critical_mass: 1
    )
  end

  # === Decision deadline events ===

  test "fires decision.deadline_reached for past-deadline decisions" do
    decision = create_decision(deadline: 1.minute.ago)
    original_updated_at = decision.updated_at

    Collective.clear_thread_scope

    travel 1.minute do
      DeadlineEventJob.perform_now
    end

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.where(event_type: "decision.deadline_reached").last
    assert_not_nil event
    assert_equal decision.id, event.subject_id
    assert_equal "Decision", event.subject_type

    decision.reload
    assert_not_nil decision.deadline_event_fired_at
    assert_equal original_updated_at, decision.updated_at
  end

  test "does not fire for decisions with future deadlines" do
    create_decision(deadline: 1.hour.from_now)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "decision.deadline_reached").count
  end

  test "does not fire twice for the same decision" do
    decision = create_decision(deadline: 1.minute.ago)
    decision.update!(deadline_event_fired_at: Time.current)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "decision.deadline_reached").count
  end

  # === Commitment deadline events ===

  test "fires commitment.deadline_reached for past-deadline commitments" do
    commitment = create_commitment(deadline: 1.minute.ago)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.where(event_type: "commitment.deadline_reached").last
    assert_not_nil event
    assert_equal commitment.id, event.subject_id
    assert_equal "Commitment", event.subject_type

    commitment.reload
    assert_not_nil commitment.deadline_event_fired_at
  end

  test "does not fire for commitments with future deadlines" do
    create_commitment(deadline: 1.hour.from_now)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "commitment.deadline_reached").count
  end

  test "does not fire twice for the same commitment" do
    commitment = create_commitment(deadline: 1.minute.ago)
    commitment.update!(deadline_event_fired_at: Time.current)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "commitment.deadline_reached").count
  end

  # === Lottery integration ===

  test "enqueues LotteryDrawJob for lottery decisions" do
    decision = create_decision(deadline: 1.minute.ago, subtype: "lottery")

    Collective.clear_thread_scope

    assert_enqueued_with(job: LotteryDrawJob, args: [decision.id]) do
      DeadlineEventJob.perform_now
    end
  end

  test "does not enqueue LotteryDrawJob for vote decisions" do
    create_decision(deadline: 1.minute.ago, subtype: "vote")

    Collective.clear_thread_scope

    assert_no_enqueued_jobs(only: LotteryDrawJob) do
      DeadlineEventJob.perform_now
    end
  end

  # === Cross-tenant ===

  test "processes decisions and commitments across multiple tenants" do
    # Create a decision in the first tenant
    create_decision(deadline: 1.minute.ago)

    # Create a second tenant with its own decision
    other_tenant = create_tenant(subdomain: "tenant2", name: "Tenant 2")
    other_user = create_user(name: "User 2")
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, name: "Collective 2", handle: "collective2")
    other_collective.add_user!(other_user)

    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    Tenant.current_id = other_tenant.id

    Decision.create!(
      tenant: other_tenant, collective: other_collective,
      created_by: other_user, updated_by: other_user,
      question: "Tenant 2 decision?", description: "",
      deadline: 1.minute.ago,
      subtype: "vote"
    )

    Collective.clear_thread_scope
    Tenant.current_id = nil

    DeadlineEventJob.perform_now

    # Should fire deadline events for both tenants
    deadline_events = Event.unscoped_for_system_job.where(event_type: "decision.deadline_reached")
    assert_equal 2, deadline_events.count
  end

  # === Event metadata ===

  test "includes resource metadata in decision event" do
    decision = create_decision(deadline: 1.minute.ago)

    Collective.clear_thread_scope
    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.where(event_type: "decision.deadline_reached").last
    assert_not_nil event
    assert_equal "decision", event.metadata["resource_type"]
    assert_equal decision.id, event.metadata["resource_id"]
    assert_equal "Test?", event.metadata["question"]
    assert_equal "vote", event.metadata["subtype"]
    assert_not_nil event.metadata["deadline"]
  end

  test "includes resource metadata in commitment event" do
    commitment = create_commitment(deadline: 1.minute.ago)

    Collective.clear_thread_scope
    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.where(event_type: "commitment.deadline_reached").last
    assert_not_nil event
    assert_equal "commitment", event.metadata["resource_type"]
    assert_equal commitment.id, event.metadata["resource_id"]
    assert_equal "Test commitment", event.metadata["title"]
    assert_not_nil event.metadata["deadline"]
  end

  # === Soft-deleted items ===

  test "does not fire for soft-deleted decisions" do
    decision = create_decision(deadline: 1.minute.ago)
    decision.update!(deleted_at: Time.current)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "decision.deadline_reached").count
  end

  test "does not fire for soft-deleted commitments" do
    commitment = create_commitment(deadline: 1.minute.ago)
    commitment.update!(deleted_at: Time.current)

    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert_equal 0, Event.where(event_type: "commitment.deadline_reached").count
  end

  # === Error isolation ===

  test "continues processing after a single record fails" do
    create_decision(deadline: 3.minutes.ago) # this one will fail
    good_decision = create_decision(deadline: 2.minutes.ago)

    Collective.clear_thread_scope

    call_count = 0
    original_record = EventService.method(:record!)
    EventService.stub(:record!, lambda { |**kwargs|
      call_count += 1
      raise "simulated failure" if call_count == 1

      original_record.call(**kwargs)
    }) do
      DeadlineEventJob.perform_now
    end

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # The good decision (processed second) should still have its event fired
    good_decision.reload
    assert_not_nil good_decision.deadline_event_fired_at
  end
end

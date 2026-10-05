# frozen_string_literal: true

require "test_helper"

class AiAgentCreationServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @tenant.set_feature_flag!("external_ai_agents", true)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  teardown do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def enable_stripe_billing_flag!(tenant)
    tenant.enable_feature_flag!("stripe_billing")
  end

  def create_with(params, billing_confirmed: false, responsibility_confirmed: true, principal: @user)
    helper = ApiHelper.new(
      current_user: principal,
      current_collective: @collective,
      current_tenant: @tenant,
      params: ActionController::Parameters.new(params)
    )
    AiAgentCreationService.call(api_helper: helper, billing_confirmed: billing_confirmed,
                                responsibility_confirmed: responsibility_confirmed)
  end

  test "creates an agent whose principal is the api helper's user" do
    result = create_with({ name: "Service Agent", mode: "external" })

    assert result.created?
    assert_equal :created, result.status
    assert_equal @user.id, result.ai_agent.parent_id
    assert result.ai_agent.external_ai_agent?
    assert_in_delta Time.current, result.ai_agent.principal_responsibility_confirmed_at, 5.seconds
    assert_not result.ai_agent.pending_billing_setup?
    assert_nil result.charged_cents
  end

  test "reports responsibility_confirmation_required and creates nothing until the principal confirms" do
    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      result = create_with({ name: "Unowned Agent", mode: "external" }, responsibility_confirmed: false)
      assert_equal :responsibility_confirmation_required, result.status
    end
  end

  test "admins confirm responsibility like everyone else" do
    @user.update!(app_admin: true)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      result = create_with({ name: "Admin Agent", mode: "external" }, responsibility_confirmed: false)
      assert_equal :responsibility_confirmation_required, result.status
    end
  ensure
    @user.update!(app_admin: false)
  end

  test "reports billing_setup_required and creates nothing when the principal has no billing" do
    enable_stripe_billing_flag!(@tenant)
    # An existing agent on the tenant makes the principal's billable quantity
    # non-zero, so billing setup is required before creating another.
    existing = create_ai_agent(parent: @user, name: "Existing Billable Agent")
    @tenant.add_user!(existing)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      result = create_with({ name: "Blocked Agent", mode: "external" }, billing_confirmed: true)
      assert_equal :billing_setup_required, result.status
      assert_not result.created?
      assert_nil result.ai_agent
    end
  end

  test "reports billing_confirmation_required when billing is on and the charge is unconfirmed" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      result = create_with({ name: "Unconfirmed Agent", mode: "external" }, billing_confirmed: false)
      assert_equal :billing_confirmation_required, result.status
    end
  end

  test "admins are exempt from billing confirmation" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)

    result = create_with({ name: "Admin Agent", mode: "external" }, billing_confirmed: false)

    assert result.created?
    assert_not result.ai_agent.pending_billing_setup?
  end

  test "assigns the principal's stripe customer and reports the prorated charge" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sync = Struct.new(:success, :charged_cents).new(true, 150)

    StripeService.stub(:sync_subscription_quantity!, sync) do
      result = create_with({ name: "Charged Agent", mode: "external" }, billing_confirmed: true)

      assert result.created?
      assert_equal sc.id, result.ai_agent.stripe_customer_id
      assert_equal 150, result.charged_cents
      assert_not result.ai_agent.pending_billing_setup?
    end
  end

  test "parks the agent when the subscription sync fails" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sync = Struct.new(:success, :charged_cents).new(false, nil)

    StripeService.stub(:sync_subscription_quantity!, sync) do
      result = create_with({ name: "Parked Agent", mode: "external" }, billing_confirmed: true)

      assert result.created?
      assert result.ai_agent.pending_billing_setup?
    end
  end

  test "a taken handle leaves nothing behind even inside a caller's transaction" do
    create_with({ name: "First", mode: "external", handle: "taken-handle" })

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      ActiveRecord::Base.transaction do
        result = create_with({ name: "Second", mode: "external", handle: "taken-handle" })
        assert_equal :handle_taken, result.status
      end
    end
  end

  test "reports handle_taken for an explicit handle that is already in use" do
    create_with({ name: "First", mode: "external", handle: "taken-handle" })

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      result = create_with({ name: "Second", mode: "external", handle: "taken-handle" })
      assert_equal :handle_taken, result.status
    end
  end
end

# typed: false

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "unauthenticated user is redirected to login" do
    get "/"
    assert_response :redirect
  end

  test "authenticated user sees homepage" do
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_response :success
  end

  test "homepage displays feed items from main collective" do
    sign_in_as(@user, tenant: @tenant)

    # Create a note in the main collective
    main_collective = Collective.find(@tenant.main_collective_id)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main_collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: main_collective,
      created_by: @user,
      text: "A public note visible on the homepage",
      deadline: Time.current + 1.week,
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    assert_includes response.body, "A public note visible on the homepage"
    assert_includes response.body, "pulse-feed-item"
  end

  test "homepage does not display feed items from non-main collectives" do
    sign_in_as(@user, tenant: @tenant)

    # Create a note in a regular collective (not the main one)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "A private note only for collective members",
      deadline: Time.current + 1.week,
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/"
    assert_response :success
    assert_not_includes response.body, "A private note only for collective members"
  end
end

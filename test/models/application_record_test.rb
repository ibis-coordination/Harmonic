require "test_helper"

class ApplicationRecordTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @user = @global_user
    # Use a non-main collective for the "other" side; main collective is set
    # up in test_helper's global tenant.
    @other = create_collective(tenant: @tenant, created_by: @user)
    @other.add_user!(@user)
    @tenant.main_collective.add_user!(@user) unless @tenant.main_collective.user_is_member?(@user)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @other.handle)
  end

  test "main_collective_scope returns only main-collective records for the given tenant" do
    main = @tenant.main_collective
    other = @other

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: main.handle)
    main_note = Note.create!(
      tenant: @tenant, collective: main, created_by: @user,
      text: "in main", deadline: Time.current + 1.week,
    )

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other.handle)
    other_note = Note.create!(
      tenant: @tenant, collective: other, created_by: @user,
      text: "in other collective", deadline: Time.current + 1.week,
    )

    # Even while thread-scoped to `other`, main_collective_scope drops the
    # collective default scope and re-applies it to main only.
    ids = Note.main_collective_scope(@tenant).pluck(:id)

    assert_includes ids, main_note.id
    assert_not_includes ids, other_note.id
  end
end

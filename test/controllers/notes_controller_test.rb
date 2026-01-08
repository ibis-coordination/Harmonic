require "test_helper"

class NotesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from new note form" do
    get "/studios/#{@studio.handle}/note"
    assert_response :redirect
  end

  # === New Note Tests ===

  test "authenticated user can access new note form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/note"
    assert_response :success
  end

  # === Create Note Tests ===

  test "authenticated user can create a note" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "Note.count", 1 do
      post "/studios/#{@studio.handle}/note", params: {
        note: {
          title: "Test Note Title",
          text: "This is the note content"
        }
      }
    end

    note = Note.last
    assert_equal "Test Note Title", note.title
    assert_equal "This is the note content", note.text
    assert_equal @user, note.created_by
    assert_response :redirect
  end

  # === Show Note Tests ===

  test "authenticated user can view a note" do
    sign_in_as(@user, tenant: @tenant)

    # Create note in thread context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}"
    assert_response :success
  end

  test "returns 404 for non-existent note" do
    sign_in_as(@user, tenant: @tenant)
    # RecordNotFound is raised and caught by the controller to render 404
    # The controller has: return render '404', status: 404 unless @note
    # But the find happens before that check, so we get exception
    # In production, Rails rescues this and renders 404
    assert_raises(ActiveRecord::RecordNotFound) do
      get "/studios/#{@studio.handle}/n/nonexistent123"
    end
  end

  # === Edit Note Tests ===

  test "note creator can access edit form" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit"
    assert_response :success
  end

  test "non-creator cannot access edit form" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @studio.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,  # Created by @user
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit"
    assert_response :forbidden
  end

  # === Update Note Tests ===

  test "note creator can update note" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Original Title",
      text: "Original content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    # Update uses POST to /n/:note_id/edit
    post "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit", params: {
      note: {
        title: "Updated Title",
        text: "Updated content"
      }
    }

    note.reload
    assert_equal "Updated Title", note.title
    assert_equal "Updated content", note.text
    assert_response :redirect
  end

  test "non-creator cannot update note" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @studio.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Original Title",
      text: "Original content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    post "/studios/#{@studio.handle}/n/#{note.truncated_id}/edit", params: {
      note: {
        title: "Hacked Title"
      }
    }

    assert_response :forbidden
    note.reload
    assert_equal "Original Title", note.title
  end

  # === History Tests ===

  test "authenticated user can view note history" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
    note = Note.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Studio.clear_thread_scope
    Tenant.clear_thread_scope

    get "/studios/#{@studio.handle}/n/#{note.truncated_id}/history.html"
    assert_response :success
  end
end

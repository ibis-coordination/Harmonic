require "test_helper"

class ContentDeletionTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @other_user = create_user
    CollectiveMember.create!(tenant: @tenant, collective: @collective, user: @other_user)
    sign_in_as(@user, tenant: @tenant)
  end

  # --- Note deletion ---

  test "creator can delete their own note via settings action" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                       title: "To Delete", text: "Content")

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/settings/actions/delete_note",
         headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :redirect
    note.reload
    assert note.deleted?
    assert_equal "[deleted]", note.text
  end

  test "non-creator cannot delete note via settings action" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @other_user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/settings/actions/delete_note",
         headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :forbidden
    note.reload
    assert_not note.deleted?
  end

  test "deleted note show page renders placeholder" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                       title: "Was Here", text: "Content")
    note.soft_delete!(by: @user)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}",
        headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :success
    assert_match(/deleted/, response.body)
  end

  test "deleted note is excluded from pulse feed" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                       title: "Feed Note", text: "Visible content")
    note.soft_delete!(by: @user)

    get "/collectives/#{@collective.handle}",
        headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :success
    assert_no_match(/Feed Note/, response.body)
  end

  # --- Decision deletion ---

  test "creator can delete their own decision via settings action" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user,
                               question: "Delete me?")

    post "/collectives/#{@collective.handle}/d/#{decision.truncated_id}/settings/actions/delete_decision",
         headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :redirect
    decision.reload
    assert decision.deleted?
    assert_equal "[deleted]", decision.question
  end

  # --- Commitment deletion ---

  test "creator can delete their own commitment via settings action" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user,
                                   title: "Delete me")

    post "/collectives/#{@collective.handle}/c/#{commitment.truncated_id}/settings/actions/delete_commitment",
         headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :redirect
    commitment.reload
    assert commitment.deleted?
    assert_equal "[deleted]", commitment.title
  end

  # --- Orphaned comments (parent deleted) ---

  test "comment on deleted note still renders on its own show page" do
    parent = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Parent")
    comment = create_note(tenant: @tenant, collective: @collective, created_by: @other_user,
                          text: "A comment", commentable: parent)
    parent.soft_delete!(by: @user)

    get "/collectives/#{@collective.handle}/n/#{comment.truncated_id}",
        headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :success
    assert_match(/deleted/, response.body)
    assert_match(/A comment/, response.body)
  end

  test "pulse feed renders without error when comment parent is deleted" do
    parent = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Parent")
    create_note(tenant: @tenant, collective: @collective, created_by: @other_user,
                text: "Orphaned comment", commentable: parent)
    parent.soft_delete!(by: @user)

    get "/collectives/#{@collective.handle}",
        headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :success
  end

  # --- Comment deletion ---

  test "creator can delete their own comment" do
    parent = create_note(tenant: @tenant, collective: @collective, created_by: @other_user)
    comment = create_note(tenant: @tenant, collective: @collective, created_by: @user,
                          text: "My comment", commentable: parent)

    post "/collectives/#{@collective.handle}/n/#{comment.truncated_id}/settings/actions/delete_note",
         headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }

    assert_response :redirect
    comment.reload
    assert comment.deleted?
    assert_equal "[deleted]", comment.text
  end
end

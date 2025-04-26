require "test_helper"

class DataDeletionManagerTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
    @note = create_note(tenant: @tenant, studio: @studio, created_by: @user)
    @decision = create_decision(tenant: @tenant, studio: @studio, created_by: @user)
    @commitment = create_commitment(tenant: @tenant, studio: @studio, created_by: @user)
    @ddm = DataDeletionManager.new(user: @user)
  end

  test "DataDeletionManager does not delete anything unless correct confirmation_token is provided" do
    assert_raises { @ddm.delete_studio!(studio: @studio, confirmation_token: 'incorrect token') }
    assert_not @studio.reload.nil?
    assert_raises { @ddm.delete_note!(note: @note, confirmation_token: 'incorrect token') }
    assert_not @note.reload.nil?
    assert_raises { @ddm.delete_decision!(decision: @decision, confirmation_token: 'incorrect token') }
    assert_not @decision.reload.nil?
    assert_raises { @ddm.delete_commitment!(commitment: @commitment, confirmation_token: 'incorrect token') }
    assert_not @commitment.reload.nil?
    assert_raises { @ddm.delete_user!(user: @user, confirmation_token: 'incorrect token') }
    assert_not @user.reload.nil?
  end

  test "DataDeletionManager deletes studio with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    assert_difference -> { Studio.count }, -1 do
      @ddm.delete_studio!(studio: @studio, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes note with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    assert_difference -> { Note.count }, -1 do
      @ddm.delete_note!(note: @note, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes decision with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token

    assert_difference -> { Decision.count }, -1 do
      @ddm.delete_decision!(decision: @decision, confirmation_token: confirmation_token)
    end
  end

  test "DataDeletionManager deletes commitment with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    @commitment.join_commitment!(@user)
    assert_equal 1, CommitmentParticipant.where(commitment: @commitment).count
    assert_difference -> { Commitment.count }, -1 do
      @ddm.delete_commitment!(commitment: @commitment, confirmation_token: confirmation_token)
    end
    assert_equal 0, CommitmentParticipant.where(commitment: @commitment).count
  end

  test "DataDeletionManager deletes user PII and marks user as deleted with correct confirmation_token" do
    confirmation_token = @ddm.confirmation_token
    user_email = @user.email
    user_name = @user.name
    oauth_identity = OauthIdentity.create!(user: @user, provider: "test_provider", uid: "test_uid")
    # Profile image is attached
    @user.image.attach(
      io: File.open(Rails.root.join("public", "placeholder.png")),
      filename: "placeholder.png",
      content_type: "image/png"
    )
    assert @user.image.attached?

    assert_difference -> { OauthIdentity.count }, -1 do
      assert_no_difference -> { User.count } do
        result = @ddm.delete_user!(user: @user, confirmation_token: confirmation_token)

        # Verify user PII is removed
        @user.reload
        assert_match(/@deleted\.user$/, @user.email)
        assert_equal "Deleted User", @user.name
        assert_not @user.image.attached?

        # Verify API tokens are marked as deleted
        assert ApiToken.unscoped.where(user_id: @user.id).all? { |token| token.deleted_at.present? }

        # Verify StudioUser records are archived
        assert StudioUser.unscoped.where(user_id: @user.id).all? { |studio_user| studio_user.archived_at.present? }

        # Verify TenantUser records are updated and archived
        TenantUser.unscoped.where(user_id: @user.id).each do |tenant_user|
          assert_equal "Deleted User", tenant_user.display_name
          assert_match(/-deleted$/, tenant_user.handle)
          assert tenant_user.archived_at.present?
        end

        # Verify the result message
        assert_equal "PII for user '#{@user.id}' has been removed and the user has been marked as deleted.", result
      end
    end
  end

end

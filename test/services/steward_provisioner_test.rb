# typed: false
# frozen_string_literal: true

require "test_helper"

class StewardProvisionerTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @principal = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @tenant.enable_api!
    @principal.update!(sys_admin: true)
  end

  def teardown
    Tenant.clear_thread_scope
  end

  test "provision! creates a minimal steward agent with role, flagged read token" do
    result = StewardProvisioner.provision!(
      tenant: @tenant,
      principal_handle: @principal.tenant_user.handle,
      handle: "steward",
    )

    steward = result.steward
    assert_equal "ai_agent", steward.user_type
    assert_equal @principal.id, steward.parent_id
    assert_equal({ "mode" => "external" }, steward.agent_configuration)
    assert steward.sys_admin?
    assert_equal "steward", steward.tenant_user.handle

    token = result.token
    assert_equal "rest", token.token_type
    assert_equal ApiToken.read_scopes, token.scopes
    assert token.sys_admin?
    assert token.plaintext_token.present?
    assert_in_delta 1.year.from_now.to_i, token.expires_at.to_i, 60
  end

  test "provision! does not add the steward to any shared collective" do
    result = StewardProvisioner.provision!(
      tenant: @tenant,
      principal_handle: @principal.tenant_user.handle,
      handle: "steward",
    )
    # Every user gets an auto-created private workspace; the steward must not
    # be in anything shared (least privilege — admin pages need no membership).
    shared = result.steward.collectives.where.not(collective_type: "private_workspace")
    assert_empty shared
    assert_not @collective.users.exists?(id: result.steward.id)
  end

  test "provision! refuses when the tenant API is disabled" do
    @tenant.settings["feature_flags"] ||= {}
    @tenant.settings["feature_flags"]["api"] = false
    @tenant.save!
    error = assert_raises(StewardProvisioner::PreconditionFailed) do
      StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    end
    assert_match(/API/, error.message)
  end

  test "provision! refuses a principal without sys_admin" do
    @principal.update!(sys_admin: false)
    error = assert_raises(StewardProvisioner::PreconditionFailed) do
      StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    end
    assert_match(/sys_admin/, error.message)
  end

  test "provision! refuses a taken handle" do
    StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    assert_raises(StewardProvisioner::PreconditionFailed) do
      StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    end
  end

  test "rotate! mints a new token and revokes the previous ones" do
    first = StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    rotated = StewardProvisioner.rotate!(tenant: @tenant, handle: "steward")

    assert rotated.plaintext_token.present?
    assert_not_equal first.token.id, rotated.id
    assert first.token.reload.deleted_at.present?, "previous token should be revoked"
    assert_nil rotated.deleted_at
    assert rotated.sys_admin?
  end

  test "revoke! revokes all tokens and removes the role" do
    result = StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    StewardProvisioner.revoke!(tenant: @tenant, handle: "steward")

    assert result.token.reload.deleted_at.present?
    assert_not result.steward.reload.sys_admin?
  end

  test "rotate! and revoke! refuse an unknown handle" do
    assert_raises(StewardProvisioner::PreconditionFailed) { StewardProvisioner.rotate!(tenant: @tenant, handle: "nope") }
    assert_raises(StewardProvisioner::PreconditionFailed) { StewardProvisioner.revoke!(tenant: @tenant, handle: "nope") }
  end

  test "enable_reporting! joins the collective and mints an unflagged content token" do
    StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    token = StewardProvisioner.enable_reporting!(tenant: @tenant, handle: "steward", collective_handle: @collective.handle)

    steward = User.find_by!(name: "Steward")
    assert @collective.users.exists?(id: steward.id), "steward should join the reporting collective"
    assert_equal ["read:all", "create:all"], token.scopes
    assert_not token.sys_admin?, "report token must not carry the sys_admin flag"
    assert_equal "rest", token.token_type
    assert token.plaintext_token.present?
  end

  test "enable_reporting! is idempotent on membership and refuses unknown collective" do
    StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    StewardProvisioner.enable_reporting!(tenant: @tenant, handle: "steward", collective_handle: @collective.handle)
    StewardProvisioner.enable_reporting!(tenant: @tenant, handle: "steward", collective_handle: @collective.handle)
    steward = User.find_by!(name: "Steward")
    assert_equal 1, @collective.collective_members.where(user_id: steward.id).count

    assert_raises(StewardProvisioner::PreconditionFailed) do
      StewardProvisioner.enable_reporting!(tenant: @tenant, handle: "steward", collective_handle: "no-such-collective")
    end
  end

  test "revoke! also revokes report tokens" do
    StewardProvisioner.provision!(tenant: @tenant, principal_handle: @principal.tenant_user.handle, handle: "steward")
    report_token = StewardProvisioner.enable_reporting!(tenant: @tenant, handle: "steward", collective_handle: @collective.handle)
    StewardProvisioner.revoke!(tenant: @tenant, handle: "steward")
    assert report_token.reload.deleted_at.present?
  end
end

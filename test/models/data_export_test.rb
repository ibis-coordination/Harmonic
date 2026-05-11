# typed: false

require "test_helper"

class DataExportTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
  end

  test "defaults export_type to 'collective'" do
    export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "pending")
    assert_equal "collective", export.export_type
  end

  test "rejects unknown export_type values" do
    export = DataExport.new(tenant: @tenant, collective: @collective, user: @user, status: "pending", export_type: "bogus")
    refute export.valid?
    assert export.errors[:export_type].present?
  end

  test "accepts export_type 'user'" do
    export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "pending", export_type: "user")
    assert_equal "user", export.export_type
  end

  test "scopes filter by export_type" do
    collective_export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "pending", export_type: "collective")
    user_export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "pending", export_type: "user")

    assert_includes DataExport.collective_exports, collective_export
    refute_includes DataExport.collective_exports, user_export

    assert_includes DataExport.user_exports, user_export
    refute_includes DataExport.user_exports, collective_export
  end
end

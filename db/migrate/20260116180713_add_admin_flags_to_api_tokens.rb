class AddAdminFlagsToApiTokens < ActiveRecord::Migration[7.0]
  def change
    add_column :api_tokens, :sys_admin, :boolean, default: false, null: false
    add_column :api_tokens, :app_admin, :boolean, default: false, null: false
    add_column :api_tokens, :tenant_admin, :boolean, default: false, null: false
  end
end

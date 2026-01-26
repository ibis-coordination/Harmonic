class AddCreatedByToStudios < ActiveRecord::Migration[7.0]
  def up
    add_reference :studios, :created_by, null: true, foreign_key: { to_table: :users }, type: :uuid
    add_reference :studios, :updated_by, null: true, foreign_key: { to_table: :users }, type: :uuid
    # Skip update step if no studios exist (fresh database)
    studio_count = execute("SELECT COUNT(*) FROM studios").first["count"].to_i
    if studio_count > 0
      default_user_email = nil # Must be set to a valid email address
      raise 'Please set default_user_email to a valid email address' unless default_user_email
      default_user = execute("SELECT id FROM users WHERE email = #{connection.quote(default_user_email)}").first
      raise "User with email #{default_user_email} not found" unless default_user
      execute("UPDATE studios SET created_by_id = '#{default_user['id']}', updated_by_id = '#{default_user['id']}'")
    end
    change_column_null :studios, :created_by_id, false
    change_column_null :studios, :updated_by_id, false
  end

  def down
    remove_reference :studios, :created_by
    remove_reference :studios, :updated_by
  end
end

class AddTruncatedIdToWebhooks < ActiveRecord::Migration[7.0]
  def change
    execute <<-SQL
      ALTER TABLE webhooks
      ADD COLUMN truncated_id character varying GENERATED ALWAYS AS (left(id::text, 8)) STORED NOT NULL;
    SQL
    add_index :webhooks, :truncated_id, unique: true
  end
end

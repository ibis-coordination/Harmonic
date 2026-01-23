class AddUserIdToWebhooks < ActiveRecord::Migration[7.0]
  def change
    add_reference :webhooks, :user, type: :uuid, foreign_key: true, index: true
  end
end

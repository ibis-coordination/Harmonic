class AddClientNameToApiTokens < ActiveRecord::Migration[7.2]
  def change
    add_column :api_tokens, :client_name, :string, limit: 64
  end
end

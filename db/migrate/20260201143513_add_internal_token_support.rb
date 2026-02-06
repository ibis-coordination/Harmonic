# frozen_string_literal: true

class AddInternalTokenSupport < ActiveRecord::Migration[7.0]
  def change
    add_column :api_tokens, :internal, :boolean, default: false, null: false
    add_column :api_tokens, :internal_encrypted_token, :text, null: true
  end
end

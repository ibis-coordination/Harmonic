# frozen_string_literal: true

class AddInternalToSuperagents < ActiveRecord::Migration[7.0]
  def change
    add_column :superagents, :internal, :boolean, default: false, null: false
  end
end

class CreateOmniAuthIdentities < ActiveRecord::Migration[7.0]
  def change
    create_table :omni_auth_identities, id: :uuid do |t|
      # t.references :user, null: true, foreign_key: true, type: :uuid
      t.string :email, null: false, index: { unique: true }
      t.string :name
      t.string :password_digest

      t.timestamps
    end
  end
end

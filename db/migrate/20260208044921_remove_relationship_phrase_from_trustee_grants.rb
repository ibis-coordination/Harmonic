class RemoveRelationshipPhraseFromTrusteeGrants < ActiveRecord::Migration[7.0]
  def up
    remove_column :trustee_grants, :relationship_phrase
  end

  def down
    add_column :trustee_grants, :relationship_phrase, :string, null: false, default: "{trusted_user} on behalf of {granting_user}"
  end
end

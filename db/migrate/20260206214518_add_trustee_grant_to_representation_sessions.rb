class AddTrusteeGrantToRepresentationSessions < ActiveRecord::Migration[7.0]
  def change
    # trustee_grant_id is optional - NULL for studio representation, set for user representation
    add_reference :representation_sessions, :trustee_grant, null: true, foreign_key: true, type: :uuid
  end
end

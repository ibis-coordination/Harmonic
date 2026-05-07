class AddVoteReceiptEmailToDecisionParticipants < ActiveRecord::Migration[7.2]
  def change
    add_column :decision_participants, :vote_receipt_email, :boolean, default: false, null: false
  end
end

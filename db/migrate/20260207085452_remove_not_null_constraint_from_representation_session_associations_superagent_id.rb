class RemoveNotNullConstraintFromRepresentationSessionAssociationsSuperagentId < ActiveRecord::Migration[7.0]
  def change
    change_column_null :representation_session_associations, :superagent_id, true
  end
end

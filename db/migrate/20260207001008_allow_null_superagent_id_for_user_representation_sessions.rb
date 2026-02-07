class AllowNullSuperagentIdForUserRepresentationSessions < ActiveRecord::Migration[7.0]
  def change
    # User representation sessions (via trustee grants) don't have a superagent_id
    # because they can span multiple studios. Only studio representation sessions
    # require a superagent_id.
    change_column_null :representation_sessions, :superagent_id, true
  end
end

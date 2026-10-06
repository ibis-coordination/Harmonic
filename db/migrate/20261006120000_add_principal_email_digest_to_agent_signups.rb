# typed: true

class AddPrincipalEmailDigestToAgentSignups < ActiveRecord::Migration[7.2]
  def change
    # The addressee of a signup is whoever proves control of the named email,
    # member or not. A keyed digest supports the lookup without storing the
    # address an anonymous caller supplied. NOT NULL with no backfill: the
    # table has not shipped to production.
    add_column :agent_signups, :principal_email_digest, :string, null: false
    # The invite a signup carries so a non-member principal can join an
    # invite-only tenant from the claim link.
    add_reference :agent_signups, :invite, foreign_key: { on_delete: :nullify }, type: :uuid, index: false

    remove_index :agent_signups, [:tenant_id, :principal_user_id, :state]
    add_index :agent_signups, [:tenant_id, :principal_email_digest, :state]
  end
end

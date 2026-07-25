# Two independently declared electorates per decision: who may vote, and who
# may propose options. Each is a union of clauses (see UserSet).
#
# One jsonb column per set rather than typed columns per clause field: clause
# payloads vary in shape, the clause list is variable-length, and
# DecisionActionService.update_decision! diffs `decision.changes` — so a jsonb
# column lands in the audit chain as one coherent before/after value instead of
# several scattered column diffs.
#
# The default reproduces today's behavior exactly: anyone who already clears the
# `vote` / `add_options` action authorization.
class AddEligibilityToDecisions < ActiveRecord::Migration[7.2]
  # A Hash, not a JSON string — a String default would be serialized *as* a
  # json string value ("{\"any_of\": ...}") rather than an object.
  OPEN = { "any_of" => [{ "type" => "open" }] }.freeze

  def change
    change_table :decisions, bulk: true do |t|
      t.column :voter_eligibility, :jsonb, null: false, default: OPEN
      t.column :proposer_eligibility, :jsonb, null: false, default: OPEN
    end
  end
end

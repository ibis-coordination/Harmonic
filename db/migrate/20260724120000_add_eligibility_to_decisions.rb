# Two independently declared user sets per decision: who may vote, and who may
# propose options. Each is a union of clauses (see UserSet).
#
# One jsonb column per set rather than typed columns per clause field: clause
# payloads vary in shape, the clause list is variable-length, and
# DecisionActionService.update_decision! diffs `decision.changes` — so a jsonb
# column lands in the audit chain as one coherent before/after value instead of
# several scattered column diffs.
#
# NULL means no restriction, which is today's behavior for every existing row.
# "Everyone" is deliberately not representable as a set: it is a property of the
# call site, not a set of users, and giving it a clause would mean an
# unenumerable member of a grammar whose whole point is describing bounded sets.
class AddEligibilityToDecisions < ActiveRecord::Migration[7.2]
  def change
    change_table :decisions, bulk: true do |t|
      t.column :voter_eligibility, :jsonb
      t.column :proposer_eligibility, :jsonb
    end
  end
end

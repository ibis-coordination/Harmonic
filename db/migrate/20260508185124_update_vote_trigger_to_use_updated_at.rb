class UpdateVoteTriggerToUseUpdatedAt < ActiveRecord::Migration[7.2]
  def up
    # Change the vote immutability trigger to compare the vote's updated_at against
    # the decision deadline, instead of NOW(). This allows importing historical votes
    # on past-deadline decisions (by setting updated_at to the original timestamp),
    # while still preventing new votes/modifications after close in normal app usage
    # (Rails auto-sets updated_at to Time.current on create and update).
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_vote_mutation_after_close() RETURNS TRIGGER AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM decisions
          WHERE id = NEW.decision_id
          AND deadline < NEW.updated_at
        ) THEN
          RAISE EXCEPTION 'Votes cannot be created or modified after the decision is closed';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_vote_mutation_after_close() RETURNS TRIGGER AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM decisions
          WHERE id = NEW.decision_id
          AND deadline < NOW()
        ) THEN
          RAISE EXCEPTION 'Votes cannot be created or modified after the decision is closed';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end

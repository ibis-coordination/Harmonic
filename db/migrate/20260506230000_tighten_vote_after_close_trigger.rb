class TightenVoteAfterCloseTrigger < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_vote_mutation_after_close() RETURNS TRIGGER AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM decisions
          WHERE id = NEW.decision_id
          AND deadline <= NOW()
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

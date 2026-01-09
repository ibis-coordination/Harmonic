# typed: true

class DecisionResult < ApplicationRecord
  extend T::Sig

  self.primary_key = "option_id"
  self.table_name = "decision_results" # view

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      position: position,
      decision_id: decision_id,
      option_id: option_id,
      option_title: option_title,
      option_random_id: random_id,
      accepted_yes: accepted_yes,
      accepted_no: accepted_no,
      vote_count: vote_count,
      preferred: preferred,
    }
  end

  sig { params(other_result: DecisionResult).returns(String) }
  def get_sorting_factor(other_result)
    if self.accepted_yes != other_result.accepted_yes
      'accepted_yes'
    elsif self.preferred != other_result.preferred
      'preferred'
    else
      'random_id'
    end
  end

  sig { params(other_result: T.nilable(DecisionResult), factor: String).returns(T::Boolean) }
  def is_sorting_factor?(other_result, factor)
    return false if other_result.nil?
    get_sorting_factor(other_result) == factor
  end

  sig { params(position: Integer).void }
  def position=(position)
    @position = position
  end

  sig { returns(Integer) }
  def position
    # @position is expected to be set in decsion.results method
    raise 'Position not set' unless defined?(@position)
    @position
  end

  sig { returns(String) }
  def random_id
    super.to_s.rjust(9, '0')
  end
end

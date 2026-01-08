# typed: false

class DecisionResult < ApplicationRecord
  self.primary_key = "option_id"
  self.table_name = "decision_results" # view

  def api_json
    {
      position: position,
      decision_id: decision_id,
      option_id: option_id,
      option_title: option_title,
      option_random_id: random_id,
      approved_yes: approved_yes,
      approved_no: approved_no,
      approval_count: approval_count,
      stars: stars,
    }
  end

  def get_sorting_factor(other_result)
    if self.approved_yes != other_result.approved_yes
      'approved_yes'
    elsif self.stars != other_result.stars
      'stars'
    else
      'random_id'
    end
  end

  def is_sorting_factor?(other_result, factor)
    return false if other_result.nil?
    get_sorting_factor(other_result) == factor
  end

  def position=(position)
    @position = position
  end

  def position
    # @position is expected to be set in decsion.results method
    raise 'Position not set' unless defined?(@position)
    @position
  end

  def random_id
    super.to_s.rjust(9, '0')
  end
end

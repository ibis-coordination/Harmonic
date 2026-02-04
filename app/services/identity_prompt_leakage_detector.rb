# typed: strict
# frozen_string_literal: true

# Detects when an agent may be directly quoting its identity prompt in outputs.
#
# Identity prompts describe who an agent is and how it should behave. While not
# necessarily secret, agents should embody their prompts naturally rather than
# quoting them verbatim. This detector helps identify when an agent might be
# revealing its instructions directly (e.g., due to a prompt injection attack
# or confused behavior).
#
# Detection methods:
# 1. Canary token detection - A unique token embedded in the prompt that should never appear in outputs
# 2. Similarity detection - Checks if output contains substantial portions of the identity prompt
#
# @example Usage in AgentNavigator
#   detector = IdentityPromptLeakageDetector.new
#   detector.extract_from_content(whoami_content)
#
#   # Later, after LLM response:
#   if detector.check_leakage(llm_output)
#     Rails.logger.warn("Identity prompt leakage detected")
#   end
#
class IdentityPromptLeakageDetector
  extend T::Sig

  # Minimum length of matching substring to consider as potential leakage
  SIMILARITY_THRESHOLD_CHARS = 50

  # Minimum percentage of identity prompt that must match to trigger similarity detection
  SIMILARITY_THRESHOLD_PERCENT = 0.3

  sig { void }
  def initialize
    @canary = T.let(nil, T.nilable(String))
    @identity_prompt = T.let(nil, T.nilable(String))
    @active = T.let(false, T::Boolean)
  end

  # Extract canary and identity prompt from whoami page content.
  #
  # Looks for the pattern:
  #   <canary:VALUE>
  #   ...identity prompt content...
  #   </canary:VALUE>
  #
  # @param content [String] The rendered whoami page content
  # @return [Boolean] True if extraction was successful
  sig { params(content: String).returns(T::Boolean) }
  def extract_from_content(content)
    # Match the canary pattern: <canary:value>...</canary:value>
    # Value can be alphanumeric (hex from SecureRandom.hex)
    match = content.match(%r{<canary:([a-zA-Z0-9]+)>(.*?)</canary:\1>}m)

    return false unless match

    @canary = match[1]
    @identity_prompt = match[2]&.strip
    @active = @canary.present? && @identity_prompt.present?

    @active
  end

  # Check if the output contains potential identity prompt leakage.
  #
  # @param output [String] The LLM output to check
  # @return [Hash] Result with :leaked (boolean) and :reasons (array of strings)
  sig { params(output: String).returns(T::Hash[Symbol, T.untyped]) }
  def check_leakage(output)
    return { leaked: false, reasons: [] } unless @active

    reasons = []

    # Check 1: Canary token appears in output
    reasons << "canary_token_detected" if @canary && output.include?(@canary)

    # Check 2: Substantial portion of identity prompt appears in output
    reasons << "identity_prompt_similarity" if @identity_prompt && substantial_overlap?(output, @identity_prompt)

    {
      leaked: reasons.any?,
      reasons: reasons,
    }
  end

  # Check if detector has been initialized with content
  sig { returns(T::Boolean) }
  def active?
    @active
  end

  private

  # Check if output contains substantial overlap with identity prompt.
  #
  # Uses longest common substring to detect if significant portions
  # of the identity prompt appear in the output.
  #
  # @param output [String] The output to check
  # @param identity_prompt [String] The identity prompt to compare against
  # @return [Boolean] True if substantial overlap detected
  sig { params(output: String, identity_prompt: String).returns(T::Boolean) }
  def substantial_overlap?(output, identity_prompt)
    return false if identity_prompt.length < SIMILARITY_THRESHOLD_CHARS

    # Normalize both strings for comparison
    normalized_output = normalize(output)
    normalized_prompt = normalize(identity_prompt)

    # Find longest common substring
    lcs_length = longest_common_substring_length(normalized_output, normalized_prompt)

    # Check if LCS exceeds thresholds
    return true if lcs_length >= SIMILARITY_THRESHOLD_CHARS
    return true if lcs_length.to_f / normalized_prompt.length >= SIMILARITY_THRESHOLD_PERCENT

    false
  end

  # Normalize text for comparison (lowercase, collapse whitespace)
  sig { params(text: String).returns(String) }
  def normalize(text)
    text.downcase.gsub(/\s+/, " ").strip
  end

  # Calculate length of longest common substring between two strings.
  #
  # Uses dynamic programming approach with space optimization.
  # For very long strings, samples to avoid excessive computation.
  #
  # @param first_string [String] First string
  # @param second_string [String] Second string
  # @return [Integer] Length of longest common substring
  sig { params(first_string: String, second_string: String).returns(Integer) }
  def longest_common_substring_length(first_string, second_string)
    # For performance, limit comparison length
    max_len = 2000
    str_a = first_string.length > max_len ? first_string.slice(0, max_len) || first_string : first_string
    str_b = second_string.length > max_len ? second_string.slice(0, max_len) || second_string : second_string

    return 0 if str_a.empty? || str_b.empty?

    # Use rolling array for space efficiency
    prev_row = T.let(Array.new(str_b.length + 1, 0), T::Array[Integer])
    curr_row = T.let(Array.new(str_b.length + 1, 0), T::Array[Integer])
    max_length = T.let(0, Integer)

    str_a.each_char.with_index do |char_a, _i|
      str_b.each_char.with_index do |char_b, j|
        if char_a == char_b
          curr_row[j + 1] = (prev_row[j] || 0) + 1
          current_val = curr_row[j + 1] || 0
          max_length = current_val if current_val > max_length
        else
          curr_row[j + 1] = 0
        end
      end
      prev_row, curr_row = curr_row, prev_row
      curr_row.fill(0)
    end

    max_length
  end
end

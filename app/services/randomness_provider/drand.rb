# typed: true
# frozen_string_literal: true

module RandomnessProvider
  class Drand
    extend T::Sig
    include RandomnessProvider

    # drand quicknet chain parameters
    CHAIN_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
    GENESIS_TIME = 1_692_803_367 # Unix seconds, 2023-08-23T15:29:27Z
    PERIOD = 3 # seconds per round

    # Multiple independent relays for cross-verification.
    # If any relay returns a different randomness value, the fetch is rejected.
    RELAYS = [
      "https://api.drand.sh",
      "https://api2.drand.sh",
      "https://api3.drand.sh",
    ].freeze

    BASE_URL = RELAYS.first

    # Returns the first drand round published AFTER the given deadline.
    # This ensures the randomness was not yet known at the deadline.
    # Round R is published at: genesis + (R - 1) * period
    sig { override.params(deadline: T.any(Time, ActiveSupport::TimeWithZone)).returns(Integer) }
    def round_for_timestamp(deadline)
      unix = deadline.to_i
      return 2 if unix <= GENESIS_TIME

      # The round active at `unix` is: floor((unix - genesis) / period) + 1
      # We want the NEXT round (first one not yet published at the deadline)
      ((unix - GENESIS_TIME) / PERIOD) + 2
    end

    sig { override.params(round_number: Integer).returns({ round: Integer, randomness: String }) }
    def fetch_round(round_number)
      results = fetch_from_relays(round_number)

      raise "drand: all relays failed for round #{round_number}" if results.empty?

      randomness_values = results.pluck(:randomness).uniq
      if randomness_values.size > 1
        raise "drand: relay disagreement for round #{round_number} — " \
              "got #{randomness_values.size} different randomness values"
      end

      T.must(results.first)
    end

    private

    sig { params(round_number: Integer).returns(T::Array[{ round: Integer, randomness: String }]) }
    def fetch_from_relays(round_number)
      results = T.let([], T::Array[{ round: Integer, randomness: String }])
      errors = T.let([], T::Array[String])

      RELAYS.each do |relay_url|
        result = fetch_from_relay(relay_url, round_number)
        results << result
        # Stop early if we have 2 agreeing relays
        break if results.size >= 2 && results.pluck(:randomness).uniq.size == 1
      rescue StandardError => e
        errors << "#{relay_url}: #{e.message}"
      end

      raise "drand: all relays failed for round #{round_number}: #{errors.join("; ")}" if results.empty?

      results
    end

    sig { params(relay_url: String, round_number: Integer).returns({ round: Integer, randomness: String }) }
    def fetch_from_relay(relay_url, round_number)
      uri = URI("#{relay_url}/#{CHAIN_HASH}/public/#{round_number}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 10
      request = Net::HTTP::Get.new(uri)
      response = http.request(request)
      raise "HTTP #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(T.must(response.body))
      { round: data.fetch("round"), randomness: data.fetch("randomness") }
    end

    public

    sig { override.params(round_number: Integer).returns(T.nilable(String)) }
    def verification_url(round_number)
      "#{BASE_URL}/#{CHAIN_HASH}/public/#{round_number}"
    end

    sig do
      override.params(deadline: T.any(Time, ActiveSupport::TimeWithZone), round_number: Integer)
        .returns(T::Hash[Symbol, T.untyped])
    end
    def round_derivation(deadline, round_number)
      deadline_unix = deadline.to_i
      {
        description: "The beacon round is the first drand round published after the lottery deadline. " \
                     "This ensures the randomness was not yet known when entries were added.",
        formula: "round = floor( (deadline_unix - genesis_time) / period ) + 2",
        steps: [
          "deadline_unix = #{deadline_unix}",
          "genesis_time  = #{GENESIS_TIME}",
          "period        = #{PERIOD} seconds",
          "",
          "round = floor( (#{deadline_unix} - #{GENESIS_TIME}) / #{PERIOD} ) + 2",
          "round = #{round_number}",
        ],
        chain_info_url: "#{BASE_URL}/#{CHAIN_HASH}/info",
        chain_info_note: "You can verify the chain parameters (genesis time and period) " \
                         "by fetching the chain info from the drand network.",
      }
    end
  end
end

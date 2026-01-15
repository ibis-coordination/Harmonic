# typed: true

class LinkParser
  extend T::Sig

  sig { params(text: String, subdomain: T.nilable(String), superagent_handle: T.nilable(String), block: T.proc.params(record: T.untyped).void).returns(String) }
  def self.parse(text, subdomain: nil, superagent_handle: nil, &block)
    models = { 'n' => Note, 'c' => Commitment, 'd' => Decision, 'r' => RepresentationSession }
    domain = "#{subdomain}.#{ENV['HOSTNAME']}" + (superagent_handle ? "/(?:studios|scenes)/#{superagent_handle}" : '')
    prefixes = models.keys.join
    pattern = Regexp.new("https://#{domain}/([#{prefixes}])/([0-9a-f-]+)")
    memo = {}
    text.gsub(pattern) do |match|
      prefix = $1
      id = $2
      model = models[prefix]
      column_name = id.length == 8 ? :truncated_id : :id
      record = model.find_by(column_name => id)
      if record && !memo[record.id]
        memo[record.id] = true
        yield record
      end
    end
  end

  sig { params(path: String).returns(T.untyped) }
  def self.parse_path(path)
    models = { 'n' => Note, 'c' => Commitment, 'd' => Decision, 'r' => RepresentationSession }
    path_pieces = path.split('/')
    prefix = path_pieces[-2]
    id = path_pieces[-1]
    return nil if id.nil?
    superagent_handle = path_pieces[-3]
    superagent_ids = Superagent.where(handle: superagent_handle).pluck(:id)
    model = models[prefix]
    column_name = id.length == 8 ? :truncated_id : :id
    record = model.find_by(column_name => id, superagent_id: superagent_ids)
  end

  sig { params(from_record: T.nilable(T.any(Note, Decision, Commitment)), subdomain: T.nilable(String), superagent_handle: T.nilable(String)).void }
  def initialize(from_record: nil, subdomain: nil, superagent_handle: nil)
    @from_record = from_record
    @subdomain = subdomain
    @superagent_handle = superagent_handle
    if @from_record.nil? && (@subdomain.nil? || @superagent_handle.nil?)
      raise ArgumentError, "Must pass in either from_record or subdomain + superagent_handle"
    elsif @from_record && @subdomain
      raise ArgumentError, "Cannot pass in both from_record and subdomain/superagent_handle"
    end
  end

  sig { params(text: T.nilable(String), block: T.proc.params(record: T.untyped).void).void }
  def parse(text = nil, &block)
    if @from_record
      if text
        raise ArgumentError, "Cannot pass in text with from_record"
      end
      text = @from_record.class == Note ? T.unsafe(@from_record).text : T.unsafe(@from_record).description
      subdomain = T.must(@from_record.tenant).subdomain
      superagent_handle = T.must(@from_record.superagent).handle
      self.class.parse(text, subdomain: subdomain, superagent_handle: superagent_handle) do |to_record|
        yield to_record
      end
    elsif @subdomain && @superagent_handle
      if text.nil?
        raise ArgumentError, "Cannot pass in subdomain without text"
      end
      self.class.parse(text, subdomain: @subdomain, superagent_handle: @superagent_handle) do |to_record|
        yield to_record
      end
    else
      raise ArgumentError, "Cannot parse without text or from_record"
    end
  end

  sig { void }
  def parse_and_create_link_records!
    unless @from_record
      raise ArgumentError, "Cannot create link records without a from_record"
    end
    existing_links = Link.where(from_linkable: @from_record)
    # Create hash of existing links by to_record_id
    existing_links_by_to_linkable_id = existing_links.index_by(&:to_linkable_id)
    self.parse do |to_record|
      existing_link = existing_links_by_to_linkable_id[to_record.id]
      if existing_link
        existing_links_by_to_linkable_id.delete(to_record.id)
      else
        Link.create!(from_linkable: @from_record, to_linkable: to_record)
      end
    end
    # Links that are no longer in the text should be destroyed
    existing_links_by_to_linkable_id.values.each(&:destroy)
  end
end
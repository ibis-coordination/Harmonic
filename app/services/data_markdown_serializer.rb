# typed: true

class DataMarkdownSerializer
  extend T::Sig

  sig { params(data: T.any(String, T::Hash[T.untyped, T.untyped], T::Array[T.untyped]), title: String).returns(String) }
  def self.serialize_for_embed_in_markdown(data:, title: "Data")
    if data.is_a?(String)
      data = JSON.parse(data)
    end
    markdown = "# #{title}\n```json\n" + JSON.pretty_generate(data) + "\n```"
  end

  sig { params(markdown: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.extract_data_from_markdown(markdown)
    pattern = /# (?<title>.*)\n+```json\n(?<json>.*)\n```/m
    # one or more, loop through all matches
    markdown.scan(pattern).map do |match|
      {
        title: match[0],
        data: JSON.parse(T.must(match[1]))
      }
    end
  end
end
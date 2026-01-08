# typed: false

class DataMarkdownSerializer
  def self.serialize_for_embed_in_markdown(data:, title: "Data")
    if data.is_a?(String)
      data = JSON.parse(data)
    end
    markdown = "# #{title}\n```json\n" + JSON.pretty_generate(data) + "\n```"
  end

  def self.extract_data_from_markdown(markdown)
    pattern = /# (?<title>.*)\n+```json\n(?<json>.*)\n```/m
    # one or more, loop through all matches
    markdown.scan(pattern).map do |match|
      {
        title: match[0],
        data: JSON.parse(match[1])
      }
    end
  end
end
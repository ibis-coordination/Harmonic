# LLM Chat Feature - Minimal MVP

## Goal

Prove LLM-in-app functionality with the smallest possible change. A simple "Ask Harmonic" form that answers questions about how to use Harmonic.

**No database changes. No persistence. No RAG.**

## What We're Building

A `/ask` page where users type a question about Harmonic, submit, and see the LLM's response.

## Files to Create/Modify

### 1. Docker Infrastructure

**docker-compose.yml** - Add 2 services:
```yaml
ollama:
  image: ollama/ollama:latest
  volumes:
    - ollama_data:/root/.ollama

litellm:
  image: ghcr.io/berriai/litellm:main-latest
  command: ["--config", "/app/litellm_config.yaml"]
  ports:
    - "4000:4000"
  volumes:
    - ./config/litellm_config.yaml:/app/litellm_config.yaml
  depends_on:
    - ollama
  env_file:
    - .env
```

**config/litellm_config.yaml**:
```yaml
model_list:
  - model_name: default
    litellm_params:
      model: ollama/llama3.2
      api_base: http://ollama:11434
```

**scripts/setup-ollama.sh**:
```bash
#!/bin/bash
docker compose exec ollama ollama pull llama3.2
```

### 2. Service (1 file)

**app/services/llm_client.rb**:
```ruby
class LlmClient
  def initialize
    @base_url = ENV.fetch("LITELLM_BASE_URL", "http://litellm:4000")
  end

  def ask(question)
    response = Faraday.post("#{@base_url}/v1/chat/completions") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        model: "default",
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: question }
        ]
      }.to_json
    end

    JSON.parse(response.body).dig("choices", 0, "message", "content")
  end

  private

  def system_prompt
    @system_prompt ||= <<~PROMPT
      You are a helpful assistant for Harmonic, a social agency platform.

      #{File.read(Rails.root.join("mcp-server/CONTEXT.md"))}

      Answer questions about how to use Harmonic. Be concise and helpful.
    PROMPT
  end
end
```

### 3. Controller (1 file)

**app/controllers/ask_controller.rb**:
```ruby
class AskController < ApplicationController
  def index
    @question = nil
    @answer = nil
  end

  def create
    @question = params[:question]
    @answer = LlmClient.new.ask(@question)
    render :index
  end
end
```

### 4. View (1 file)

**app/views/ask/index.html.erb**:
```erb
<h1>Ask Harmonic</h1>

<%= form_with url: ask_path, method: :post, local: true do |f| %>
  <%= f.text_area :question, value: @question, placeholder: "Ask a question about Harmonic...", rows: 3 %>
  <%= f.submit "Ask" %>
<% end %>

<% if @answer %>
  <h2>Answer</h2>
  <div class="answer">
    <%= simple_format @answer %>
  </div>
<% end %>
```

### 5. Routes

**config/routes.rb** - Add:
```ruby
get "ask" => "ask#index"
post "ask" => "ask#create"
```

### 6. Environment

**.env** - Add:
```bash
LITELLM_BASE_URL=http://litellm:4000
```

## Implementation Order

1. Add ollama + litellm to docker-compose.yml
2. Create config/litellm_config.yaml
3. Create scripts/setup-ollama.sh
4. Add LITELLM_BASE_URL to .env
5. Create app/services/llm_client.rb
6. Create app/controllers/ask_controller.rb
7. Create app/views/ask/index.html.erb
8. Add routes

## Verification

The LLM services are **optional** and don't start by default (to save resources).
They use Docker profiles and have memory limits (4GB for Ollama, 512MB for LiteLLM).

**To use the LLM chat feature:**
```bash
# Start the app with LLM services enabled
docker compose --profile llm up -d

# First time only: pull the model (~1.3GB)
./scripts/setup-ollama.sh
```

**To stop just the LLM services (frees memory):**
```bash
docker compose stop ollama litellm
```

**Test the feature:**
1. Visit `/ask`
2. Type "How do I create a note?"
3. See LLM response

## What This Proves

- ✅ Ollama runs locally in Docker
- ✅ LiteLLM proxies requests correctly
- ✅ Rails can call the LLM
- ✅ System prompt with Harmonic docs works
- ✅ Basic UI flow works

## Future Enhancements (not in MVP)

- Conversation persistence
- RAG over user's notes/decisions/commitments
- Streaming responses
- Rate limiting
- Markdown API for LLM access

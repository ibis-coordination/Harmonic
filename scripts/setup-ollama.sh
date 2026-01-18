#!/bin/bash
# Pull the default Ollama model for the LLM chat feature
# Run this after starting the LLM services for the first time

set -e

echo "Pulling llama3.2:1b model (lightweight, ~1.3GB)..."
docker compose --profile llm exec ollama ollama pull llama3.2:1b
echo "Done! The model is ready for use."

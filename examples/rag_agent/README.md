# RAG Agent

An ADK Elixir example that demonstrates **Retrieval-Augmented Generation** — a port of the Python ADK `rag_agent/agent.py` sample.

## How It Works

The Python sample uses Vertex AI RAG for document retrieval. This Elixir version implements a simple **in-memory corpus** with keyword-based retrieval — no external services or vector databases required.

The agent:
1. Receives a user question
2. Calls `retrieve_documents` to search the corpus
3. Uses the retrieved content to ground its answer
4. Cites the source document

### Corpus

`RagAgent.Corpus` stores hardcoded documentation snippets about ADK Elixir covering:
- Agent types (LlmAgent, LoopAgent, SequentialAgent, ParallelAgent)
- Tools and FunctionTool
- Runner and session management
- RunConfig, error handling, web API, LLM backends

Retrieval uses tokenized keyword matching with:
- Stop word removal
- Token length weighting (longer tokens = more specific)
- Prefix matching for partial matches

### Extending

To use real vector search in production, replace `RagAgent.Corpus.retrieve/2` with:
- **pgvector** via Ecto for PostgreSQL embeddings
- **Vertex AI RAG** via the Google Cloud API
- **Pinecone / Weaviate / Meilisearch** — any search backend

The agent code stays the same — only the retrieval function changes.

## Usage

```elixir
iex -S mix

RagAgent.chat("How do I create a tool in ADK Elixir?")
RagAgent.chat("What workflow agents are available?")
RagAgent.chat("How does sub-agent transfer work?")

# Interactive
RagAgent.interactive()
```

## Configuration

```bash
ADK_MODEL=gemini-flash-latest iex -S mix
```

## Files

| File | Purpose |
|------|---------|
| `lib/rag_agent.ex` | Agent definition, chat/interactive functions |
| `lib/rag_agent/corpus.ex` | In-memory document store + keyword retrieval |
| `test/rag_agent_test.exs` | Tests for agent and corpus retrieval |

## Running Tests

```bash
mix test
```

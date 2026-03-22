defmodule ADK.Plugin.DebugLogging do
  @moduledoc """
  A plugin that logs debug information for ADK runs, saving states to a file.
  Parity with Python's DebugLoggingPlugin.
  """

  @behaviour ADK.Plugin

  @pdict_key {__MODULE__, :state}

  @type config :: %{
          output_path: String.t(),
          include_session_state: boolean(),
          include_system_instruction: boolean()
        }

  @impl true
  def init(config) do
    config = if is_map(config), do: Map.to_list(config), else: config || []

    {:ok,
     %{
       output_path: Keyword.get(config, :output_path, "adk_debug.yaml"),
       include_session_state: Keyword.get(config, :include_session_state, true),
       include_system_instruction: Keyword.get(config, :include_system_instruction, true)
     }}
  end

  @impl true
  def before_run(context, state) do
    invocation_id = context.invocation_id || "unknown"
    session_id =
      if context.session_pid do
        case ADK.Session.get(context.session_pid) do
          {:ok, session} -> session.id
          _ -> "unknown"
        end
      else
        "unknown"
      end

    initial_entry = %{
      "entry_type" => "invocation_start",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "data" => %{
        "agent_name" => get_agent_id(context)
      }
    }

    # Store state in pdict using invocation_id as key
    Process.put({@pdict_key, invocation_id}, %{
      invocation_id: invocation_id,
      session_id: session_id,
      entries: [initial_entry],
      config: state
    })

    {:cont, context, state}
  end

  @impl true
  def after_run(events, context, state) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        {events, state}

      pdict_state ->
        entries = Enum.reverse(pdict_state.entries)

        entries =
          if state.include_session_state do
            session_entry = %{
              "entry_type" => "session_state_snapshot",
              "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
              "data" => %{
                "state" =>
                  if context.session_pid do
                    ADK.Session.get_all_state(context.session_pid)
                  else
                    %{}
                  end
              }
            }
            entries ++ [session_entry]
          else
            entries
          end

        doc = %{
          "invocation_id" => pdict_state.invocation_id,
          "session_id" => pdict_state.session_id,
          "entries" => entries
        }

        yaml_content = "---\n" <> Jason.encode!(doc) <> "\n"

        File.write(state.output_path, yaml_content, [:append])

        # Cleanup
        Process.delete({@pdict_key, invocation_id})

        {events, state}
    end
  end

  @impl true
  def before_model(context, request) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        {:ok, request}

      pdict_state ->
        system_instruction = Map.get(request, :system_instruction, "") || ""
        system_instruction = if is_binary(system_instruction), do: system_instruction, else: ""
        
        config_data =
          if pdict_state.config.include_system_instruction do
            %{
              "system_instruction" => system_instruction,
              "system_instruction_length" => String.length(system_instruction)
            }
          else
            %{
              "system_instruction_length" => String.length(system_instruction)
            }
          end

        entry = %{
          "entry_type" => "llm_request",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "model" => Map.get(request, :model, "unknown"),
            "content_count" => length(Map.get(request, :messages, [])),
            "config" => config_data
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        {:ok, request}
    end
  end

  @impl true
  def after_model(context, response) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        response

      pdict_state ->
        entry = %{
          "entry_type" => "llm_response",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "turn_complete" => true,
            "content" =>
              case response do
                {:ok, resp} ->
                  %{
                    "role" => "model",
                    "parts" => [%{"text" => Map.get(resp, :text, "")}]
                  }

                {:error, _} ->
                  %{}
              end
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        response
    end
  end

  @impl true
  def before_tool(context, tool_name, args) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        {:ok, args}

      pdict_state ->
        entry = %{
          "entry_type" => "tool_call",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "tool_name" => tool_name,
            "args" => args
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        {:ok, args}
    end
  end

  @impl true
  def after_tool(context, tool_name, result) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        result

      pdict_state ->
        entry = %{
          "entry_type" => "tool_response",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "tool_name" => tool_name,
            "result" =>
              case result do
                {:ok, data} -> %{"output" => "success", "data" => data}
                {:error, err} -> %{"output" => "error", "error" => inspect(err)}
                other -> %{"output" => "success", "data" => inspect(other)}
              end
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        result
    end
  end

  @impl true
  def on_model_error(context, {:error, error} = err_tuple) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        err_tuple

      pdict_state ->
        error_type = if is_exception(error), do: inspect(error.__struct__), else: "Error"
        
        entry = %{
          "entry_type" => "llm_error",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "error_type" => error_type,
            "error_message" => inspect(error)
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        err_tuple
    end
  end

  @impl true
  def on_tool_error(context, tool_name, {:error, error} = err_tuple) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        err_tuple

      pdict_state ->
        error_type = if is_exception(error), do: inspect(error.__struct__), else: "Error"

        entry = %{
          "entry_type" => "tool_error",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "data" => %{
            "tool_name" => tool_name,
            "error_type" => error_type,
            "error_message" => inspect(error)
          }
        }

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        err_tuple
    end
  end

  @impl true
  def on_event(context, event) do
    invocation_id = context.invocation_id || "unknown"

    case Process.get({@pdict_key, invocation_id}) do
      nil ->
        :ok

      pdict_state ->
        content_text = if Map.has_key?(event, :content) and is_map(event.content) do
          Map.get(event.content, :text, "")
        else
          ""
        end
        
        entry =
          case event.author do
            "user" ->
              %{
                "entry_type" => "user_message",
                "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
                "data" => %{
                  "content" => %{
                    "role" => "user",
                    "parts" => [%{"text" => content_text}]
                  }
                }
              }

            _ ->
              %{
                "entry_type" => "event",
                "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
                "data" => %{
                  "author" => event.author,
                  "event_id" => event.id
                }
              }
          end

        Process.put({@pdict_key, invocation_id}, %{pdict_state | entries: [entry | pdict_state.entries]})

        :ok
    end
  end

  defp get_agent_id(%{agent: %{name: name}}) when is_binary(name), do: name
  defp get_agent_id(_), do: "unknown"
end
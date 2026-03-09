defmodule ToolUse.Tools do
  @moduledoc """
  Tool definitions for the multi-tool agent.

  Each tool is a `ADK.Tool.FunctionTool` with:
  - A name and description (for the LLM)
  - A JSON Schema for parameters
  - An implementation function
  """

  @doc "Returns all tools for the agent."
  def all do
    [calculator(), string_utils(), current_time()]
  end

  @doc "Math expression evaluator."
  def calculator do
    ADK.Tool.FunctionTool.new("calculator",
      description: "Evaluate a mathematical expression. Supports +, -, *, /, ** (power), parentheses.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "expression" => %{
            "type" => "string",
            "description" => "Math expression to evaluate, e.g. '(2 + 3) * 4'"
          }
        },
        "required" => ["expression"]
      },
      func: fn _ctx, %{"expression" => expr} ->
        case safe_eval(expr) do
          {:ok, result} -> {:ok, %{"result" => result}}
          {:error, reason} -> {:ok, %{"error" => reason}}
        end
      end
    )
  end

  @doc "String manipulation utilities."
  def string_utils do
    ADK.Tool.FunctionTool.new("string_utils",
      description: """
      Perform string operations. Supported operations:
      - "word_count": count words in text
      - "reverse": reverse the text
      - "uppercase": convert to uppercase
      - "length": character count
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The input text"},
          "operation" => %{
            "type" => "string",
            "enum" => ["word_count", "reverse", "uppercase", "length"],
            "description" => "The string operation to perform"
          }
        },
        "required" => ["text", "operation"]
      },
      func: fn _ctx, args -> {:ok, string_op(args["operation"], args["text"])} end
    )
  end

  @doc "Current date/time tool."
  def current_time do
    ADK.Tool.FunctionTool.new("current_time",
      description: "Get the current date and time. Optionally specify a UTC offset.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "utc_offset_hours" => %{
            "type" => "number",
            "description" => "UTC offset in hours, e.g. 9 for Tokyo (UTC+9), -5 for New York (UTC-5). Default: 0"
          }
        }
      },
      func: fn _ctx, args ->
        offset = args["utc_offset_hours"] || 0
        now = DateTime.utc_now() |> DateTime.add(trunc(offset * 3600), :second)

        {:ok, %{
          "datetime" => Calendar.strftime(now, "%Y-%m-%d %H:%M:%S"),
          "utc_offset" => offset,
          "day_of_week" => Calendar.strftime(now, "%A")
        }}
      end
    )
  end

  # --- Private helpers ---

  # Safe math evaluator using Elixir's Code module with restricted operations
  defp safe_eval(expr) do
    # Sanitize: only allow digits, operators, parens, dots, spaces
    sanitized = String.replace(expr, "**", "pow_op")

    if Regex.match?(~r/^[\d\s\+\-\*\/\.\(\)pow_]+$/, sanitized) do
      # Convert ** to :math.pow calls, then evaluate
      elixir_expr =
        expr
        |> String.replace("^", "**")
        |> String.replace(~r/(\d+(?:\.\d+)?)\s*\*\*\s*(\d+(?:\.\d+)?)/, ":math.pow(\\1, \\2)")

      try do
        {result, _} = Code.eval_string(elixir_expr)
        {:ok, result}
      rescue
        e -> {:error, "Evaluation error: #{Exception.message(e)}"}
      end
    else
      {:error, "Invalid expression. Only numbers and basic operators (+, -, *, /, **) are allowed."}
    end
  end

  defp string_op("word_count", text), do: %{"word_count" => text |> String.split() |> length()}
  defp string_op("reverse", text), do: %{"reversed" => String.reverse(text)}
  defp string_op("uppercase", text), do: %{"uppercase" => String.upcase(text)}
  defp string_op("length", text), do: %{"length" => String.length(text)}
  defp string_op(op, _text), do: %{"error" => "Unknown operation: #{op}"}
end

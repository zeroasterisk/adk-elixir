defmodule ADK.Harness.Feedback do
  @moduledoc """
  Feedback loop for agent self-verification.

  After an agent produces output, a verifier agent (or function) checks it.
  On rejection, the original agent retries with the rejection reason appended.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Examples

      feedback = %ADK.Harness.Feedback{
        verifier: fn output -> if String.length(output) > 10, do: :ok, else: {:reject, "Too short"} end,
        max_retries: 3,
        on_reject: fn reason, attempt -> "Rejected: \#{reason}. Attempt \#{attempt}." end
      }
  """

  defstruct [:verifier, :on_reject, max_retries: 3]

  @type verifier :: (String.t() -> :ok | {:reject, String.t()}) | struct()

  @type t :: %__MODULE__{
          verifier: verifier(),
          max_retries: non_neg_integer(),
          on_reject: (String.t(), non_neg_integer() -> String.t()) | nil
        }

  @doc """
  Check output against the verifier. Returns `:ok` or `{:reject, reason}`.
  """
  @spec verify(t(), String.t()) :: :ok | {:reject, String.t()}
  def verify(%__MODULE__{verifier: verifier}, output) when is_function(verifier, 1) do
    verifier.(output)
  end

  @doc """
  Build a retry message from a rejection reason and attempt number.
  Uses the configured `on_reject` callback, or a default message.
  """
  @spec retry_message(t(), String.t(), non_neg_integer()) :: String.t()
  def retry_message(%__MODULE__{on_reject: on_reject}, reason, attempt)
      when is_function(on_reject, 2) do
    on_reject.(reason, attempt)
  end

  def retry_message(%__MODULE__{}, reason, attempt) do
    "Your previous answer was rejected: #{reason}. Please try again (attempt #{attempt})."
  end

  @doc """
  Returns true if more retries are available.
  """
  @spec retries_remaining?(t(), non_neg_integer()) :: boolean()
  def retries_remaining?(%__MODULE__{max_retries: max}, attempt) do
    attempt < max
  end
end

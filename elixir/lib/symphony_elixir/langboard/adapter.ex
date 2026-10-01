defmodule SymphonyElixir.Langboard.Adapter do
  @moduledoc """
  Langboard-backed tracker adapter.

  Board columns act as tracker states: ``active_states`` and ``terminal_states``
  carry column names. Card listing comes from the board card collection and
  per-card refresh from the card context bundle. Dispatchability is fail-closed:
  a card point-read without a proven execution fence (``execution.is_ready``)
  is never dispatchable.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Langboard.Client
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :missing_langboard_active_states),
         :ok <- validate_states(tracker_settings.terminal_states, :missing_langboard_terminal_states) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings),
    do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :langboard_client_module, Client)
  end

  defp validate_states(states, _missing_error) when is_list(states) and states != [] do
    if Enum.all?(states, &is_binary/1) do
      :ok
    else
      {:error, :invalid_langboard_states}
    end
  end

  defp validate_states(_states, missing_error), do: {:error, missing_error}
end

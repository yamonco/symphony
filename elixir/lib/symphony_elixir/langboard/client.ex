defmodule SymphonyElixir.Langboard.Client do
  @moduledoc """
  Thin Langboard REST client for board card polling.

  Reads two endpoints only, matching the machine-credential scope the board
  grants orchestrators:

    * ``GET /board/{board_uid}/cards`` — board card collection (state polling)
    * ``GET /board/{board_uid}/card/{card_uid}/context`` — bounded card bundle
      (ID refresh, including the fail-closed execution fence)

  Column names are the tracker states. ``active_states`` selects candidate
  cards; everything else stays untouched.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @page_size 100
  @user_agent "symphony"

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    ["LANGBOARD_TOKEN" | env_reference_names([provider["token"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker, &perform_request/4)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker, &perform_request/4)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 4) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 4) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun) do
    normalized_states = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()
    ids = Enum.uniq(state_names)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, langboard_settings} <- settings(tracker_settings) do
          do_fetch_cards(langboard_settings, normalized_states, request_fun, [], 0)
        end
    end
  end

  defp do_fetch_cards(settings, requested_states, request_fun, acc, fetched) do
    params = %{"limit" => @page_size, "offset" => fetched}

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             board_cards_path(settings),
             params,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :langboard_unknown_payload} do
      cards = payload |> Enum.map(&normalize_card/1) |> Enum.reject(&is_nil/1)
      updated_acc = [cards | acc]

      if length(payload) < @page_size do
        issues =
          updated_acc
          |> Enum.reverse()
          |> List.flatten()
          |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))

        {:ok, issues}
      else
        do_fetch_cards(settings, requested_states, request_fun, updated_acc, fetched + length(payload))
      end
    end
  end

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, langboard_settings} <- settings(tracker_settings) do
          fetch_card_ids(ids, langboard_settings, request_fun, [])
        end
    end
  end

  defp fetch_card_ids([], _settings, _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_card_ids([id | rest], settings, request_fun, acc) do
    with {:ok, payload} <-
           request_with_settings(
             "GET",
             card_context_path(settings, id),
             %{},
             settings,
             request_fun,
             true
           ) do
      continue_card_id_fetch(payload, rest, settings, request_fun, acc)
    end
  end

  defp continue_card_id_fetch(:not_found, rest, settings, request_fun, acc) do
    fetch_card_ids(rest, settings, request_fun, acc)
  end

  defp continue_card_id_fetch(payload, rest, settings, request_fun, acc)
       when is_map(payload) do
    case normalize_context_card(payload) do
      %Issue{} = issue -> fetch_card_ids(rest, settings, request_fun, [issue | acc])
      nil -> fetch_card_ids(rest, settings, request_fun, acc)
    end
  end

  defp continue_card_id_fetch(_payload, _rest, _settings, _request_fun, _acc) do
    {:error, :langboard_unknown_payload}
  end

  # Collection card: uid + title + column name. Dispatchability is not proven
  # at the collection level, so candidate cards stay dispatchable and the
  # orchestrator's ID refresh (context bundle fence) refines them.
  defp normalize_card(card) when is_map(card) do
    uid = card["uid"]
    title = card["title"]
    state = card["project_column_name"]

    if present_string?(uid) and present_string?(title) and present_string?(state) do
      %Issue{
        id: uid,
        identifier: "LB-#{uid}",
        title: title,
        description: card_description(card["description"]),
        state: state,
        labels: extract_labels(card),
        blocked_by: [],
        dispatchable: is_nil(card["archived_at"]),
        created_at: parse_datetime(card["created_at"]),
        updated_at: parse_datetime(card["updated_at"])
      }
    end
  end

  defp normalize_card(_card), do: nil

  # Context bundle: scope_context.card.core carries identity and the card's
  # execution block carries the fail-closed fence.
  defp normalize_context_card(payload) when is_map(payload) do
    with %{} = card <- get_in(payload, ["scope_context", "card"]) || %{},
         %{} = core <- card["core"] || %{},
         uid when is_binary(uid) <- core["uid"],
         title when is_binary(title) <- core["title"] do
      {ready, generation} = execution_fence(card)

      %Issue{
        id: uid,
        identifier: "LB-#{uid}",
        title: title,
        description: card_description(core["description"]),
        state: core["column_name"] || card["project_column_name"],
        labels: extract_labels(core),
        blocked_by: [],
        dispatchable: ready,
        created_at: parse_datetime(core["created_at"]),
        updated_at: parse_datetime(core["updated_at"]),
        native_ref: %{
          "execution_generation" => generation,
          "execution_ready" => ready
        }
      }
    else
      _ -> nil
    end
  end

  defp normalize_context_card(_payload), do: nil

  defp execution_fence(card) do
    execution = card["execution"]

    ready =
      is_map(execution) and execution["is_ready"] == true and
        is_integer(execution["generation"])

    generation = if ready, do: execution["generation"], else: nil
    {ready, generation}
  end

  defp card_description(%{"content" => content}) when is_binary(content), do: content
  defp card_description(content) when is_binary(content), do: content
  defp card_description(_description), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_card), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, params, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, params, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("Langboard API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:langboard_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :langboard_unknown_payload}
    end
  end

  defp perform_request(method, path, params, settings) do
    request_opts = [
      method: method(method),
      url: settings.base_url <> path,
      headers: langboard_headers(settings.token),
      params: params,
      connect_options: [timeout: 30_000]
    ]

    case Req.request(request_opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, {:langboard_api_request, reason}}
    end
  end

  defp langboard_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"user-agent", @user_agent},
      {"accept", "application/json"}
    ]
  end

  defp board_cards_path(settings), do: "/board/#{settings.board_uid}/cards"

  defp card_context_path(settings, card_uid), do: "/board/#{settings.board_uid}/card/#{card_uid}/context"

  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method("PUT"), do: :put
  defp method("PATCH"), do: :patch
  defp method("DELETE"), do: :delete
  defp method(other), do: {:error, {:unsupported_method, other}}

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)

    base_url = resolve_setting(provider["base_url"], System.get_env("LANGBOARD_BASE_URL"))
    board_uid = resolve_setting(provider["board_uid"], System.get_env("LANGBOARD_BOARD_UID"))
    token = resolve_setting(provider["token"], System.get_env("LANGBOARD_TOKEN"))

    with {:ok, base_url} <- require_setting(base_url, :missing_langboard_base_url),
         {:ok, board_uid} <- require_setting(board_uid, :missing_langboard_board_uid),
         {:ok, token} <- require_setting(token, :missing_langboard_token) do
      {:ok, %{base_url: String.trim_trailing(base_url, "/"), board_uid: board_uid, token: token}}
    end
  end

  defp settings(_tracker_settings), do: {:error, :missing_langboard_tracker_settings}

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  # ``$VAR`` references keep secrets out of the workflow file without leaking
  # them into the agent workspace.
  defp resolve_setting("$" <> env_name, _fallback), do: System.get_env(env_name)
  defp resolve_setting(nil, fallback) when is_binary(fallback), do: fallback
  defp resolve_setting(nil, _fallback), do: nil
  defp resolve_setting(value, _fallback) when is_binary(value), do: value

  defp require_setting(nil, error), do: {:error, error}
  defp require_setting("", error), do: {:error, error}

  defp require_setting(value, _error) when is_binary(value), do: {:ok, value}

  defp env_reference_names(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn
      "$" <> name -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_state(state) when is_binary(state),
    do: state |> String.trim() |> String.downcase()

  defp normalize_state(_state), do: ""

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end

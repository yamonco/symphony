defmodule SymphonyElixir.Langboard.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Langboard.Adapter, as: LangboardAdapter
  alias SymphonyElixir.Langboard.Client, as: LangboardClient

  defmodule FakeLangboardClient do
    def fetch_issues_by_states(states) do
      send(self(), {:langboard_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:langboard_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    langboard_client_module = Application.get_env(:symphony_elixir, :langboard_client_module)

    on_exit(fn ->
      if is_nil(langboard_client_module) do
        Application.delete_env(:symphony_elixir, :langboard_client_module)
      else
        Application.put_env(:symphony_elixir, :langboard_client_module, langboard_client_module)
      end
    end)

    :ok
  end

  test "adapter validates langboard config and delegates reads" do
    settings = tracker_settings()

    assert :ok = LangboardAdapter.validate_config(settings)

    assert {:error, :missing_langboard_active_states} =
             LangboardAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_langboard_terminal_states} =
             LangboardAdapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_langboard_states} =
             LangboardAdapter.validate_config(%{settings | active_states: [42]})

    Application.put_env(:symphony_elixir, :langboard_client_module, FakeLangboardClient)

    assert {:ok, ["Doing"]} = LangboardAdapter.fetch_issues_by_states(["Doing"])
    assert_receive {:langboard_states_called, ["Doing"]}

    assert {:ok, ["CARD-1"]} = LangboardAdapter.fetch_issues_by_ids(["CARD-1"])
    assert_receive {:langboard_ids_called, ["CARD-1"]}
  end

  test "client validates board settings and declares token environments" do
    assert :ok = LangboardClient.validate_settings(tracker_settings())

    assert {:error, :missing_langboard_base_url} =
             LangboardClient.validate_settings(tracker_settings(%{"base_url" => nil}))

    assert {:error, :missing_langboard_board_uid} =
             LangboardClient.validate_settings(tracker_settings(%{"board_uid" => ""}))

    assert {:error, :missing_langboard_token} =
             LangboardClient.validate_settings(tracker_settings(%{"token" => nil}))

    assert LangboardClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_LANGBOARD_TOKEN"})) ==
             ["LANGBOARD_TOKEN", "SYMPHONY_LANGBOARD_TOKEN"]
  end

  test "client polls board cards filtered by column states" do
    request_fun = fn "GET", "/board/BOARD/cards", params, _settings ->
      send(self(), {:cards_polled, params})

      {:ok,
       %{
         status: 200,
         body: [
           raw_card("CARD-1", "Fix login", "Doing"),
           raw_card("CARD-2", "Write docs", "Doing"),
           raw_card("CARD-3", "Old work", "Done")
         ]
       }}
    end

    assert {:ok, issues} =
             LangboardClient.fetch_issues_by_states_for_test(
               ["doing"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["CARD-1", "CARD-2"]
    assert %SymphonyElixir.Tracker.Issue{} = issue = Enum.at(issues, 0)
    assert issue.identifier == "LB-CARD-1"
    assert issue.title == "Fix login"
    assert issue.state == "Doing"
    assert issue.dispatchable
    assert_receive {:cards_polled, %{"limit" => 100, "offset" => 0}}
  end

  test "client refreshes cards by id through the context bundle fence" do
    request_fun = fn "GET", "/board/BOARD/card/CARD-1/context", _params, _settings ->
      {:ok,
       %{
         status: 200,
         body: %{
           "scope_context" => %{
             "card" => %{
               "core" => %{
                 "uid" => "CARD-1",
                 "title" => "Fix login",
                 "description" => %{"content" => "Steps to reproduce"},
                 "column_name" => "Doing",
                 "created_at" => "2026-10-01T00:00:00Z",
                 "updated_at" => "2026-10-01T01:00:00Z"
               },
               "execution" => %{"is_ready" => true, "generation" => 3}
             }
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             LangboardClient.fetch_issues_by_ids_for_test(["CARD-1"], tracker_settings(), request_fun)

    assert issue.id == "CARD-1"
    assert issue.dispatchable
    assert issue.native_ref["execution_generation"] == 3
    assert issue.description == "Steps to reproduce"
  end

  test "context refresh fails closed without a proven execution fence" do
    request_fun = fn "GET", "/board/BOARD/card/CARD-9/context", _params, _settings ->
      {:ok,
       %{
         status: 200,
         body: %{
           "scope_context" => %{
             "card" => %{
               "core" => %{"uid" => "CARD-9", "title" => "No fence"},
               "execution" => %{"is_ready" => false, "generation" => 1}
             }
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             LangboardClient.fetch_issues_by_ids_for_test(["CARD-9"], tracker_settings(), request_fun)

    refute issue.dispatchable
  end

  test "context refresh tolerates missing cards" do
    request_fun = fn "GET", "/board/BOARD/card/GONE/context", _params, _settings ->
      {:ok, %{status: 404, body: %{"error" => "not found"}}}
    end

    assert {:ok, []} =
             LangboardClient.fetch_issues_by_ids_for_test(["GONE"], tracker_settings(), request_fun)
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    provider =
      Map.merge(
        %{
          "base_url" => "https://langboard.example.test",
          "board_uid" => "BOARD",
          "token" => "lb-token"
        },
        provider_overrides
      )

    %{
      kind: "langboard",
      active_states: ["Doing"],
      terminal_states: ["Done"],
      provider: provider
    }
  end

  defp raw_card(uid, title, column) do
    %{
      "uid" => uid,
      "title" => title,
      "project_column_name" => column,
      "created_at" => "2026-10-01T00:00:00Z",
      "updated_at" => "2026-10-01T01:00:00Z"
    }
  end
end

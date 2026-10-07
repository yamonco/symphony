defmodule SymphonyElixir.Codex.SessionCheckpoint do
  @moduledoc """
  Durable Codex thread identity for local workers. Records stay outside disposable
  workspaces; a changed tracker, issue, execution fence, or immutable pin denies resume.
  """

  alias SymphonyElixir.{Config, PathSafety, Workflow}

  @spec load(Path.t(), map() | nil, String.t() | nil) ::
          {:ok, map() | nil, String.t() | nil} | {:error, term()}
  def load(workspace, issue, worker_host) do
    case Config.settings!().codex.resume_state_root do
      nil -> {:ok, nil, nil}
      _root when not is_nil(worker_host) -> {:error, :remote_thread_checkpoint_unsupported}
      root when is_map(issue) -> load_local(root, workspace, issue)
      _root -> {:error, :thread_checkpoint_issue_required}
    end
  end

  @spec save(map() | nil, String.t()) :: :ok | {:error, term()}
  def save(nil, _thread_id), do: :ok

  def save(%{path: path, identity: identity}, thread_id) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    payload = Jason.encode!(%{"identity" => identity, "thread_id" => thread_id})

    result =
      with :ok <- File.write(temporary, payload, [:exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} -> {:error, {:thread_checkpoint_write_failed, reason}}
      end

    File.rm(temporary)
    result
  end

  defp load_local(root, workspace, issue) do
    expanded = Path.expand(root, Path.dirname(Workflow.workflow_file_path()))
    workspace_root = Config.local_workspace_root()

    with false <- match?({:ok, %File.Stat{type: :symlink}}, File.lstat(expanded)),
         {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, workspace_root} <- PathSafety.canonicalize(workspace_root),
         false <- canonical == workspace_root or String.starts_with?(canonical, workspace_root <> "/"),
         :ok <- File.mkdir_p(canonical),
         :ok <- File.chmod(canonical, 0o700) do
      tracker = Config.settings!().tracker

      scope = %{
        "workspace" => workspace,
        "tracker" => tracker.kind,
        "project" => tracker.project_slug,
        "endpoint" => tracker.endpoint,
        "board" => tracker.provider["board_uid"],
        "base_url" => tracker.provider["base_url"],
        "issue" => issue.id
      }

      pins =
        for name <- ["profile-pin.json", "armory-pin.json"], into: %{} do
          path = Path.join([workspace, ".fractalops", name])
          {name, if(File.regular?(path), do: digest(File.read!(path)), else: nil)}
        end

      identity = Map.merge(scope, %{"execution_generation" => (issue.native_ref || %{})["execution_generation"], "pins" => pins})
      checkpoint = %{path: Path.join(canonical, digest(Jason.encode!(scope)) <> ".json"), identity: identity}
      read(checkpoint)
    else
      _ -> {:error, :unsafe_thread_checkpoint_root}
    end
  end

  defp read(%{path: path, identity: identity} = checkpoint) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, checkpoint, nil}

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, bytes} <- File.read(path),
             {:ok, %{"identity" => ^identity, "thread_id" => thread_id}} <- Jason.decode(bytes),
             true <- is_binary(thread_id) and thread_id != "" do
          {:ok, checkpoint, thread_id}
        else
          _ -> {:error, :invalid_thread_checkpoint}
        end

      _ ->
        {:error, :invalid_thread_checkpoint}
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

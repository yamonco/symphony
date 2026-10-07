defmodule SymphonyElixir.SessionCheckpointTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.SessionCheckpoint

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-checkpoint-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/CARD")
    store = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_resume_state_root: store)
    {:ok, root: root, workspace: workspace, store: store, issue: %Issue{id: "CARD", native_ref: %{"execution_generation" => 1}}}
  end

  test "durable identity resumes only the same execution and pins", c do
    pins = Path.join(c.workspace, ".fractalops")
    File.mkdir_p!(pins)
    File.write!(Path.join(pins, "profile-pin.json"), "profile-1")
    assert {:ok, checkpoint, nil} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    assert :ok = SessionCheckpoint.save(checkpoint, "thread-1")
    assert {:ok, ^checkpoint, "thread-1"} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    assert Bitwise.band(File.stat!(checkpoint.path).mode, 0o777) == 0o600
    assert {:error, :invalid_thread_checkpoint} = SessionCheckpoint.load(c.workspace, %{c.issue | native_ref: %{"execution_generation" => 2}}, nil)
    File.write!(Path.join(pins, "profile-pin.json"), "profile-2")
    assert {:error, :invalid_thread_checkpoint} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    assert {:ok, other, nil} = SessionCheckpoint.load(c.workspace, %{c.issue | id: "OTHER"}, nil)
    refute other.path == checkpoint.path
  end

  test "disabled checkpoints preserve existing local and remote behavior", c do
    write_workflow_file!(Workflow.workflow_file_path())
    assert {:ok, nil, nil} = SessionCheckpoint.load(c.workspace, nil, nil)
    assert {:ok, nil, nil} = SessionCheckpoint.load(c.workspace, nil, "host")
    assert :ok = SessionCheckpoint.save(nil, "thread")
  end

  test "enabled checkpoints require issue and reject remote worker", c do
    assert {:error, :thread_checkpoint_issue_required} = SessionCheckpoint.load(c.workspace, nil, nil)
    assert {:error, :remote_thread_checkpoint_unsupported} = SessionCheckpoint.load(c.workspace, c.issue, "host")
  end

  test "root inside workspace tree and symlink root denied", c do
    for store <- [Path.dirname(c.workspace), Path.join(c.workspace, "sessions")] do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(c.workspace),
        codex_resume_state_root: store
      )

      assert {:error, :unsafe_thread_checkpoint_root} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    end

    File.mkdir_p!(c.store)
    link = Path.join(c.root, "link")
    File.ln_s!(c.store, link)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(c.workspace),
      codex_resume_state_root: link
    )

    assert {:error, :unsafe_thread_checkpoint_root} = SessionCheckpoint.load(c.workspace, c.issue, nil)
  end

  test "invalid root and checkpoint files fail closed", c do
    File.write!(c.store, "file")
    assert {:error, :unsafe_thread_checkpoint_root} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    File.rm!(c.store)
    assert {:ok, checkpoint, nil} = SessionCheckpoint.load(c.workspace, c.issue, nil)

    for bytes <- ["not-json", "{}", Jason.encode!(%{"identity" => checkpoint.identity, "thread_id" => ""})] do
      File.write!(checkpoint.path, bytes)
      assert {:error, :invalid_thread_checkpoint} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    end

    File.rm!(checkpoint.path)
    File.mkdir_p!(checkpoint.path)
    assert {:error, :invalid_thread_checkpoint} = SessionCheckpoint.load(c.workspace, c.issue, nil)
    assert {:error, {:thread_checkpoint_write_failed, _}} = SessionCheckpoint.save(checkpoint, "thread")
    File.rmdir!(checkpoint.path)
    File.ln_s!("/etc/passwd", checkpoint.path)
    assert {:error, :invalid_thread_checkpoint} = SessionCheckpoint.load(c.workspace, c.issue, nil)
  end

  test "real app-server transport starts then resumes across separate processes", c do
    script = Path.join(c.root, "fake-codex")
    trace = Path.join(c.root, "requests.jsonl")

    File.write!(script, """
    #!/usr/bin/env python3
    import json,sys
    for line in sys.stdin:
      p=json.loads(line)
      with open(#{inspect(trace)}, 'a') as f: f.write(json.dumps(p)+'\\n')
      if p.get('method')=='initialize': print(json.dumps({'id':1,'result':{}}),flush=True)
      if p.get('method') in ['thread/start','thread/resume']:
        print(json.dumps({'id':2,'result':{'thread':{'id':'thread-durable'}}}),flush=True)
      if p.get('method')=='turn/start':
        print(json.dumps({'id':3,'result':{'turn':{'id':'turn-1'}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{}}),flush=True)
    """)

    File.chmod!(script, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(c.workspace),
      codex_resume_state_root: c.store,
      codex_command: script
    )

    assert {:ok, first} = AppServer.start_session(c.workspace, issue: c.issue)
    assert {:ok, _} = AppServer.run_turn(first, "bounded test", c.issue)
    AppServer.stop_session(first)
    assert {:ok, second} = AppServer.start_session(c.workspace, issue: c.issue)
    assert first.thread_id == second.thread_id
    AppServer.stop_session(second)
    requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [start, resume] = Enum.filter(requests, &(&1["id"] == 2))
    assert start["method"] == "thread/start"
    assert resume["method"] == "thread/resume"
    assert resume["params"]["threadId"] == "thread-durable"
    refute Map.has_key?(resume["params"], "dynamicTools")
  end
end

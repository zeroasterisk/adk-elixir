defmodule ADK.Workflow.Executor do
  @moduledoc """
  Graph traversal and execution engine for workflows.

  Traverses the DAG defined by `ADK.Workflow.Graph`, executing agent nodes and
  routing based on context/events. Supports sequential traversal, parallel
  fan-out with join, conditional routing, and checkpointing.

  ## Execution Model

  1. Find `:START` edges → resolve initial nodes
  2. Execute each node (agent or function)
  3. Collect events, determine next nodes via edges
  4. For fan-out: run parallel branches with `Task.async_stream`
  5. For join: wait for all predecessors to complete
  6. Checkpoint after each node completion
  7. Terminate when `:END` is reached or no more nodes

  ## Telemetry

  Emits `[:adk, :workflow, *]` telemetry events for FlowLive integration:
  - `[:adk, :workflow, :start]` — workflow execution begins
  - `[:adk, :workflow, :node, :start]` — node execution begins
  - `[:adk, :workflow, :node, :stop]` — node execution completes
  - `[:adk, :workflow, :stop]` — workflow execution completes
  """

  alias ADK.Workflow.{Graph, Collaboration, Checkpoint}

  @type run_opts :: [
          checkpoint_store: module(),
          collaboration: Collaboration.mode(),
          timeout: pos_integer(),
          node_timeout: pos_integer(),
          resume_id: String.t() | nil
        ]

  @doc """
  Execute a workflow graph.

  ## Options

  - `:checkpoint_store` — checkpoint backend (default: `Checkpoint.EtsStore`)
  - `:collaboration` — collaboration mode for fan-in (default: `:pipeline`)
  - `:timeout` — global timeout in ms (default: 300_000)
  - `:node_timeout` — per-node timeout in ms (default: 60_000)
  - `:resume_id` — workflow ID to resume from checkpoints
  """
  @spec run(Graph.t(), ADK.Context.t(), run_opts()) :: [ADK.Event.t()]
  def run(%Graph{} = graph, %ADK.Context{} = ctx, opts \\ []) do
    store = Keyword.get(opts, :checkpoint_store, Checkpoint.EtsStore)
    collab_mode = Keyword.get(opts, :collaboration, :pipeline)
    node_timeout = Keyword.get(opts, :node_timeout, 60_000)
    workflow_id = Keyword.get(opts, :resume_id) || generate_id()

    # Get already-completed nodes if resuming
    completed = if opts[:resume_id], do: store.completed_nodes(workflow_id), else: []
    completed_set = MapSet.new(completed)

    # Initialize checkpoint store before any parallel tasks
    if function_exported?(store, :init, 0), do: store.init()

    emit_telemetry(:start, %{workflow_id: workflow_id, graph: graph})

    # Find START successors
    start_nodes = Graph.successors(graph, :START)

    # Execute the graph
    events =
      execute_nodes(
        start_nodes,
        graph,
        ctx,
        %{
          store: store,
          workflow_id: workflow_id,
          collab_mode: collab_mode,
          node_timeout: node_timeout,
          completed: completed_set,
          visited: MapSet.new(),
          join_results: %{},
          history: []
        }
      )

    emit_telemetry(:stop, %{workflow_id: workflow_id, event_count: length(events)})

    events
  end

  # ── Core Execution ──

  defp execute_nodes([], _graph, _ctx, _state), do: []

  defp execute_nodes(node_ids, graph, ctx, state) do
    # Filter out already-completed nodes (for resume)
    to_run = Enum.reject(node_ids, &MapSet.member?(state.completed, &1))

    # Detect if this is a fan-out (multiple nodes to run in parallel)
    case to_run do
      [] ->
        # All nodes already completed, proceed to successors
        proceed_from_completed(node_ids, graph, ctx, state)

      [:END] ->
        []

      [single] ->
        execute_single(single, graph, ctx, state)

      multiple ->
        execute_parallel(multiple, graph, ctx, state)
    end
  end

  defp execute_single(:END, _graph, _ctx, _state), do: []

  defp execute_single(node_id, graph, ctx, state) do
    # Guard against infinite loops
    if MapSet.member?(state.visited, node_id) do
      []
    else
      # Check if this is a join point
      preds = Graph.predecessors(graph, node_id)

      if length(preds) > 1 do
        # Join node — check if all predecessors completed
        completed_preds =
          Enum.filter(preds, fn p ->
            MapSet.member?(state.completed, p) or p == :START
          end)

        if length(completed_preds) < length(preds) do
          # Not all predecessors done — store partial results and wait
          []
        else
          # All predecessors done — execute with collaboration
          do_execute_node(node_id, graph, ctx, state)
        end
      else
        do_execute_node(node_id, graph, ctx, state)
      end
    end
  end

  defp execute_parallel(node_ids, graph, ctx, state) do
    results =
      node_ids
      |> Task.async_stream(
        fn node_id ->
          {node_id, execute_single(node_id, graph, ctx, state)}
        end,
        timeout: state.node_timeout,
        ordered: true
      )
      |> Enum.flat_map(fn
        {:ok, {_node_id, events}} ->
          events

        {:exit, reason} ->
          [ADK.Event.new(author: "workflow", content: "Parallel node failed: #{inspect(reason)}")]
      end)

    results
  end

  defp do_execute_node(node_id, graph, ctx, state) do
    node_def = Map.get(graph.nodes, node_id, node_id)

    emit_telemetry([:node, :start], %{
      workflow_id: state.workflow_id,
      node_id: node_id
    })

    {status, events, output} = run_node(node_def, node_id, ctx)

    status =
      if status == :ok do
        validate_output(node_def, output, ctx)
      else
        status
      end

    if status == :ok do
      state.store.save(state.workflow_id, node_id, :completed, output)

      emit_telemetry([:node, :stop], %{
        workflow_id: state.workflow_id,
        node_id: node_id,
        event_count: length(events)
      })

      new_state = %{
        state
        | completed: MapSet.put(state.completed, node_id),
          visited: MapSet.put(state.visited, node_id),
          history: [node_id | state.history]
      }

      next_events =
        case Graph.outgoing(graph, node_id) do
          :none ->
            []

          {:unconditional, targets} ->
            execute_nodes(targets, graph, ctx, new_state)

          {:conditional, routes} ->
            route_key = extract_route(events, output)

            case Map.get(routes, route_key) do
              nil ->
                case Map.get(routes, "default") || Map.get(routes, :default) do
                  nil -> []
                  default_target -> execute_nodes([default_target], graph, ctx, new_state)
                end

              target ->
                execute_nodes([target], graph, ctx, new_state)
            end
        end

      events ++ next_events
    else
      state.store.save(state.workflow_id, node_id, :failed, output)

      emit_telemetry([:node, :fail], %{
        workflow_id: state.workflow_id,
        node_id: node_id,
        reason: status
      })

      compensation_events = rollback(state.history, status, graph, ctx)

      events ++
        compensation_events ++
        [
          ADK.Event.error("Workflow failed at node #{node_id}: #{inspect(status)}",
            author: "workflow"
          )
        ]
    end
  end

  defp rollback([], _reason, _graph, _ctx), do: []

  defp rollback([node_id | rest], reason, graph, ctx) do
    node_def = Map.get(graph.nodes, node_id)

    events =
      case node_def do
        %ADK.Workflow.Step{compensate: comp} when is_function(comp) ->
          invoke_compensate(comp, node_id, reason, ctx)

        _ ->
          []
      end

    events ++ rollback(rest, reason, graph, ctx)
  end

  defp invoke_compensate(comp, node_id, reason, ctx) do
    result =
      case :erlang.fun_info(comp, :arity) do
        {:arity, 1} -> comp.(ctx)
        {:arity, 2} -> comp.(node_id, ctx)
        {:arity, 3} -> comp.(node_id, reason, ctx)
        _ -> comp.(ctx)
      end

    wrap_events(result, :"#{node_id}_compensate")
  end

  # ── Node Execution ──

  defp run_node(%ADK.Workflow.Step{} = step, node_id, ctx) do
    result =
      if is_function(step.run, 2) do
        step.run.(node_id, ctx)
      else
        step.run.(ctx)
      end

    status =
      case result do
        {:error, _} = err -> err
        {:halt, reason} -> {:error, reason}
        _ -> :ok
      end

    events = wrap_events(result, node_id)
    output = extract_output(events)
    {status, events, output}
  end

  defp run_node(node_def, node_id, ctx) when is_function(node_def, 1) do
    result = node_def.(ctx)

    status =
      case result do
        {:error, _} = err -> err
        {:halt, reason} -> {:error, reason}
        _ -> :ok
      end

    events = wrap_events(result, node_id)
    output = extract_output(events)
    {status, events, output}
  end

  defp run_node(node_def, node_id, _ctx) when is_function(node_def, 0) do
    result = node_def.()

    status =
      case result do
        {:error, _} = err -> err
        {:halt, reason} -> {:error, reason}
        _ -> :ok
      end

    events = wrap_events(result, node_id)
    output = extract_output(events)
    {status, events, output}
  end

  defp run_node(node_def, _node_id, ctx) do
    if ADK.Agent.impl_for(node_def) do
      child_ctx = ADK.Context.for_child(ctx, node_def)
      events = ADK.Agent.run(node_def, child_ctx)
      output = extract_output(events)

      status =
        if Enum.any?(events, &(&1.custom_metadata && &1.custom_metadata[:error])),
          do: {:error, :agent_error},
          else: :ok

      {status, events, output}
    else
      event = ADK.Event.error("Unknown node type: #{inspect(node_def)}", author: "workflow")
      {{:error, :unknown_node_type}, [event], nil}
    end
  end

  # ── Validation ──

  defp validate_output(%ADK.Workflow.Step{validate: val}, output, ctx) when is_function(val) do
    case :erlang.fun_info(val, :arity) do
      {:arity, 1} -> val.(output)
      {:arity, 2} -> val.(output, ctx)
      _ -> :ok
    end
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:validation_failed, reason}}
      false -> {:error, :validation_failed}
      true -> :ok
      _ -> :ok
    end
  end

  defp validate_output(_node_def, _output, _ctx), do: :ok

  # ── Helpers ──

  defp proceed_from_completed(node_ids, graph, ctx, state) do
    node_ids
    |> Enum.flat_map(fn node_id ->
      new_state = %{state | visited: MapSet.put(state.visited, node_id)}

      case Graph.outgoing(graph, node_id) do
        :none -> []
        {:unconditional, targets} -> execute_nodes(targets, graph, ctx, new_state)
        # Can't route without re-executing
        {:conditional, _routes} -> []
      end
    end)
  end

  defp wrap_events(result, _node_id) when is_list(result), do: result

  defp wrap_events(%ADK.Event{} = event, _node_id), do: [event]

  defp wrap_events(result, node_id) when is_binary(result) do
    [ADK.Event.new(author: to_string(node_id), content: %{"parts" => [%{"text" => result}]})]
  end

  defp wrap_events(nil, _node_id), do: []

  defp wrap_events(result, node_id) do
    [
      ADK.Event.new(
        author: to_string(node_id),
        content: %{"parts" => [%{"text" => inspect(result)}]}
      )
    ]
  end

  defp extract_output(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&ADK.Event.text/1)
  end

  defp extract_route(events, output) do
    # Check events for route metadata
    route_from_events =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        cond do
          is_map(event.custom_metadata) && Map.has_key?(event.custom_metadata, "route") ->
            event.custom_metadata["route"]

          is_map(event.custom_metadata) && Map.has_key?(event.custom_metadata, :route) ->
            event.custom_metadata[:route]

          true ->
            nil
        end
      end)

    route_from_events || output
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_telemetry(event_name, metadata) when is_atom(event_name) do
    emit_telemetry([event_name], metadata)
  end

  defp emit_telemetry(event_suffix, metadata) when is_list(event_suffix) do
    if function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute([:adk, :workflow | event_suffix], %{}, metadata)
    end
  rescue
    _ -> :ok
  end
end

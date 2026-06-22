defmodule Cardamom.Introspect do
  @moduledoc """
  Read-only BEAM introspection, served over HTTP so the live node can be watched
  from a browser — including on a headless box (AWS, a garage server) where the
  `:observer` desktop GUI is impractical.

  This is the same public introspection `:observer` itself uses
  (`Process.info/2`, `:erlang.memory/0`, `Supervisor.which_children/1`,
  `:ets.info/2`), gathered into JSON-friendly snapshots. We expose the cheap
  read-only *snapshots* — NOT observer's interactive tracing/charting (expensive,
  and tracing can hurt a running system).

  STRICTLY READ-ONLY (architecture.md "the UI is a READ-ONLY observer"):
  introspection only, never control. No "kill this process" / "start a trace"
  here — that would cross from observing to driving the node.
  """

  @doc "VM-wide summary (the `:observer` System tab, distilled)."
  @spec system() :: map()
  def system do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      memory_total_bytes: :erlang.memory(:total),
      memory_processes_bytes: :erlang.memory(:processes),
      memory_ets_bytes: :erlang.memory(:ets),
      memory_binary_bytes: :erlang.memory(:binary),
      run_queue: :erlang.statistics(:run_queue),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  @doc """
  Top `limit` processes by mailbox length (so a backing-up mailbox surfaces
  first), each with the health fields the `:observer` Processes tab shows.
  """
  @spec processes(pos_integer()) :: [map()]
  def processes(limit \\ 20) do
    Process.list()
    |> Enum.map(&process_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.message_queue_len, :desc)
    |> Enum.take(limit)
  end

  defp process_info(pid) do
    case Process.info(pid, [
           :registered_name,
           :message_queue_len,
           :memory,
           :reductions,
           :current_function
         ]) do
      nil ->
        nil

      info ->
        %{
          pid: inspect(pid),
          name: name_of(info[:registered_name]),
          message_queue_len: info[:message_queue_len],
          memory_bytes: info[:memory],
          reductions: info[:reductions],
          current_function: mfa(info[:current_function])
        }
    end
  end

  defp name_of([]), do: nil
  defp name_of(name) when is_atom(name), do: inspect(name)
  defp name_of(_), do: nil

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: nil

  # Maintained negative-filter list. NEGATIVE = default-visible: a child is shown
  # unless its label matches a pattern here. New processes appear by default
  # (useful while developing — you see things get added); mute noise by adding a
  # pattern. Patterns may be a Regex or a plain string (matched as a substring).
  @default_hidden [
    # Bandit's HTTP acceptor pool — ~100 identical subtrees that bury our own
    # structure. Hidden by default; remove this to see them.
    ~r/^"acceptor-\d+"$/
  ]

  @doc "The maintained list of hide patterns (negative filter)."
  @spec default_hidden() :: [Regex.t() | String.t()]
  def default_hidden, do: @default_hidden

  @doc """
  Walk a supervision tree (default: the Cardamom top supervisor) into a nested
  map of `%{name, type, children}` — the `:observer` Applications tab view.

  `hide` is a negative filter (default-visible): children whose label matches any
  pattern (Regex or substring String) are omitted. Defaults to `default_hidden/0`.
  """
  @spec tree(Supervisor.supervisor(), [Regex.t() | String.t()]) :: map()
  def tree(supervisor \\ Cardamom.Supervisor, hide \\ @default_hidden) do
    walk(supervisor, :supervisor, "#{inspect(supervisor)}", hide)
  end

  @doc "Whether `label` matches any pattern in `hide` (Regex or substring)."
  @spec hidden?(String.t(), [Regex.t() | String.t()]) :: boolean()
  def hidden?(label, hide) do
    Enum.any?(hide, fn
      %Regex{} = re -> Regex.match?(re, label)
      str when is_binary(str) -> String.contains?(label, str)
    end)
  end

  defp walk(pid_or_name, type, label, hide) do
    # Only supervisors answer which_children; never call it on a worker.
    children =
      if type == :supervisor do
        case safe_which_children(pid_or_name) do
          {:ok, kids} ->
            for {id, child, child_type, _modules} <- kids,
                is_pid(child),
                child_label = child_id_label(id),
                not hidden?(child_label, hide) do
              walk(child, child_type, child_label, hide)
            end

          :error ->
            []
        end
      else
        []
      end

    %{name: label, type: type, children: children}
  end

  defp safe_which_children(pid_or_name) do
    {:ok, Supervisor.which_children(pid_or_name)}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp child_id_label(id) when is_atom(id), do: inspect(id)
  defp child_id_label(id), do: inspect(id)
end

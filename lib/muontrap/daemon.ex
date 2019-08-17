defmodule MuonTrap.Daemon do
  use GenServer

  require Logger

  @moduledoc """
  Wrap an OS process in a GenServer so that it can be supervised.

  For example, in your children list add MuonTrap.Daemon like this:

  ```elixir
  children = [
    {MuonTrap.Daemon, ["my_server", ["--options", "foo")], [id: :my_daemon, cd: "/some_directory"]]}
  ]

  opts = [strategy: :one_for_one, name: MyApplication.Supervisor]
  Supervisor.start_link(children, opts)
  ```

  In the `child_spec` tuple, the second element is a list that corresponds to
  the `MuonTrap.cmd/3` parameters. I.e., The first item in the list is the
  program to run, the second is a list of commandline arguments, and the third
  is a list of options. The same options as `MuonTrap.cmd/3` are available with
  the following additions:

  * `:name` - Name the Daemon GenServer
  * `:log_output` - When set, send output from the command to the Logger. Specify the log level (e.g., `:debug`)
  * `:stderr_to_stdout` - When set to `true`, redirect stderr to stdout. Defaults to `false`.
  """

  defmodule State do
    @moduledoc false

    defstruct [:command, :port, :cgroup_path, :log_output]
  end

  def child_spec([command, args]) do
    child_spec([command, args, []])
  end

  def child_spec([command, args, opts]) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [command, args, opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Start/link a deamon GenServer for the specified command.
  """
  @spec start_link(binary(), [binary()], keyword()) :: GenServer.on_start()
  def start_link(command, args, opts \\ []) do
    {genserver_opts, opts} =
      case Keyword.pop(opts, :name) do
        {nil, _opts} -> {[], opts}
        {name, new_opts} -> {[name: name], new_opts}
      end

    GenServer.start_link(__MODULE__, [command, args, opts], genserver_opts)
  end

  @doc """
  Get the value of the specified cgroup variable.
  """
  @spec cgget(GenServer.server(), binary(), binary()) :: binary()
  def cgget(server, controller, variable_name) do
    GenServer.call(server, {:cgget, controller, variable_name})
  end

  @doc """
  Modify a cgroup variable.
  """
  @spec cgset(GenServer.server(), binary(), binary(), binary()) :: :ok | no_return()
  def cgset(server, controller, variable_name, value) do
    GenServer.call(server, {:cgset, controller, variable_name, value})
  end

  @doc """
  Return the OS pid to the muontrap executable.
  """
  @spec os_pid(GenServer.server()) :: non_neg_integer()
  def os_pid(server) do
    GenServer.call(server, :os_pid)
  end

  @impl true
  def init([command, args, opts]) do
    options = MuonTrap.Options.validate(:daemon, command, args, opts)
    port_options = MuonTrap.Port.port_options(options) ++ [{:line, 256}]

    port = Port.open({:spawn_executable, to_charlist(MuonTrap.muontrap_path())}, port_options)

    {:ok,
     %State{
       command: command,
       port: port,
       cgroup_path: Map.get(options, :cgroup_path),
       log_output: Map.get(options, :log_output)
     }}
  end

  @impl true
  def handle_call({:cgget, controller, variable_name}, _from, state) do
    result =
      System.cmd("cat", ["/sys/fs/cgroups/#{controller}/#{state.cgroup_path}/#{variable_name}"])

    {:reply, result, state}
  end

  @impl true
  def handle_call({:cgset, controller, variable_name, value}, _from, state) do
    result =
      File.write!("/sys/fs/cgroups/#{controller}/#{state.cgroup_path}/#{variable_name}", value)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:os_pid, os_pid} = Port.info(state.port, :os_pid)
    {:reply, os_pid, state}
  end

  @impl true
  def handle_info({_port, {:data, _}}, %State{log_output: nil} = state) do
    # Ignore output
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {_, message}}},
        %State{port: port, log_output: log_level} = state
      ) do
    _ = Logger.log(log_level, "#{state.command}: #{message}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    reason =
      case status do
        0 ->
          _ = Logger.info("#{state.command}: Process exited successfully")
          :normal

        _failure ->
          _ = Logger.error("#{state.command}: Process exited with status #{status}")
          :error_exit_status
      end

    {:stop, reason, state}
  end
end

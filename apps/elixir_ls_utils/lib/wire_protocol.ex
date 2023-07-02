defmodule ElixirLS.Utils.WireProtocol do
  @moduledoc """
  Reads and writes packets using the Language Server Protocol's wire protocol
  """
  alias ElixirLS.Utils.{PacketStream, OutputDevice}

  @debug_io Application.compile_env(:elixir_ls_utils, :debug_io, false)

  @separator "\r\n\r\n"

  def send(packet) do
    pid = io_dest()
    body = JasonV.encode_to_iodata!(packet)
    body = [body | @separator]

    iodata = [
      "Content-Length: ",
      IO.iodata_length(body) |> Integer.to_string(),
      @separator,
      body
    ]

    if @debug_io do
      File.write!("out.txt", iodata, [:binary, {:encoding, :latin1}, :write, :append])
    end

    IO.binwrite(pid, iodata)
  end

  defp io_dest do
    Process.whereis(:raw_user) || Process.group_leader()
  end

  def io_user_intercepted? do
    !!Process.whereis(:raw_user)
  end

  def io_error_intercepted? do
    !!Process.whereis(:raw_standard_error)
  end

  def intercept_output(print_fn, print_err_fn, intercept_error \\ false) do
    raw_user = Process.whereis(:user)
    raw_standard_error = Process.whereis(:standard_error)

    :ok = :io.setopts(raw_user, binary: true, encoding: :latin1)

    {:ok, intercepted_user} = OutputDevice.start_link(raw_user, print_fn)

    Process.unregister(:user)
    Process.register(raw_user, :raw_user)
    Process.register(intercepted_user, :user)

    if intercept_error do
      {:ok, intercepted_standard_error} = OutputDevice.start_link(raw_user, print_err_fn)
      Process.unregister(:standard_error)
      Process.register(raw_standard_error, :raw_standard_error)
      Process.register(intercepted_standard_error, :standard_error)
    end

    [_init_process | non_init_processes] = :erlang.processes()

    for process <- non_init_processes,
        process not in [
          raw_user,
          raw_standard_error,
          intercepted_user,
          intercepted_standard_error
        ] do
      Process.group_leader(process, intercepted_user)
    end
  end

  def undo_intercept_output() do
    raw_user = if io_user_intercepted? do
      intercepted_user = Process.whereis(:user)

      Process.unregister(:user)

      raw_user =
        try do
          raw_user = Process.whereis(:raw_user)
          Process.unregister(:raw_user)
          Process.register(raw_user, :user)
          raw_user
        rescue
          ArgumentError -> nil
        end

      Process.unlink(intercepted_user)
      Process.exit(intercepted_user, :kill)

      raw_user
    end

    raw_standard_error = if io_error_intercepted? do
      intercepted_standard_error = Process.whereis(:standard_error)
      Process.unregister(:standard_error)

      raw_standard_error =
        try do
          raw_standard_error = Process.whereis(:raw_standard_error)
          Process.unregister(:raw_standard_error)
          Process.register(raw_standard_error, :standard_error)
          raw_user
        rescue
          ArgumentError -> nil
        end

      Process.unlink(intercepted_standard_error)
      Process.exit(intercepted_standard_error, :kill)

      raw_standard_error
    end

    [init_process | non_init_processes] = :erlang.processes()

    if raw_user do
      for process <- non_init_processes,
          process not in [
            raw_user,
            raw_standard_error
          ] do
        Process.group_leader(process, raw_user)
      end
    else
      for process <- non_init_processes,
          process not in [raw_standard_error] do
        Process.group_leader(process, init_process)
      end
    end
  end

  def stream_packets(receive_packets_fn) do
    PacketStream.stream(Process.whereis(:raw_user), true)
    |> Stream.each(fn packet -> receive_packets_fn.(packet) end)
    |> Stream.run()
  end
end

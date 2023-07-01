path = System.find_executable("erl")
Port.open({:spawn_executable, path}, [:binary, {:args, ["-noshell", "-kernel", "standard_io_encoding", "latin1", "-eval", "io:setopts(standard_io, [{encoding, latin1}]), io:format('duπa~n', []), erlang:halt()"]}, :exit_status])
receive do
  {_, {:data, a}} -> IO.inspect([:s] ++ String.to_charlist(a))
after
  2000 -> IO.puts "nothing"
end

Port.open({:spawn_executable, path}, [:binary, {:args, ["-noshell", "-kernel", "standard_io_encoding", "latin1", "-eval", "io:format('teπt~n', []), erlang:halt()"]}, :exit_status])
receive do
  {_, {:data, a}} -> IO.inspect([:s] ++ String.to_charlist(a))
after
  2000 -> IO.puts "nothing"
end

Process.sleep(2000)

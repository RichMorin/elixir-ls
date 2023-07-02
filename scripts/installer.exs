defmodule ElixirLS.Shell.Quiet do
  @moduledoc false

  @behaviour Mix.Shell

  @impl true
  def print_app() do
    if name = Mix.Shell.printable_app_name() do
      IO.puts(:stderr, "==> #{name}")
    end

    :ok
  end

  @impl true
  def info(message) do
    print_app()
    IO.puts(:stderr, IO.ANSI.format(message))
  end

  @impl true
  def error(message) do
    print_app()
    IO.puts(:stderr, IO.ANSI.format(message))
  end

  @impl true
  def prompt(message) do
    print_app()
    IO.puts(:stderr, IO.ANSI.format(message))
    raise "Mix.Shell.prompt is not supported at this time"
  end

  @impl true
  def yes?(message, options \\ []) do
    default = Keyword.get(options, :default, :yes)

    unless default in [:yes, :no] do
      raise ArgumentError,
            "expected :default to be either :yes or :no, got: #{inspect(default)}"
    end

    IO.puts(:stderr, IO.ANSI.format(message))

    default == :yes
  end

  @impl true
  def cmd(command, opts \\ []) do
    print_app? = Keyword.get(opts, :print_app, true)

    Mix.Shell.cmd(command, opts, fn data ->
      if print_app?, do: print_app()
      IO.write(:stderr, data)
    end)
  end
end

defmodule ElixirLS.Mix do
  # This module is based on code from elixir project
  # https://github.com/elixir-lang/elixir/blob/v1.15.1/lib/mix/lib/mix.ex#L759 and has modified version
  # of Mix.install which does not stop Hex after install and does not start apps
  @mix_install_project Mix.InstallProject

  def install(deps, opts \\ [])

  def install(deps, opts) when is_list(deps) and is_list(opts) do
    Mix.start()

    if Mix.Project.get() do
      Mix.raise("Mix.install/2 cannot be used inside a Mix project")
    end

    elixir_requirement = opts[:elixir]
    elixir_version = System.version()

    if !!elixir_requirement and not Version.match?(elixir_version, elixir_requirement) do
      Mix.raise(
        "Mix.install/2 declared it supports only Elixir #{elixir_requirement} " <>
          "but you're running on Elixir #{elixir_version}"
      )
    end

    deps =
      Enum.map(deps, fn
        dep when is_atom(dep) ->
          {dep, ">= 0.0.0"}

        {app, opts} when is_atom(app) and is_list(opts) ->
          {app, maybe_expand_path_dep(opts)}

        {app, requirement, opts} when is_atom(app) and is_binary(requirement) and is_list(opts) ->
          {app, requirement, maybe_expand_path_dep(opts)}

        other ->
          other
      end)

    config = Keyword.get(opts, :config, [])
    config_path = expand_path(opts[:config_path], deps, :config_path, "config/config.exs")
    system_env = Keyword.get(opts, :system_env, [])
    consolidate_protocols? = Keyword.get(opts, :consolidate_protocols, true)

    id =
      {deps, config, system_env, consolidate_protocols?}
      |> :erlang.term_to_binary()
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    force? = System.get_env("MIX_INSTALL_FORCE") in ["1", "true"] or !!opts[:force]

    case Mix.State.get(:installed) do
      nil ->
        Application.put_all_env(config, persistent: true)
        System.put_env(system_env)

        install_dir = install_dir(id)

        if opts[:verbose] do
          Mix.shell().info("Mix.install/2 using #{install_dir}")
        end

        if force? do
          File.rm_rf!(install_dir)
        end

        config = [
          version: "0.1.0",
          build_embedded: false,
          build_per_environment: true,
          build_path: "_build",
          lockfile: "mix.lock",
          deps_path: "deps",
          deps: deps,
          app: :mix_install,
          erlc_paths: [],
          elixirc_paths: [],
          compilers: [],
          consolidate_protocols: consolidate_protocols?,
          config_path: config_path,
          prune_code_paths: false
        ]

        started_apps = Application.started_applications()
        :ok = Mix.ProjectStack.push(@mix_install_project, config, "nofile")
        build_dir = Path.join(install_dir, "_build")
        external_lockfile = expand_path(opts[:lockfile], deps, :lockfile, "mix.lock")

        try do
          first_build? = not File.dir?(build_dir)
          File.mkdir_p!(install_dir)

          File.cd!(install_dir, fn ->
            if config_path do
              Mix.Task.rerun("loadconfig")
            end

            cond do
              external_lockfile ->
                md5_path = Path.join(install_dir, "merge.lock.md5")

                old_md5 =
                  case File.read(md5_path) do
                    {:ok, data} -> Base.decode64!(data)
                    _ -> nil
                  end

                new_md5 = external_lockfile |> File.read!() |> :erlang.md5()

                if old_md5 != new_md5 do
                  lockfile = Path.join(install_dir, "mix.lock")
                  old_lock = Mix.Dep.Lock.read(lockfile)
                  new_lock = Mix.Dep.Lock.read(external_lockfile)
                  Mix.Dep.Lock.write(Map.merge(old_lock, new_lock), file: lockfile)
                  File.write!(md5_path, Base.encode64(new_md5))
                  Mix.Task.rerun("deps.get")
                end

              first_build? ->
                Mix.Task.rerun("deps.get")

              true ->
                # We already have a cache. If the user by any chance uninstalled Hex,
                # we make sure it is installed back (which mix deps.get would do anyway)
                Mix.Hex.ensure_installed?(true)
                :ok
            end

            Mix.Task.rerun("deps.loadpaths")

            # # Hex and SSL can use a good amount of memory after the registry fetching,
            # # so we stop any app started during deps resolution.
            # stop_apps(Application.started_applications() -- started_apps)

            Mix.Task.rerun("compile")

            if config_path do
              Mix.Task.rerun("app.config")
            end
          end)

          # for %{app: app, opts: opts} <- Mix.Dep.cached(),
          #     Keyword.get(opts, :runtime, true) and Keyword.get(opts, :app, true) do
          #   Application.ensure_all_started(app)
          # end

          Mix.State.put(:installed, id)
          :ok
        after
          Mix.ProjectStack.pop()
        end

      ^id when not force? ->
        :ok

      _ ->
        Mix.raise("Mix.install/2 can only be called with the same dependencies in the given VM")
    end
  end

  defp expand_path(_path = nil, _deps, _key, _), do: nil
  defp expand_path(path, _deps, _key, _) when is_binary(path), do: Path.expand(path)

  defp expand_path(app_name, deps, key, relative_path) when is_atom(app_name) do
    app_dir =
      case List.keyfind(deps, app_name, 0) do
        {_, _, opts} when is_list(opts) -> opts[:path]
        {_, opts} when is_list(opts) -> opts[:path]
        _ -> Mix.raise("unknown dependency #{inspect(app_name)} given to #{inspect(key)}")
      end

    unless app_dir do
      Mix.raise("#{inspect(app_name)} given to #{inspect(key)} must be a path dependency")
    end

    Path.join(app_dir, relative_path)
  end

  defp install_dir(cache_id) do
    install_root =
      System.get_env("MIX_INSTALL_DIR") ||
        Path.join(Mix.Utils.mix_cache(), "installs")

    version = "elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
    Path.join([install_root, version, cache_id])
  end

  defp maybe_expand_path_dep(opts) do
    if Keyword.has_key?(opts, :path) do
      Keyword.update!(opts, :path, &Path.expand/1)
    else
      opts
    end
  end
end

defmodule ElixirLS.Installer do
  defp local_dir, do: Path.expand("#{__DIR__}/..")

  defp run_mix_install({:local, dir}, force?) do
    ElixirLS.Mix.install(
      [
        {:elixir_ls, path: dir},
      ],
      force: force?,
      consolidate_protocols: false,
      config_path: Path.join(dir, "config/config.exs"),
      lockfile: Path.join(dir, "mix.lock")
    )
  end

  defp run_mix_install({:tag, tag}, force?) do
    ElixirLS.Mix.install([
        {:elixir_ls, github: "elixir-lsp/elixir-ls", tag: tag}
      ],
      force: force?,
      consolidate_protocols: false
    )
  end

  defp local? do
    System.get_env("ELS_LOCAL") == "1"
  end

  defp get_release do
    version = Path.expand("#{__DIR__}/VERSION")
    |> File.read!()
    |> String.trim()
    {:tag, "v#{version}"}
  end

  def install(force?) do
    if local?() do
      dir = local_dir()
      IO.puts(:stderr, "Installing local ElixirLS from #{dir}")
      IO.puts(:stderr, "Running in #{File.cwd!}")

      run_mix_install({:local, dir}, force?)
    else
      {:tag, tag} = get_release()
      IO.puts(:stderr, "Installing ElixirLS release #{tag}")
      IO.puts(:stderr, "Running in #{File.cwd!}")

      run_mix_install({:tag, tag}, force?)
    end
    IO.puts(:stderr, "Install complete")
  end

  def install_for_launch do
    if local?() do
      dir = Path.expand("#{__DIR__}/..")
      run_mix_install({:local, dir}, false)
    else
      run_mix_install(get_release(), false)
    end
  end

  def install_with_retry do
    try do
      install(false)
    catch
      kind, error ->
        IO.puts(:stderr, "Mix.install failed with #{Exception.format(kind, error, __STACKTRACE__)}")
        IO.puts(:stderr, "Retrying Mix.install with force: true")
        install(true)
    end
  end
end

defmodule Igniter.Util.Install do
  @moduledoc """
  Tools for installing packages and running their associated
  installers, if present.

  [!NOTE]
  The functions in this module are not composable, and are primarily meant to
  be used internally and to support building custom tooling on top of Igniter,
  such as [Fireside](https://github.com/ibarakaiev/fireside).
  """

  @doc """
  Installs the provided list of dependencies. `deps` can be either:
  - a string like `"ash,ash_postgres"`
  - a list of strings like `["ash", "ash_postgres", ...]`
  - a list of tuples like `[{:ash, "~> 3.0"}, {:ash_postgres, "~> 2.0"}]`
  """
  def install(deps, argv, igniter \\ Igniter.new(), opts \\ [])

  def install(deps, argv, igniter, opts) when is_binary(deps) do
    deps = String.split(deps, ",")

    install(deps, argv, igniter, opts)
  end

  def install([head | _] = deps, argv, igniter, opts) when is_binary(head) do
    deps =
      Enum.map(deps, fn dep ->
        case determine_dep_type_and_version(dep) do
          {install, requirement} ->
            {install, requirement}

          :error ->
            raise "Could not determine source for requested package #{dep}"
        end
      end)

    install(deps, argv, igniter, opts)
  end

  def install([head | _] = deps, argv, igniter, opts) when is_tuple(head) do
    if Enum.any?(deps, &(elem(&1, 0) == :igniter)) do
      raise ArgumentError,
            "cannot install the igniter package with `mix igniter.install`. Please use `mix igniter.setup` instead."
    end

    global_options =
      Keyword.update!(
        Igniter.Mix.Task.Info.global_options(),
        :switches,
        &Keyword.put(&1, :example, :boolean)
      )

    only =
      argv
      |> OptionParser.parse!(switches: [only: :keep])
      |> elem(0)
      |> Keyword.get_values(:only)
      |> Enum.join(",")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)
      |> case do
        [] -> nil
        value -> value
      end

    if only && Mix.env() not in only do
      raise """
      The `--only` option can only be used when running `mix igniter.install` in an environment
      that matches one of the environments in `--only`. For example:

          MIX_ENV=#{Enum.at(only, 0)} mix igniter.install --only #{Enum.join(only, ",")}
      """
    end

    {igniter, desired_tasks, {options, _}} =
      Igniter.Util.Info.compose_install_and_validate!(
        igniter,
        argv,
        %Igniter.Mix.Task.Info{
          schema: global_options[:switches],
          aliases: [],
          installs: deps
        },
        "igniter.install",
        yes: "--yes" in argv,
        only: only,
        append?: Keyword.get(opts, :append?, false)
      )

    igniter = Igniter.apply_and_fetch_dependencies(igniter, options)

    {available_tasks, available_task_sources} =
      Enum.zip(desired_tasks, Enum.map(desired_tasks, &Mix.Task.get/1))
      |> Enum.filter(fn {_desired_task, source_task} -> source_task end)
      |> Enum.unzip()

    case available_tasks do
      [] ->
        :ok

      [task] ->
        run_installers(
          igniter,
          available_task_sources,
          "The following installer was found and executed: `#{task}`",
          argv,
          options
        )

      tasks ->
        run_installers(
          igniter,
          available_task_sources,
          "The following installers were found and executed: #{Enum.map_join(tasks, ", ", &"`#{&1}`")}",
          argv,
          options
        )
    end

    desired_tasks
    |> Enum.filter(&(&1 not in available_tasks))
    |> Enum.map(&String.trim_trailing(&1, ".install"))
    |> case do
      [] ->
        :ok

      [package] ->
        IO.puts("The package `#{package}` had no associated installer task.")

      packages ->
        IO.puts("The packages `#{Enum.join(packages, ", ")}` had no associated installer task.")
    end
  end

  defp run_installers(igniter, igniter_task_sources, title, argv, options) do
    igniter_task_sources
    |> Enum.reduce(igniter, fn igniter_task_source, igniter ->
      Igniter.compose_task(igniter, igniter_task_source, argv)
    end)
    |> Igniter.do_or_dry_run(Keyword.put(options, :title, title))

    :ok
  end

  defp determine_dep_type_and_version(requirement) do
    case String.split(requirement, "@", trim: true, parts: 2) do
      [package] ->
        if Regex.match?(~r/^[a-z][a-z0-9_]*$/, package) do
          :inets.start()
          :ssl.start()
          url = ~c"https://hex.pm/api/packages/#{package}"

          case :httpc.request(:get, {url, [{~c"User-Agent", ~c"igniter-installer"}]}, [], []) do
            {:ok, {{_version, _, _reason_phrase}, _headers, body}} ->
              case Jason.decode(body) do
                {:ok,
                 %{
                   "releases" => [
                     %{"version" => version}
                     | _
                   ]
                 }} ->
                  {String.to_atom(package),
                   Igniter.Util.Version.version_string_to_general_requirement!(version)}

                _ ->
                  :error
              end

            _ ->
              :error
          end
        else
          :error
        end

      [package, version] ->
        case version do
          "git:" <> requirement ->
            if String.contains?(requirement, "@") do
              case String.split(requirement, ["@"], trim: true) do
                [url, ref] ->
                  [git: url, ref: ref]

                _ ->
                  :error
              end
            else
              [git: requirement, override: true]
            end

          "github:" <> requirement ->
            if String.contains?(requirement, "@") do
              case String.split(requirement, ["/", "@"], trim: true) do
                [org, project, ref] ->
                  [github: "#{org}/#{project}", ref: ref]

                _ ->
                  :error
              end
            else
              [github: requirement, override: true]
            end

          "path:" <> requirement ->
            [path: requirement, override: true]

          version ->
            case Version.parse(version) do
              {:ok, version} ->
                "== #{version}"

              _ ->
                case Igniter.Util.Version.version_string_to_general_requirement(version) do
                  {:ok, requirement} ->
                    requirement

                  _ ->
                    :error
                end
            end
        end
        |> case do
          :error ->
            :error

          requirement ->
            {String.to_atom(package), requirement}
        end
    end
  end

  def get_deps! do
    Mix.shell().info("running mix deps.get")

    case Mix.shell().cmd("mix deps.get") do
      0 ->
        Mix.Project.clear_deps_cache()
        Mix.Project.pop()
        Mix.Dep.clear_cached()

        "mix.exs"
        |> File.read!()
        |> Code.eval_string([], file: Path.expand("mix.exs"))

        Igniter.Util.DepsCompile.run(recompile_igniter?: true)

      exit_code ->
        Mix.shell().info("""
        mix deps.get returned exited with code: `#{exit_code}`
        """)
    end
  end
end

defmodule Sprout.Shell do
  @moduledoc """
  Sets up shell integration for Bash or ZSH.
  """
  use TypedStruct

  typedstruct do
    field :type, :bash | :zsh
    field :argv, [String.t()]
    field :env, keyword()
  end

  @spec initialize(Path.t()) :: t()
  def initialize(shell) do
    client_dir = Sprout.client_dir()

    paths = %{
      pipe: Sprout.pipe_path(),
      relay: Sprout.relay_path(),
      env: Sprout.env_path()
    }

    initialize_fifo!(paths.pipe)
    initialize_fifo!(paths.relay)
    initialize_env!(paths.env)

    case Path.basename(shell) do
      "bash" ->
        rc = Path.join(client_dir, "bashrc")

        File.write!(rc, bashrc(paths))

        %__MODULE__{
          type: :bash,
          argv: ["--rcfile", rc],
          env: []
        }

      "zsh" ->
        rc = Path.join(client_dir, ".zshrc")
        env = Path.join(client_dir, ".zshenv")

        File.write!(env, zshenv(client_dir))
        File.write!(rc, zshrc(paths))

        %__MODULE__{
          type: :zsh,
          argv: [],
          env: [{"ZDOTDIR", client_dir}]
        }
    end
  end

  defp initialize_fifo!(fifo) do
    {_, 0} = System.cmd("mkfifo", [fifo])
  end

  defp initialize_env!(env) do
    File.touch!(env)
  end

  defp bashrc(%{pipe: pipe, relay: relay, env: env}) do
    """
    [ -f "$HOME/.bashrc" ] && source "$HOME"/.bashrc

    REAL_PS1="$PS1"

    exec 3>#{pipe}
    exec 4<#{relay}
    . #{env}

    trap '[ "$BASH_COMMAND" = "$PROMPT_COMMAND" ] || printf "START %s\\n" "$BASH_COMMAND" >&3' DEBUG
    sprout_prompt_command() {
      printf "END %s\\n" "$?" >&3
      . #{env}

      if [ "$SPROUT_TURN" = "1" ]; then
        PS1=""

        while IFS= read -r line <&4; do
          case "$line" in
            "RUN "*)
              cmd="${line#RUN }"
              printf "START %s\\n" "$cmd" >&3
              eval "$cmd"
              printf "END %s\\n" "$?" >&3
              ;;
            "DONE")
              break
              ;;
          esac
        done

        PS1="$REAL_PS1"
      fi
    }
    PROMPT_COMMAND=sprout_prompt_command
    """
  end

  defp zshenv(dir) do
    """
    source "$HOME/.zshenv" 2>/dev/null
    export REAL_ZDOTDIR="${ZDOTDIR:-$HOME}"
    export ZDOTDIR=#{dir}
    """
  end

  defp zshrc(%{pipe: pipe, relay: relay, env: env}) do
    """
    [ -f "$REAL_ZDOTDIR/.zshrc" ] && source "$REAL_ZDOTDIR"/.zshrc

    REAL_PROMPT="$PROMPT"

    exec 3>#{pipe}
    exec 4<#{relay}
    source #{env}

    sprout_preexec() { print -u3 "START $1" }
    sprout_precmd() {
      print -u3 "END $?"
      source #{env}

      if [ "$SPROUT_TURN" = "1" ]; then
        PROMPT=""

        while IFS= read -r line <&4; do
          case "$line" in
            "RUN "*)
              cmd="${line#RUN }"
              print -u3 "START $cmd"
              eval "$cmd"
              print -u3 "END $?"
              ;;
            "DONE")
              break
              ;;
          esac
        done

        PROMPT="$REAL_PROMPT"
      fi
    }
    preexec_functions+=(sprout_preexec)
    precmd_functions+=(sprout_precmd)
    """
  end
end
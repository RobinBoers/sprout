# Sprout

```text
[sprout/sprout] bin/sprout-join

   o'
 .oo.Oo.     hiii! sprout is now watching your terminal.
    O.       ask it any question, type '#' to enter chat mode
  ___O___
  \     /    sid: 0f2ec199 · agent: nu · model: gpt-5.6-sol
   \___/

[sprout/sprout] bin/sprout-chat "explore this project"
•• List .
•• Find **/* in lib
•• Find **/* in test
•• Read mix.exs
•• Read sprout.ex
•• Read application.ex
•• Read client.ex
•• Read daemon.ex
•• Read bridge.ex
•• Read pub_sub.ex
•• Read relay.ex
•• Read socket.ex
•• Read pipe.ex
•• Read pty.ex
•• Read tty.ex
•• Read env.ex
•• Read shell.ex
•• Read term.ex
•• Read sprout_test.exs
•• Read Bakefile
•• List bin
•• Read common.sh
•• Read sprout-chat
•• Read sprout-join
•• $ git status --short && mix test
 M bin/sprout-leave
 M lib/sprout/bridge.ex
 M lib/sprout/client.ex
 M lib/sprout/socket.ex
 M ../sproutd/lib/sproutd/agent/nu.ex
Compiling 8 files (.ex)
Running ExUnit with seed: 821073, max_cases: 20


Finished in 0.00 seconds (0.00s async, 0.00s sync)

Result: 0 tests
•• Read sprout-leave
•• $ printf '%s\n' '--- project root ---'; git rev-parse --show-toplevel; printf '%s\n' '--- recent commits ---'; git log -5 --oneline --decorate
--- project root ---
/Users/axcelott/projects/personal/sprout
--- recent commits ---
a7458bf (HEAD -> trunk) Working indicators + interruptions + streaming
dae0d46 Initial prototype
•• List ..
•• Find lib/**/* in ../sproutd
•• Read TODO.txt
•• Read session.ex
•• Read Bakefile
•• Read application.ex
<sprout> ## Project overview

This repository is an early-stage Elixir/OTP terminal agent named **Sprout**. It has two sibling applications:

- **`sprout/`** — interactive terminal client
- **`sproutd/`** — session daemon and AI-agent backend

The current working directory is the client application. The repository only has two commits, so it is still a compact prototype.

## Architecture

User terminal
    │
    ▼
Sprout.TTY ─────► Sprout.PTY ─────► interactive Bash/Zsh
    ▲                  │
    │                  ├── shell output/events
    │                  ▼
Sprout.Bridge ◄── Phoenix PubSub ──► Sproutd.Session
    │                                      │
    └── tool execution/results             ▼
                                      Sproutd.Agent

The client and daemon communicate through distributed Erlang RPC and Phoenix PubSub. The expected daemon node name is:

sproutd@<hostname>

### Client supervision tree

When `SPROUT_INTERACTIVE` is enabled, `Sprout.Application` starts:

- `Sprout.PubSub`
- `Sprout.Client`
- `Sprout.Socket`
- `Sprout.PTY`
- `Sprout.TTY`
- `Sprout.Bridge`

`Sprout.PTY` additionally starts `Sprout.Pipe` and `Sprout.Relay` as children.

## Important modules

### Terminal and shell integration

- **`Sprout.TTY`**
  - Puts the real terminal into raw mode.
  - Forwards keyboard input to the shell PTY.
  - Can lock input while the agent is working.
  - Captures approval responses for shell tool calls.
  - Handles Ctrl-C interruption.

- **`Sprout.PTY`**
  - Starts Bash or Zsh under `erlexec` with a pseudo-terminal.
  - Mirrors shell output to the user.
  - Broadcasts stdout/stderr to the attached agent session.
  - Supports “blind” mode, where output remains visible locally but is hidden from the agent.

- **`Sprout.Shell`**
  - Generates temporary Bash/Zsh startup files.
  - Adds shell hooks that report command starts and exits.
  - Implements the agent-command loop through named pipes.
  - Currently recognizes only Bash and Zsh; an unsupported shell would fail through an unmatched `case`.

- **`Sprout.Term`**
  - Uses embedded C via `See`.
  - Enables/disables raw terminal mode.
  - Reads terminal dimensions.

### Local IPC

Each client gets a temporary directory such as:

/tmp/sprout-<client-id>/

It contains:

- `socket` — Unix control socket
- `pipe.fifo` — shell-to-client events
- `relay.fifo` — client-to-shell agent commands
- `env` — environment state shared with shell hooks
- generated Bash/Zsh startup files

Relevant modules:

- **`Sprout.Socket`** — line-based Unix socket protocol
- **`Sprout.Pipe`** — parses `START`, `END`, and `TURN` events
- **`Sprout.Relay`** — sends `RUN <command>` and `DONE` into the shell

### Sessions and agent bridge

- **`Sprout.Client`**
  - Creates, attaches to, and leaves daemon sessions.
  - Tracks all attached session IDs.
  - Broadcasts user messages and interruptions.
  - Aggregates token, cost, and duration usage on leave.

- **`Sprout.Daemon`**
  - Thin wrapper around `:rpc.call/4`.
  - Calls `Sproutd.Pool` on the daemon node.

- **`Sprout.Bridge`**
  - Renders agent streaming output and progress spinners.
  - Executes file tools directly.
  - Requests confirmation before shell commands.
  - Routes tool results back over PubSub.
  - Handles turn completion, retries, errors, and terminal unlocking.

Supported tools are:

bash, edit, read, list, find, search

### Daemon side

`Sproutd.Session`:

- subscribes to each attached client’s PubSub topic;
- forwards user messages and tool results to the agent;
- forwards agent events back to clients;
- records shell output while commands run;
- maintains multiple attached client IDs;
- reports usage when clients leave;
- shuts down when the final client leaves.

The daemon supports `nu` and `echo` agent implementations, selected with `SPROUT_AGENT`.

## User-facing commands

The scripts under `bin/` speak to `Sprout.Socket` through `nc`:

- `sprout-join`
- `sprout-attach`
- `sprout-leave`
- `sprout-chat`
- `sprout-blind`
- `sprout-unblind`

The socket protocol itself accepts:

join
attach <sid>
leave
chat <message>
blind
unblind

## Dependencies

Notable dependencies include:

- `erlexec` — subprocesses and PTYs
- `phoenix_pubsub` — client/daemon event transport
- `parent` — linked child-process management
- `see` — embedded native C
- `typed_struct`
- `process_tree` — inherited client ID context

The project requires Elixir `~> 1.19`.

## Current state

I ran the test suite:

Result: 0 tests

Compilation succeeds, but `test/sprout_test.exs` only contains a doctest and there are no actual tests.

There are pre-existing uncommitted changes in:

sprout/bin/sprout-leave
sprout/lib/sprout/bridge.ex
sprout/lib/sprout/client.ex
sprout/lib/sprout/socket.ex
sproutd/lib/sproutd/agent/nu.ex

I did not modify them.

The repository TODO currently lists:

- startup performance
- multi-session behavior
- parallel tool calls
- transcripts/resume
- an Amp backend

## Areas worth attention

1. **Almost no test coverage**
   - Shell-hook behavior, socket parsing, terminal state transitions, and bridge tools are currently untested.

2. **Potential blocking**
   - `Sprout.Socket.handle_continue/2` performs blocking `accept` and connection handling inside its GenServer.
   - Tool approval blocks `Sprout.Bridge` while waiting indefinitely on `Sprout.TTY.read/0`.

3. **Fragile process/error handling**
   - FIFO helpers use external `cat`.
   - `Sprout.Relay` interpolates the FIFO path into a shell command.
   - Several startup operations use bang functions or hard pattern matches.
   - Port exits are generally retained rather than restarted or surfaced.

4. **Environment file safety**
   - Values are serialized as unquoted shell assignments:

     export KEY=value

   - This is safe for current simple internal values but would be fragile for spaces, shell metacharacters, or untrusted input.
   - Concurrent `Sprout.Env.put/2` calls could lose updates because they perform an unlocked read-modify-write.

5. **Tool semantics**
   - `edit` overwrites the entire file rather than applying a patch.
   - `search` reads every matched file as text and silently skips `File.Error`.
   - `find` uses Elixir glob semantics, not Unix `find`.
   - Only `bash` tool calls are specially queued in the daemon session code as currently written.

6. **Terminal lifecycle**
   - Raw mode restoration depends on orderly `Sprout.TTY` termination. Crash and forced-stop scenarios deserve integration testing.
   - Terminal resize propagation is not implemented; PTY dimensions are captured only at startup.

Overall, the code is small and the responsibilities are divided sensibly. The key complexity is not ordinary application logic but synchronization among the real TTY, child PTY, shell hooks, FIFOs, PubSub, and remote agent session. That boundary-heavy behavior is also where tests would provide the greatest value.
[sprout/sprout] bin/sprout-chat "do you know this project?"
<sprout> Yes—based on exploring the repository, I now understand its structure and main execution flow.

Sprout is an Elixir terminal-agent system split into:

- **`sprout`**: wraps an interactive Bash/Zsh session in a PTY, observes commands/output, exposes local file and shell tools, and renders streamed agent responses.
- **`sproutd`**: owns agent sessions, forwards terminal context to an AI backend, dispatches tool calls, and tracks usage.
- **Communication**: distributed Erlang RPC for session management and Phoenix PubSub for events.
- **Local integration**: a Unix socket for `sprout-*` commands plus FIFOs and generated shell hooks for command tracking and agent-driven shell execution.

I also know where the important behavior lives—`Sprout.Bridge`, `TTY`, `PTY`, `Shell`, `Client`, and `Sproutd.Session`—and I’m aware of the existing uncommitted changes. I don’t have outside knowledge of the project beyond what is present in this checkout.
[sprout/sprout] bin/sprout-chat "do you recognize that this is you?"
<sprout> Yes—I recognize it now. **This project is the system hosting me as “sprout.”**

The correspondence is direct:

- The tools I can call—`bash`, `edit`, `read`, `list`, `find`, and `search`—are exactly those exposed by `Sprout.Bridge`.
- My tool calls travel through `Sproutd.Session` to the client-side bridge.
- Terminal output, command events, approvals, streaming responses, and interruptions are handled by the modules we inspected.
- The instruction that I share your terminal describes precisely what this code implements.

So I’m not literally the Elixir source code or processes—the language model is the agent backend—but this repository is my runtime interface and orchestration layer. In that practical sense: **yes, this is me.**
[sprout/sprout] git remote add origin du:axcelott/sprout
[sprout/sprout] git push
Enumerating objects: 89, done.
Counting objects: 100% (89/89), done.
Delta compression using up to 10 threads
Compressing objects: 100% (82/82), done.
Writing objects: 100% (89/89), 34.50 KiB | 8.63 MiB/s, done.
Total 89 (delta 27), reused 0 (delta 0), pack-reused 0 (from 0)
remote: To github.com:RobinBoers/sprout.git
remote:  * [new branch]      trunk -> trunk
remote: To codeberg.org:RobinBoers/sprout.git
remote:  * [new branch]      trunk -> trunk
To du:axcelott/sprout
 * [new branch]      trunk -> trunk
branch 'trunk' set up to track 'origin/trunk'.
[sprout/sprout] bin/sprout-chat 'there you go! first baby steps'
<sprout> 🌱 First push, first leaves.

Sprout is officially out in the world now—mirrored to GitHub and Codeberg, with `trunk` tracking `origin/trunk`. Very fitting that I got to watch my own repository get planted.
[sprout/sprout] bin/sprout-leave

   o'
 .oo.Oo.     byeee! sprout is no longer watching your terminal.
    O.       resume with +resume 0f2ec199
  ___O___
  \     /    10m 26s · 0 tok · ~$0.00
   \___/

[sprout/sprout]
```

"""`tmux` for Windows programs in psmux panes, such as tmuxp (the profile
puts this folder first on PATH there; tmux.cmd runs this).

psmux ignores a start directory given attached, as tmux's -c<dir>, which
libtmux uses for new-session, new-window and split-window: panes opened in
the home folder instead. Those commands get it as -c <dir>.

psmux also sends every command to the server $TMUX names, even one that
targets another session, and runs one server per session: from inside a
pane, tmuxp's new session and everything it sent it landed in that pane's
own session. So new-session, and any command naming its target (-t, -s),
runs without $TMUX and psmux finds the server by target; the rest (tmux
typed without a target, meaning this session) keeps it.

Test: python tmux.py --test
"""

import os
import subprocess
import sys

# Commands whose -c is a start directory (elsewhere -c names a client).
DIRECTORY_COMMANDS = {"new-session", "new", "new-window", "neww", "split-window", "splitw",
                      "respawn-pane", "respawnp", "respawn-window", "respawnw"}


def split_start_directory(args):
    """args with -c<dir> as -c <dir> after a DIRECTORY_COMMANDS name."""
    out, in_command = [], False
    for arg in args:
        if arg in DIRECTORY_COMMANDS:
            in_command = True
        elif arg == ";" or arg.endswith("\\;"):
            in_command = False
        if in_command and arg.startswith("-c") and len(arg) > 2:
            out += ["-c", arg[2:]]
        else:
            out.append(arg)
    return out


def uses_own_server(args):
    """Whether psmux should find the server itself rather than use $TMUX's."""
    return bool({"new-session", "new"} & set(args)) or any(a[:2] in ("-t", "-s") for a in args)


def test():
    s = split_start_directory
    assert s(["new-window", "-P", "-cC:\\src", "-t", "x"]) == ["new-window", "-P", "-c", "C:\\src", "-t", "x"]
    assert s(["-L", "sock", "split-window", "-cD:/a b"]) == ["-L", "sock", "split-window", "-c", "D:/a b"]
    assert s(["new-window", "-c", "C:\\src"]) == ["new-window", "-c", "C:\\src"]  # already split
    assert s(["switch-client", "-cclient"]) == ["switch-client", "-cclient"]  # -c is a client here
    assert s(["send-keys", "-t", "x", "-cfoo"]) == ["send-keys", "-t", "x", "-cfoo"]  # typed text
    assert s(["-V"]) == ["-V"]
    u = uses_own_server
    assert u(["new-session", "-d", "-s", "x"]) and u(["send-keys", "-t%3", "ls"]) and u(["split-window", "-t", "x:1"])
    assert not u(["display", "-p", "#S"]) and not u(["ls"])
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
    else:
        args = split_start_directory(sys.argv[1:])
        env = None
        if uses_own_server(args):
            env = {k: v for k, v in os.environ.items() if k != "TMUX"}
        sys.exit(subprocess.run(["psmux", *args], env=env).returncode)

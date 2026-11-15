import Foundation

/// Opens a terminal window whose zsh prompt already holds a command, without running it.
///
/// Terminal runs an executable `.command` file in a new window. The script starts an interactive login zsh with a
/// temporary `ZDOTDIR`: each startup file there loads the user's own file of that name, so the shell is set up as
/// usual. The last one (`.zlogin`) restores `ZDOTDIR`, puts the command into the line editor with `print -z`
/// and deletes the temporary folder. The command runs only when the user presses Return.
public enum TerminalPrefill {
    public struct File: Equatable, Sendable {
        public var path: String
        public var contents: String
        public var executable: Bool
    }

    /// The executable script inside `directory` that a terminal opens.
    public static let launcherName = "open.command"
    /// Folder names under the temporary directory start with this prefix, so stale ones can be found.
    public static let folderPrefix = "switchboard-terminal-"

    /// zsh is the only shell whose prompt can be prefilled this way.
    public static func supports(shell: String) -> Bool { (shell as NSString).lastPathComponent == "zsh" }

    /// Files to write into `directory` (an empty, private folder): the command, the launcher and the startup files.
    /// `folder` is the working folder of the new shell; `shell` is the user's zsh.
    public static func files(command: String, folder: String, shell: String, directory: String) -> [File] {
        let zdot = directory + "/zdot"
        let launcher = """
        #!/bin/zsh -f
        cd -- \(quote(folder)) 2>/dev/null || cd
        export SWITCHBOARD_PREFILL_ZDOTDIR_SET=${ZDOTDIR+1}
        export SWITCHBOARD_PREFILL_HOME="${ZDOTDIR:-$HOME}"
        export SWITCHBOARD_PREFILL_DIR=\(quote(directory))
        # The window's first shell already keeps Terminal's session history; a second setup would live in the temporary folder.
        export SHELL_SESSION_DID_INIT=1
        export ZDOTDIR=\(quote(zdot))
        # Terminal printed "Last login" and the launcher's own path; the window starts clean instead.
        printf '\\033[H\\033[2J\\033[3J'
        exec \(quote(shell)) -il

        """
        return [
            File(path: directory + "/command", contents: command, executable: false),
            File(path: directory + "/" + launcherName, contents: launcher, executable: true),
            File(path: zdot + "/.zshenv", contents: relay(".zshenv"), executable: false),
            File(path: zdot + "/.zprofile", contents: relay(".zprofile"), executable: false),
            File(path: zdot + "/.zshrc", contents: """
            # /etc/zshrc chose the history file while ZDOTDIR pointed here.
            [[ "$HISTFILE" == "$SWITCHBOARD_PREFILL_DIR/zdot/.zsh_history" ]] && HISTFILE="$SWITCHBOARD_PREFILL_HOME/.zsh_history"
            # /etc/zshrc_Apple_Terminal has seen it; shells started later in this window set up as usual.
            unset SHELL_SESSION_DID_INIT
            \(relay(".zshrc"))
            """, executable: false),
            File(path: zdot + "/.zlogin", contents: """
            ZDOTDIR="$SWITCHBOARD_PREFILL_HOME"
            [[ -r "$ZDOTDIR/.zlogin" ]] && builtin source "$ZDOTDIR/.zlogin"
            () {
              local dir="$SWITCHBOARD_PREFILL_DIR"
              [[ -z "$SWITCHBOARD_PREFILL_ZDOTDIR_SET" && "$ZDOTDIR" == "$HOME" ]] && unset ZDOTDIR
              unset SWITCHBOARD_PREFILL_HOME SWITCHBOARD_PREFILL_DIR SWITCHBOARD_PREFILL_ZDOTDIR_SET
              [[ -r "$dir/command" ]] && builtin print -rz -- "$(<"$dir/command")"
              command rm -rf -- "$dir"
            }

            """, executable: false),
        ]
    }

    /// A startup file that loads the user's file of the same name with the user's `ZDOTDIR`,
    /// then points `ZDOTDIR` back here so zsh reads the next startup file from this folder.
    private static func relay(_ name: String) -> String {
        """
        ZDOTDIR="$SWITCHBOARD_PREFILL_HOME"
        [[ -r "$ZDOTDIR/\(name)" ]] && builtin source "$ZDOTDIR/\(name)"
        SWITCHBOARD_PREFILL_HOME="$ZDOTDIR"
        ZDOTDIR="$SWITCHBOARD_PREFILL_DIR/zdot"

        """
    }

    /// A single-quoted shell word.
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

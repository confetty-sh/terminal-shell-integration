namespace Terminal.ShellIntegration;

/// <summary>
/// Which shell is being spawned.
/// </summary>
public enum ShellKind
{
    Unknown = 0,
    Bash,
    Zsh,
    Fish,

    /// <summary>pwsh, or Windows PowerShell 5.1 — the script is written for both.</summary>
    PowerShell,
}

/// <summary>
/// Why a shell was left alone.
/// </summary>
public enum SkipReason
{
    None = 0,

    /// <summary>The shell is not one this knows how to instrument.</summary>
    UnsupportedShell,

    /// <summary>Integration is already present, which happens when a shell spawns another.</summary>
    AlreadyInjected,

    /// <summary>The shell was asked to run a command and exit, so there is no prompt to mark.</summary>
    NotInteractive,

    /// <summary>The scripts are not where they were said to be.</summary>
    ResourcesMissing,
}

/// <summary>
/// What to spawn instead.
/// </summary>
public sealed record ShellIntegrationResult(
    IReadOnlyList<string> Args,
    IReadOnlyDictionary<string, string> Environment,
    ShellKind Kind,
    bool Injected,
    SkipReason Skipped = SkipReason.None);

/// <summary>
/// Prepares a shell to report what it is doing.
/// </summary>
/// <remarks>
/// <para>A terminal can only know where a prompt began, when a command started, and what it exited
/// with if the shell says so — OSC 133. Stock bash and zsh say nothing, so every terminal that wants
/// those features injects integration into the shell it spawns. This is that injection, and nothing
/// else: given a shell path with its arguments and environment, it returns the arguments and
/// environment to spawn instead.</para>
///
/// <para>Deliberately free of UI, PTY and emulator dependencies. The transform is pure, so it can be
/// tested by asserting on the arguments and environment it produces without spawning anything at
/// all — which is the only practical way to cover the shell-specific quirks below.</para>
///
/// <para>The mechanism follows Ghostty's, which is MIT licensed and solved problems worth not
/// rediscovering. In particular the bash one: <c>--init-file</c> is silently ignored for a login
/// shell, so the file never runs for anyone who starts one. POSIX mode sources <c>$ENV</c>
/// regardless, at the cost of the script having to replay bash's own startup sequence afterwards.</para>
///
/// <para>What this does NOT decide: whether to inject at all, and where the scripts live. Both are
/// the host's, because a user must be able to turn this off and only the host knows where its own
/// files are.</para>
/// </remarks>
public static class ShellIntegration
{
    /// <summary>Set on an instrumented shell, so a shell spawned from it is left alone.</summary>
    public const string MarkerVariable = "TERMINAL_SHELL_INTEGRATION";

    /// <summary>Where the scripts are, so they can find each other.</summary>
    public const string ResourcesVariable = "TERMINAL_SHELL_RESOURCES";

    /// <summary>Carries the flags the script must honour when it replays bash's startup.</summary>
    public const string BashInjectVariable = "TERMINAL_SHELL_BASH_INJECT";

    /// <summary>The user's own ENV, which POSIX mode displaces.</summary>
    public const string BashEnvVariable = "TERMINAL_SHELL_BASH_ENV";

    /// <summary>The user's own ZDOTDIR, which the injected one displaces. Absent when they had none.</summary>
    public const string ZshDotDirVariable = "TERMINAL_SHELL_ZDOTDIR";

    /// <summary>
    /// Works out what to spawn so the shell reports its prompts and working directory.
    /// </summary>
    /// <param name="shellPath">The shell being launched, as a path or a bare name.</param>
    /// <param name="args">Its arguments, not including the program itself.</param>
    /// <param name="environment">The environment it would otherwise inherit.</param>
    /// <param name="resourcesDirectory">
    /// The directory holding <c>bash/</c>, <c>zsh/</c>, <c>fish/</c> and <c>pwsh/</c>. The host owns this because
    /// only the host knows where its files are.
    /// </param>
    public static ShellIntegrationResult Prepare(
        string shellPath,
        IReadOnlyList<string>? args,
        IReadOnlyDictionary<string, string>? environment,
        string resourcesDirectory)
    {
        var originalArgs = args is null ? new List<string>() : new List<string>(args);
        var env = environment is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(environment, StringComparer.Ordinal);

        var kind = Identify(shellPath);

        if (kind == ShellKind.Unknown)
            return new(originalArgs, env, kind, false, SkipReason.UnsupportedShell);

        // A shell spawned from an instrumented one would otherwise be instrumented twice, and would
        // emit every mark twice with it.
        if (env.ContainsKey(MarkerVariable))
            return new(originalArgs, env, kind, false, SkipReason.AlreadyInjected);

        // -c runs a command and exits. There is no prompt to mark, and rewriting the arguments of a
        // one-shot command is a good way to break it.
        if (IsNonInteractive(kind, originalArgs))
            return new(originalArgs, env, kind, false, SkipReason.NotInteractive);

        var shellResources = Path.Combine(resourcesDirectory, ResourceFolder(kind));
        if (!Directory.Exists(shellResources))
            return new(originalArgs, env, kind, false, SkipReason.ResourcesMissing);

        env[MarkerVariable] = "1";
        env[ResourcesVariable] = resourcesDirectory;

        return kind switch
        {
            ShellKind.Bash => PrepareBash(originalArgs, env, shellResources, kind),
            ShellKind.Zsh => PrepareZsh(originalArgs, env, shellResources, kind),
            ShellKind.Fish => PrepareFish(originalArgs, env, shellResources, kind),
            ShellKind.PowerShell => PreparePowerShell(originalArgs, env, shellResources, kind),
            _ => new(originalArgs, env, kind, false, SkipReason.UnsupportedShell),
        };
    }

    /// <summary>
    /// Which shell a path names.
    /// </summary>
    /// <remarks>
    /// A login shell is conventionally spawned with its name prefixed by a dash — <c>-bash</c> — so
    /// that is stripped. So is a Windows extension, since the same shells are reachable there.
    /// </remarks>
    public static ShellKind Identify(string? shellPath)
    {
        if (string.IsNullOrWhiteSpace(shellPath))
            return ShellKind.Unknown;

        // Split on both separators rather than Path.GetFileName, which only honours the host's.
        // A Windows path handed to a process running on Unix would otherwise come back whole and
        // match nothing — and a test for it would pass on Windows and fail on macOS, which is worse
        // than failing everywhere.
        var trimmed = shellPath.Trim();
        var cut = trimmed.LastIndexOfAny(new[] { '/', '\\' });
        var name = cut >= 0 ? trimmed[(cut + 1)..] : trimmed;

        if (string.IsNullOrEmpty(name))
            return ShellKind.Unknown;

        if (name.StartsWith('-'))
            name = name[1..];

        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            name = name[..^4];

        return name.ToLowerInvariant() switch
        {
            "bash" => ShellKind.Bash,
            "zsh" => ShellKind.Zsh,
            "fish" => ShellKind.Fish,
            "pwsh" or "powershell" => ShellKind.PowerShell,
            _ => ShellKind.Unknown,
        };
    }

    /// <summary>The folder a shell's scripts live in. pwsh's is named for the binary, not the kind.</summary>
    private static string ResourceFolder(ShellKind kind) =>
        kind == ShellKind.PowerShell ? "pwsh" : kind.ToString().ToLowerInvariant();

    private static bool IsNonInteractive(ShellKind kind, IReadOnlyList<string> args)
    {
        if (kind == ShellKind.PowerShell)
            return IsNonInteractivePowerShell(args);

        foreach (var arg in args)
        {
            if (arg == "-c" || arg == "--command")
                return true;

            // Bundled short options, so -ic is interactive but -lc is not.
            if (arg.Length > 1 && arg[0] == '-' && arg[1] != '-' && arg.Contains('c'))
                return true;
        }

        return false;
    }

    /// <summary>
    /// PowerShell's one-shot switches.
    /// </summary>
    /// <remarks>
    /// PowerShell uses single-dash long options, case-insensitive, and accepts unambiguous prefixes
    /// of them -- so the POSIX test above would be wrong in both directions: <c>-ExecutionPolicy</c>
    /// contains a <c>c</c> and is interactive, while <c>-File</c> contains none and is not. The
    /// spellings here are the documented aliases; a bare <c>-e</c> is <c>-EncodedCommand</c>.
    /// </remarks>
    private static bool IsNonInteractivePowerShell(IReadOnlyList<string> args)
    {
        foreach (var arg in args)
        {
            if (arg.Length < 2 || arg[0] != '-')
                continue;

            switch (arg[1..].ToLowerInvariant())
            {
                case "command": case "c":
                case "file": case "f":
                case "encodedcommand": case "ec": case "enc": case "e":
                case "noninteractive":
                    return true;
            }
        }

        return false;
    }

    /// <summary>
    /// PowerShell, via <c>-NoExit -Command</c>.
    /// </summary>
    /// <remarks>
    /// <para>No profile is touched and none is displaced. <c>-Command</c> runs after the profiles,
    /// so the script finds <c>$function:prompt</c> already holding whatever the user installed --
    /// oh-my-posh, starship, their own -- and wraps it. It also means <c>-NoProfile</c> still gets
    /// integration, which a profile-based mechanism could never give.</para>
    /// <para>The one ordering rule: <c>-Login</c> has to be the first argument, so it is kept there
    /// and everything else goes before <c>-Command</c>, which consumes the rest of the line.</para>
    /// </remarks>
    private static ShellIntegrationResult PreparePowerShell(
        List<string> args, Dictionary<string, string> env, string resources, ShellKind kind)
    {
        var script = Path.Combine(resources, "integration.ps1");

        var prepared = new List<string>();
        var rest = new List<string>(args);

        if (rest.Count > 0 && (rest[0].Equals("-l", StringComparison.OrdinalIgnoreCase)
                               || rest[0].Equals("-Login", StringComparison.OrdinalIgnoreCase)))
        {
            prepared.Add(rest[0]);
            rest.RemoveAt(0);
        }

        prepared.AddRange(rest);
        prepared.Add("-NoExit");
        prepared.Add("-Command");

        // Single-quoted, with the only character that means anything inside single quotes doubled.
        prepared.Add(". '" + script.Replace("'", "''") + "'");

        return new(prepared, env, kind, true);
    }

    /// <summary>
    /// bash, via POSIX mode and <c>ENV</c>.
    /// </summary>
    /// <remarks>
    /// <para><c>--init-file</c> would be the obvious hook and is the wrong one: bash ignores it for a
    /// login shell, which is how a great many people start theirs. In POSIX mode bash sources
    /// <c>$ENV</c> whatever kind of shell it is, so that is what is used.</para>
    /// <para>The cost is paid inside the script, which must leave POSIX mode and then replay bash's
    /// own startup sequence — the flags it needs to do that faithfully are handed over in
    /// <see cref="BashInjectVariable"/>.</para>
    /// </remarks>
    private static ShellIntegrationResult PrepareBash(
        List<string> args, Dictionary<string, string> env, string resources, ShellKind kind)
    {
        var flags = new List<string>();

        foreach (var arg in args)
        {
            if (arg == "--noprofile") flags.Add("noprofile");
            else if (arg == "--norc") flags.Add("norc");
            else if (arg == "-l" || arg == "--login") flags.Add("login");
        }

        // A login shell is also spelled by the leading dash on argv[0], which the caller may have
        // set instead of passing -l.
        env[BashInjectVariable] = string.Join(" ", flags);

        // POSIX mode displaces the user's ENV, so it is kept for the script to restore.
        if (env.TryGetValue("ENV", out var userEnv))
            env[BashEnvVariable] = userEnv;

        env["ENV"] = Path.Combine(resources, "integration.bash");

        // --posix goes first: bash reads it before deciding how to start.
        var prepared = new List<string> { "--posix" };
        prepared.AddRange(args);

        return new(prepared, env, kind, true);
    }

    /// <summary>
    /// zsh, via <c>ZDOTDIR</c>.
    /// </summary>
    /// <remarks>
    /// <para>zsh reads <c>.zshenv</c> first, from <c>ZDOTDIR</c>. The injected one puts the user's
    /// <c>ZDOTDIR</c> back before sourcing theirs, so their <c>.zshenv</c> can move it again — the
    /// XDG layout, <c>export ZDOTDIR=~/.config/zsh</c> — and zsh reads the remaining three from
    /// wherever it ends up, exactly as it would have. By then <c>ZDOTDIR</c> is the user's, so the
    /// script finds <c>integration.zsh</c> through <see cref="ResourcesVariable"/> instead.</para>
    /// <para>When the user had no <c>ZDOTDIR</c>, none is handed over, and the script leaves it
    /// unset rather than set to <c>HOME</c>. zsh reads from <c>HOME</c> either way, but a
    /// <c>.zshenv</c> that only supplies a default — <c>${ZDOTDIR:-~/.config/zsh}</c> — sees the
    /// difference, and with <c>HOME</c> filled in it never moves and its <c>.zshrc</c> is never
    /// read.</para>
    /// </remarks>
    private static ShellIntegrationResult PrepareZsh(
        List<string> args, Dictionary<string, string> env, string resources, ShellKind kind)
    {
        if (env.TryGetValue("ZDOTDIR", out var userZdotdir) && !string.IsNullOrEmpty(userZdotdir))
            env[ZshDotDirVariable] = userZdotdir;
        else
            env.Remove(ZshDotDirVariable);

        env["ZDOTDIR"] = resources;

        return new(args, env, kind, true);
    }

    /// <summary>
    /// fish, via <c>XDG_DATA_DIRS</c>.
    /// </summary>
    /// <remarks>
    /// The pleasant one. fish automatically sources <c>vendor_conf.d</c> from every data directory,
    /// so nothing of the user's is displaced or replayed — the integration is simply another vendor
    /// file, and a fish with no integration is a fish that did not find it.
    /// </remarks>
    private static ShellIntegrationResult PrepareFish(
        List<string> args, Dictionary<string, string> env, string resources, ShellKind kind)
    {
        // The PARENT of the fish directory, not the fish directory itself. Fish looks for
        // "<entry>/fish/vendor_conf.d" under each data directory, so pointing it straight at the
        // fish folder makes it search for "fish/fish/vendor_conf.d" — and it finds nothing, loads
        // nothing, and says nothing, which looks exactly like integration that was never written.
        var dataDir = Directory.GetParent(resources)?.FullName ?? resources;
        var existing = env.GetValueOrDefault("XDG_DATA_DIRS", string.Empty);

        env["XDG_DATA_DIRS"] = string.IsNullOrEmpty(existing)
            ? dataDir
            : dataDir + Path.PathSeparator + existing;

        return new(args, env, kind, true);
    }
}

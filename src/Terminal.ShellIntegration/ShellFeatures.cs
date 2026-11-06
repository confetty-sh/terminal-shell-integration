namespace Terminal.ShellIntegration;

/// <summary>
/// The optional behaviours a script adds on top of the prompt marks, named as Ghostty's
/// <c>shell-integration-features</c> names them.
/// </summary>
[Flags]
public enum ShellFeature
{
    None = 0,

    /// <summary>A bar cursor at the prompt, and the user's own back for each command.</summary>
    Cursor = 1 << 0,

    /// <summary>
    /// <c>sudo</c> keeps <c>TERMINFO</c>, so a terminal whose terminfo the host ships still works
    /// under it. Only when <c>TERMINFO</c> is set: a <c>TERM</c> from the system database survives
    /// sudo as it is.
    /// </summary>
    Sudo = 1 << 1,

    /// <summary>The window title: the working directory at the prompt, the command while it runs.</summary>
    Title = 1 << 2,

    /// <summary>
    /// <c>ssh</c> forwards <c>COLORTERM</c>, <c>TERM_PROGRAM</c> and <c>TERM_PROGRAM_VERSION</c>,
    /// and falls back to <c>xterm-256color</c> when <c>TERM</c> comes from a private terminfo.
    /// </summary>
    SshEnv = 1 << 3,

    /// <summary>
    /// Accepted and does nothing. Ghostty installs its own terminfo on the remote host; with a
    /// <c>TERM</c> every host already has, there is nothing to install.
    /// </summary>
    SshTerminfo = 1 << 4,

    /// <summary>
    /// Accepted and does nothing. Ghostty puts its own command-line tool on <c>PATH</c>; this
    /// library has no tool to put there.
    /// </summary>
    Path = 1 << 5,
}

/// <summary>
/// Which features a shell gets, and how its prompt cursor blinks.
/// </summary>
/// <remarks>
/// <para>Reaches the scripts as <see cref="ShellIntegration.FeaturesVariable"/>, in the shape
/// Ghostty gives <c>GHOSTTY_SHELL_FEATURES</c>: the enabled features in alphabetical order, joined
/// by commas, with the cursor carrying <c>:blink</c> or <c>:steady</c> --
/// <c>cursor:blink,path,title</c>. With nothing enabled the variable is absent.</para>
/// <para>The blink is not a feature of its own: in Ghostty it comes from <c>cursor-style-blink</c>,
/// a different key, so a host sets it from wherever its own cursor setting lives.</para>
/// </remarks>
public readonly record struct ShellFeatures(ShellFeature Enabled, bool CursorBlink = true)
{
    /// <summary>Ghostty's defaults: <c>cursor</c>, <c>title</c> and <c>path</c> on, the rest off.</summary>
    public static ShellFeatures Default => new(ShellFeature.Cursor | ShellFeature.Title | ShellFeature.Path);

    /// <summary>Nothing beyond the prompt marks.</summary>
    public static ShellFeatures None => new(ShellFeature.None);

    // Alphabetical, which is the order Ghostty writes them in.
    private static readonly (string Name, ShellFeature Feature)[] Names =
    {
        ("cursor", ShellFeature.Cursor),
        ("path", ShellFeature.Path),
        ("ssh-env", ShellFeature.SshEnv),
        ("ssh-terminfo", ShellFeature.SshTerminfo),
        ("sudo", ShellFeature.Sudo),
        ("title", ShellFeature.Title),
    };

    /// <summary>Whether <paramref name="feature"/> is on.</summary>
    public bool Has(ShellFeature feature) => (Enabled & feature) == feature;

    /// <summary>
    /// Reads one value of Ghostty's <c>shell-integration-features</c>.
    /// </summary>
    /// <remarks>
    /// <para>A comma-separated list, each entry a feature to turn on or, prefixed <c>no-</c>, off.
    /// Anything not named keeps its default, so a value only ever says what differs. A bare boolean
    /// -- <c>true</c>, <c>false</c>, or Ghostty's other spellings <c>t</c>, <c>1</c>, <c>f</c>,
    /// <c>0</c> -- turns every feature on or off instead. An empty value is the defaults.</para>
    /// <para>One value at a time, as Ghostty reads it: every value starts again from the defaults,
    /// so when the key appears twice the later line wins whole rather than adding to the earlier.
    /// That is the config reader's to apply.</para>
    /// </remarks>
    /// <exception cref="FormatException">An entry names no feature, so the whole value is refused, as Ghostty refuses it.</exception>
    public static ShellFeatures Parse(string? value)
        => TryParse(value, out var features, out var error) ? features : throw new FormatException(error);

    /// <summary>The same, reporting a bad value rather than throwing.</summary>
    /// <param name="value">The value as the config holds it.</param>
    /// <param name="features">What it turns on; the defaults when it is refused.</param>
    /// <param name="error">The entry that named nothing, said in words, when this returns false.</param>
    public static bool TryParse(string? value, out ShellFeatures features, out string? error)
    {
        features = Default;
        error = null;

        if (string.IsNullOrEmpty(value))
            return true;

        // Untrimmed, as Ghostty compares it: " true" is a list with one unknown entry in it.
        switch (value)
        {
            case "true" or "t" or "T" or "1":
                features = new(All);
                return true;
            case "false" or "f" or "F" or "0":
                features = None;
                return true;
        }

        var enabled = Default.Enabled;
        foreach (var raw in value.Split(','))
        {
            var part = raw.Trim(' ', '\t');
            var on = true;
            if (part.StartsWith("no-", StringComparison.Ordinal))
            {
                part = part[3..];
                on = false;
            }

            var feature = Lookup(part);
            if (feature == ShellFeature.None)
            {
                error = $"'{raw.Trim(' ', '\t')}' is not a shell integration feature";
                features = Default;
                return false;
            }

            enabled = on ? enabled | feature : enabled & ~feature;
        }

        features = new(enabled);
        return true;
    }

    /// <summary>The value of <see cref="ShellIntegration.FeaturesVariable"/>, or null when nothing is on.</summary>
    public string? ToEnvironmentValue()
    {
        var parts = new List<string>();
        foreach (var (name, feature) in Names)
        {
            if (!Has(feature))
                continue;
            parts.Add(feature == ShellFeature.Cursor ? name + (CursorBlink ? ":blink" : ":steady") : name);
        }

        return parts.Count == 0 ? null : string.Join(",", parts);
    }

    private static ShellFeature All
    {
        get
        {
            var all = ShellFeature.None;
            foreach (var (_, feature) in Names)
                all |= feature;
            return all;
        }
    }

    // Case-sensitive, as Ghostty's field names are.
    private static ShellFeature Lookup(string name)
    {
        foreach (var (candidate, feature) in Names)
        {
            if (candidate == name)
                return feature;
        }

        return ShellFeature.None;
    }
}

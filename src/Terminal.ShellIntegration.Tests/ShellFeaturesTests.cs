using NUnit.Framework;
using Terminal.ShellIntegration;

namespace Terminal.ShellIntegration.Tests;

/// <summary>
/// Ghostty's <c>shell-integration-features</c> syntax, and what reaches the scripts.
/// </summary>
/// <remarks>
/// The expected values are Ghostty's own: its defaults from <c>ShellIntegrationFeatures</c> in
/// <c>Config.zig</c>, its parsing from <c>parsePackedStruct</c>, and the variable's shape from the
/// tests of <c>setupFeatures</c>. A user moving their config across must get the same features.
/// </remarks>
[TestFixture]
public class ShellFeaturesTests
{
    private const ShellFeature All = ShellFeature.Cursor | ShellFeature.Sudo | ShellFeature.Title
        | ShellFeature.SshEnv | ShellFeature.SshTerminfo | ShellFeature.Path;

    private const ShellFeature Defaults = ShellFeature.Cursor | ShellFeature.Title | ShellFeature.Path;

    private string _resources = string.Empty;

    [SetUp]
    public void CreateResources()
    {
        _resources = Path.Combine(Path.GetTempPath(), "shell-integration-tests", Guid.NewGuid().ToString("n"));
        foreach (var shell in new[] { "bash", "zsh", "fish", "pwsh" })
            Directory.CreateDirectory(Path.Combine(_resources, shell));
    }

    [TearDown]
    public void RemoveResources()
    {
        if (Directory.Exists(_resources))
            Directory.Delete(_resources, recursive: true);
    }

    // ---- parsing ----------------------------------------------------------------------------------

    [Test]
    public void The_defaults_are_Ghosttys()
        => Assert.That(ShellFeatures.Default.Enabled, Is.EqualTo(Defaults));

    [TestCase(null)]
    [TestCase("")]
    public void No_value_is_the_defaults(string? value)
        => Assert.That(ShellFeatures.Parse(value).Enabled, Is.EqualTo(Defaults));

    /// <summary>
    /// Naming a feature changes only that one; the rest keep their defaults rather than going off,
    /// which is the part people expect to work the other way.
    /// </summary>
    [TestCase("sudo", Defaults | ShellFeature.Sudo)]
    [TestCase("no-cursor", ShellFeature.Title | ShellFeature.Path)]
    [TestCase("no-cursor,sudo", ShellFeature.Title | ShellFeature.Path | ShellFeature.Sudo)]
    [TestCase("ssh-env,ssh-terminfo", Defaults | ShellFeature.SshEnv | ShellFeature.SshTerminfo)]
    [TestCase("no-title,no-path,no-cursor", ShellFeature.None)]
    [TestCase("cursor", Defaults)]
    public void A_list_changes_only_what_it_names(string value, ShellFeature expected)
        => Assert.That(ShellFeatures.Parse(value).Enabled, Is.EqualTo(expected));

    /// <summary>Entries apply in order, so the last word on one feature is the one that counts.</summary>
    [TestCase("sudo,no-sudo", Defaults)]
    [TestCase("no-title,title", Defaults)]
    public void A_later_entry_overrides_an_earlier_one(string value, ShellFeature expected)
        => Assert.That(ShellFeatures.Parse(value).Enabled, Is.EqualTo(expected));

    [TestCase("true", All)]
    [TestCase("t", All)]
    [TestCase("T", All)]
    [TestCase("1", All)]
    [TestCase("false", ShellFeature.None)]
    [TestCase("f", ShellFeature.None)]
    [TestCase("F", ShellFeature.None)]
    [TestCase("0", ShellFeature.None)]
    public void A_boolean_turns_everything_on_or_off(string value, ShellFeature expected)
        => Assert.That(ShellFeatures.Parse(value).Enabled, Is.EqualTo(expected));

    [TestCase(" sudo , no-cursor ", ShellFeature.Title | ShellFeature.Path | ShellFeature.Sudo)]
    [TestCase("\tsudo", Defaults | ShellFeature.Sudo)]
    public void Space_around_an_entry_is_ignored(string value, ShellFeature expected)
        => Assert.That(ShellFeatures.Parse(value).Enabled, Is.EqualTo(expected));

    /// <summary>
    /// An unknown entry refuses the whole value, not just itself: Ghostty does, and a half-applied
    /// value would leave someone with features they did not ask for and no idea why.
    /// </summary>
    [TestCase("telepathy")]
    [TestCase("cursor,no-telepathy")]
    [TestCase("Cursor")]
    [TestCase("no-")]
    [TestCase("cursor,,title")]
    [TestCase("TRUE")]
    [TestCase(" true")]
    [TestCase("yes")]
    public void An_unknown_entry_refuses_the_value(string value)
    {
        Assert.That(ShellFeatures.TryParse(value, out var features, out var error), Is.False);
        Assert.That(features, Is.EqualTo(ShellFeatures.Default));
        Assert.That(error, Is.Not.Null.And.Not.Empty);
        Assert.Throws<FormatException>(() => ShellFeatures.Parse(value));
    }

    [Test]
    public void The_error_names_the_entry()
    {
        ShellFeatures.TryParse("cursor, no-telepathy", out _, out var error);
        Assert.That(error, Does.Contain("no-telepathy"));
    }

    // ---- what the scripts are given ---------------------------------------------------------------

    /// <summary>Ghostty's own expected strings, so a script written against either reads the same.</summary>
    [TestCase(All, true, "cursor:blink,path,ssh-env,ssh-terminfo,sudo,title")]
    [TestCase(ShellFeature.SshEnv | ShellFeature.Sudo, true, "ssh-env,sudo")]
    [TestCase(ShellFeature.Cursor, true, "cursor:blink")]
    [TestCase(ShellFeature.Cursor, false, "cursor:steady")]
    [TestCase(ShellFeature.Title, false, "title")]
    public void The_variable_has_Ghosttys_shape(ShellFeature enabled, bool blink, string expected)
        => Assert.That(new ShellFeatures(enabled, blink).ToEnvironmentValue(), Is.EqualTo(expected));

    [Test]
    public void Nothing_on_is_no_value()
        => Assert.That(ShellFeatures.None.ToEnvironmentValue(), Is.Null);

    [Test]
    public void Prepare_hands_the_features_over()
    {
        var result = ShellIntegration.Prepare("zsh", null, null, _resources, ShellKind.Unknown,
            ShellFeatures.Parse("sudo,no-path") with { CursorBlink = false });

        Assert.That(result.Environment[ShellIntegration.FeaturesVariable], Is.EqualTo("cursor:steady,sudo,title"));
    }

    [TestCase("bash")]
    [TestCase("zsh")]
    [TestCase("fish")]
    [TestCase("pwsh")]
    public void Every_shell_gets_them(string shell)
    {
        var result = ShellIntegration.Prepare(shell, null, null, _resources, ShellKind.Unknown, ShellFeatures.Parse("ssh-env"));

        Assert.That(result.Injected, Is.True);
        Assert.That(result.Environment[ShellIntegration.FeaturesVariable], Is.EqualTo("cursor:blink,path,ssh-env,title"));
    }

    /// <summary>A host that offers no setting gives what Ghostty gives with none in the config.</summary>
    [Test]
    public void The_overloads_without_features_give_the_defaults()
    {
        var plain = ShellIntegration.Prepare("bash", null, null, _resources);
        var named = ShellIntegration.Prepare("anything", null, null, _resources, ShellKind.Zsh);

        Assert.That(plain.Environment[ShellIntegration.FeaturesVariable], Is.EqualTo("cursor:blink,path,title"));
        Assert.That(named.Environment[ShellIntegration.FeaturesVariable], Is.EqualTo("cursor:blink,path,title"));
    }

    /// <summary>
    /// Turned off here means off, even when the environment the host was started from carries a
    /// value of its own -- an empty variable would be read the same, but absent is what Ghostty does.
    /// </summary>
    [Test]
    public void Nothing_on_removes_an_inherited_value()
    {
        var inherited = new Dictionary<string, string> { [ShellIntegration.FeaturesVariable] = "sudo,ssh-env" };

        var result = ShellIntegration.Prepare("zsh", null, inherited, _resources, ShellKind.Unknown, ShellFeatures.None);

        Assert.That(result.Environment.ContainsKey(ShellIntegration.FeaturesVariable), Is.False);
    }

    /// <summary>A shell left alone is left alone: its environment is exactly what came in.</summary>
    [Test]
    public void A_shell_left_alone_gets_no_features()
    {
        var result = ShellIntegration.Prepare("zsh", new[] { "-c", "true" }, null, _resources, ShellKind.Unknown, ShellFeatures.Parse("true"));

        Assert.That(result.Injected, Is.False);
        Assert.That(result.Environment.ContainsKey(ShellIntegration.FeaturesVariable), Is.False);
    }
}

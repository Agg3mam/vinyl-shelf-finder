namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Keychain.swift som en abstraktion.
// På Mac ligger hemmelighederne i nøgleringen. På Windows ligger den rigtige udgave
// (Windows Credential Manager) i WinUI-appen; kernen kender kun interfacet.

/// Navne på de hemmeligheder, appen gemmer (samme service-navne som på Mac).
public static class SecretNames
{
    /// Discogs' personal access token.
    public const string Discogs = "dk.vinylshelffinder.discogs";
    /// iMusic-feedets URL fra Daisycon. Den indeholder brugerens media_id og behandles som en hemmelighed.
    public const string IMusicFeed = "dk.vinylshelffinder.imusicfeed";
}

/// Én hemmelighed (fx Discogs-tokenet). Indholdet må aldrig logges eller vises.
public interface ISecretStore
{
    /// Gemmer (eller udskifter) værdien uden først at slette den gamle.
    void Save(string value);
    /// Værdien, eller null hvis der ikke er gemt noget.
    string? Load();
    void Delete();
    /// Findes værdien? Må gerne svare uden at læse selve hemmeligheden.
    bool Exists { get; }
}

/// Hemmelighed i hukommelsen. Kun til checks og demo-tilstand.
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly object _lock = new();
    private string? _value;

    public InMemorySecretStore(string? value = null) => _value = value;

    public void Save(string value) { lock (_lock) _value = value; }
    public string? Load() { lock (_lock) return _value; }
    public void Delete() { lock (_lock) _value = null; }
    public bool Exists { get { lock (_lock) return _value != null; } }

    /// Værdien vises aldrig.
    public override string ToString() => "InMemorySecretStore(skjult)";
}

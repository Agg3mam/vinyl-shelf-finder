using System.Runtime.InteropServices;
using System.Text;
using VinylShelfFinder.Core;

namespace VinylShelfFinder;

/// <summary>
/// En hemmelighed i Windows' adgangskodelager (Credential Manager) som "generisk legitimationsoplysning".
/// Target-navnet er det samme som Mac'ens nøgleringsservice, fx <c>dk.vinylshelffinder.discogs</c>.
/// Værdien skrives aldrig til filer eller logs, og <see cref="ToString"/> viser den aldrig.
/// </summary>
public sealed class WindowsCredentialStore : ISecretStore
{
    private readonly string _target;

    public WindowsCredentialStore(string target) => _target = target;

    public static WindowsCredentialStore Discogs => new(SecretNames.Discogs);
    public static WindowsCredentialStore IMusicFeed => new(SecretNames.IMusicFeed);

    public void Save(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > MaxBlobBytes)
        {
            Array.Clear(bytes);
            throw new InvalidOperationException("Værdien er for lang til Windows' adgangskodelager.");
        }
        var blob = Marshal.AllocHGlobal(Math.Max(bytes.Length, 1));
        var target = Marshal.StringToHGlobalUni(_target);
        var user = Marshal.StringToHGlobalUni("Vinyl Shelf Finder");
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = user,
            };
            if (!CredWriteW(ref cred, 0))
                throw new InvalidOperationException($"Kunne ikke gemme i Windows' adgangskodelager (fejl {Marshal.GetLastWin32Error()}).");
        }
        finally
        {
            // Ryd kopierne i hukommelsen, så hemmeligheden ikke ligger og flyder.
            Array.Clear(bytes);
            for (int i = 0; i < bytes.Length; i++) Marshal.WriteByte(blob, i, 0);
            Marshal.FreeHGlobal(blob);
            Marshal.FreeHGlobal(target);
            Marshal.FreeHGlobal(user);
        }
    }

    public string? Load()
    {
        if (!CredReadW(_target, CRED_TYPE_GENERIC, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            var value = Encoding.UTF8.GetString(bytes);
            Array.Clear(bytes);
            return value;
        }
        finally
        {
            CredFree(ptr);
        }
    }

    public void Delete() => CredDeleteW(_target, CRED_TYPE_GENERIC, 0);

    /// <summary>Findes værdien? Læser kun posten og frigiver den straks; værdien kopieres ikke.</summary>
    public bool Exists
    {
        get
        {
            if (!CredReadW(_target, CRED_TYPE_GENERIC, 0, out var ptr)) return false;
            CredFree(ptr);
            return true;
        }
    }

    public override string ToString() => $"WindowsCredentialStore({_target}, skjult)";

    // MARK: Win32

    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;
    private const int MaxBlobBytes = 5 * 512; // CRED_MAX_CREDENTIAL_BLOB_SIZE

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}

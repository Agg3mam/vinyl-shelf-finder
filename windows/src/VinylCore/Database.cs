using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;

namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/SQLite.swift: en tynd, synkron wrapper over SQLite.
// Samme SQL som på Mac (med ? som pladsholder), så resten af koden kan porteres uændret.

/// Fejl fra databasen. `Message` er teknisk og hører kun hjemme i logs.
/// `UserMessage` er det, appen viser: altid almindeligt dansk.
public sealed class DatabaseException : Exception
{
    /// true når beskeden er skrevet til brugeren (fx "Sektionen er ikke tom …").
    public bool UserFacing { get; }

    public DatabaseException(string message, bool userFacing = false, Exception? inner = null)
        : base(message, inner) => UserFacing = userFacing;

    /// Det, appen viser: brugerens tekst, eller en almindelig dansk besked.
    public string UserMessage => UserFacing ? Message : "Der opstod en fejl i databasen. Prøv igen.";

    public override string ToString() => $"SQLite: {Message}";
}

/// Én række fra en forespørgsel: kolonnenavn → værdi (long, double, string eller null).
public sealed class SqlRow
{
    private readonly Dictionary<string, object?> _values;
    internal SqlRow(Dictionary<string, object?> values) => _values = values;

    public object? this[string column] => _values.TryGetValue(column, out var v) ? v : null;
    public IReadOnlyDictionary<string, object?> Values => _values;

    public long? Long(string column) => AsLong(this[column]);
    public int? Int(string column) => AsLong(this[column]) is long l && l >= int.MinValue && l <= int.MaxValue ? (int)l : null;
    public double? Double(string column) => AsDouble(this[column]);
    public string? Text(string column) => AsText(this[column]);

    /// Som SQLValue.int på Mac. En REAL uden for long's område (eller NaN) giver null, ikke et crash.
    public static long? AsLong(object? v) => v switch
    {
        long l => l,
        int i => i,
        double d => double.IsFinite(d) && d >= -9.2e18 && d <= 9.2e18 ? (long)d : null,
        string s => long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var l) ? l : null,
        _ => null,
    };

    public static double? AsDouble(object? v) => v switch
    {
        long l => l,
        int i => i,
        double d => d,
        string s => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null,
        _ => null,
    };

    public static string? AsText(object? v) => v switch
    {
        string s => s,
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        _ => null,
    };
}

/// Minimal, synkron SQLite-wrapper med WAL og fremmednøgler slået til.
/// Alle kald går gennem én lås, så den tåler at blive brugt fra flere tråde.
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _conn;
    private readonly object _gate = new();

    public string Path { get; }

    public Database(string path)
    {
        Path = path;
        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            // Ingen pulje: filen skal lukkes, når databasen lukkes (backup, sletning, flere processer).
            Pooling = false,
        }.ToString();
        _conn = new SqliteConnection(cs);
        try
        {
            _conn.Open();
            Execute("PRAGMA journal_mode=WAL;");
            Execute("PRAGMA foreign_keys=ON;");
        }
        catch (Exception e)
        {
            _conn.Dispose();
            throw e as DatabaseException ?? new DatabaseException(e.Message, inner: e);
        }
    }

    public void Dispose()
    {
        lock (_gate) _conn.Dispose();
    }

    /// Kører én eller flere SQL-sætninger uden parametre.
    public void Execute(string sql)
    {
        lock (_gate)
        {
            try
            {
                using var cmd = _conn.CreateCommand();
                cmd.CommandText = sql;
                cmd.ExecuteNonQuery();
            }
            catch (SqliteException e) { throw new DatabaseException($"{e.Message} i: {sql}", inner: e); }
        }
    }

    /// Kører en sætning med parametre (bundet til ? i rækkefølge). Returnerer last_insert_rowid.
    public long Run(string sql, params object?[]? args)
    {
        lock (_gate)
        {
            try
            {
                using var cmd = Prepare(sql, args);
                cmd.ExecuteNonQuery();
                using var id = _conn.CreateCommand();
                id.CommandText = "SELECT last_insert_rowid()";
                return (long)(id.ExecuteScalar() ?? 0L);
            }
            catch (SqliteException e) { throw new DatabaseException($"{e.Message} i: {sql}", inner: e); }
        }
    }

    public List<SqlRow> Query(string sql, params object?[]? args)
    {
        lock (_gate)
        {
            try
            {
                using var cmd = Prepare(sql, args);
                using var reader = cmd.ExecuteReader();
                var rows = new List<SqlRow>();
                while (reader.Read())
                {
                    var row = new Dictionary<string, object?>(reader.FieldCount);
                    for (int i = 0; i < reader.FieldCount; i++)
                    {
                        var v = reader.IsDBNull(i) ? null : reader.GetValue(i);
                        row[reader.GetName(i)] = v is byte[] ? null : v;
                    }
                    rows.Add(new SqlRow(row));
                }
                return rows;
            }
            catch (SqliteException e) { throw new DatabaseException($"{e.Message} i: {sql}", inner: e); }
        }
    }

    public int UserVersion
    {
        get
        {
            try { return (int)(Query("PRAGMA user_version").FirstOrDefault()?.Long("user_version") ?? 0); }
            catch (DatabaseException) { return 0; }
        }
        set
        {
            try { Execute($"PRAGMA user_version = {value}"); } catch (DatabaseException) { }
        }
    }

    /// Kører `body` i en transaktion. Ruller tilbage ved fejl.
    public T Transaction<T>(Func<T> body)
    {
        lock (_gate)
        {
            Execute("BEGIN IMMEDIATE");
            try
            {
                var result = body();
                Execute("COMMIT");
                return result;
            }
            catch
            {
                try { Execute("ROLLBACK"); } catch (DatabaseException) { }
                throw;
            }
        }
    }

    public void Transaction(Action body) => Transaction<object?>(() => { body(); return null; });

    private SqliteCommand Prepare(string sql, object?[]? args)
    {
        args ??= new object?[] { null };
        var cmd = _conn.CreateCommand();
        cmd.CommandText = NumberPlaceholders(sql);
        for (int i = 0; i < args.Length; i++)
            cmd.Parameters.AddWithValue("?" + (i + 1).ToString(CultureInfo.InvariantCulture), ToSql(args[i]));
        return cmd;
    }

    private static object ToSql(object? v) => v switch
    {
        null => DBNull.Value,
        bool b => b ? 1L : 0L,
        int i => (long)i,
        long l => l,
        double d => d,
        float f => (double)f,
        string s => s,
        CopyStatus st => st.RawValue(),
        HistoryKind k => k.RawValue(),
        _ => v.ToString() ?? "",
    };

    /// "? , ?" → "?1, ?2", så Microsoft.Data.Sqlite kan binde dem. Tekst i '…' og "…" røres ikke.
    internal static string NumberPlaceholders(string sql)
    {
        var sb = new StringBuilder(sql.Length + 16);
        int n = 0;
        char quote = '\0';
        for (int i = 0; i < sql.Length; i++)
        {
            char c = sql[i];
            if (quote != '\0')
            {
                if (c == quote) quote = '\0';
                sb.Append(c);
                continue;
            }
            if (c == '\'' || c == '"') { quote = c; sb.Append(c); continue; }
            if (c == '?' && !(i + 1 < sql.Length && char.IsDigit(sql[i + 1])))
            {
                n++;
                sb.Append('?').Append(n.ToString(CultureInfo.InvariantCulture));
                continue;
            }
            sb.Append(c);
        }
        return sb.ToString();
    }
}

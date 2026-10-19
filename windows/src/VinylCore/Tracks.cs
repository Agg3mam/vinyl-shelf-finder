using System.Text.Json.Nodes;

namespace VinylShelfFinder.Core;

// Sanglister fra Discogs, så man kan søge på en sang uden at huske albummet.
// Port af Sources/VinylCore/Tracks.swift. Hentes i baggrunden én udgivelse ad gangen (Discogs' grænse),
// og følger med til de andre enheder via kontoen (feltet "tracks" i udgivelsens post).

public sealed partial class DiscogsClient
{
    /// Sanglisten for én udgivelse (/releases/{id}).
    public async Task<List<Track>> TracklistAsync(int releaseId, CancellationToken ct = default) =>
        ParseTracklist(await GetAsync($"/releases/{releaseId}", ct: ct).ConfigureAwait(false));

    /// Kun sange: overskrifter ("heading") springes over, og et nummer delt i dele ("index") giver delene.
    public static List<Track> ParseTracklist(byte[] data)
    {
        JsonObject o;
        try { o = JsonNode.Parse(data) as JsonObject ?? throw DiscogsException.Decoding("sanglisten"); }
        catch (System.Text.Json.JsonException) { throw DiscogsException.Decoding("sanglisten"); }
        var list = new List<Track>();
        void Add(JsonArray? items)
        {
            foreach (var t in items?.OfType<JsonObject>() ?? Enumerable.Empty<JsonObject>())
            {
                string Str(string k) => t[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s.Trim() : "";
                switch (Str("type_") is { Length: > 0 } type ? type : "track")
                {
                    case "heading": break;
                    case "index": Add(t["sub_tracks"] as JsonArray); break;
                    default:
                        var title = Str("title");
                        if (title.Length == 0) break;
                        var d = Str("duration");
                        list.Add(new Track(Str("position"), title, d.Length == 0 ? null : d));
                        break;
                }
            }
        }
        Add(o["tracklist"] as JsonArray);
        return list;
    }
}

public sealed partial class ShelfStore
{
    /// Alle hentede sanglister.
    internal Dictionary<int, List<Track>> LoadTracks()
    {
        var out_ = new Dictionary<int, List<Track>>();
        foreach (var r in Db.Query("SELECT release_id, position, title, duration FROM release_tracks ORDER BY release_id, idx"))
        {
            var id = (int)r.Long("release_id")!.Value;
            if (!out_.TryGetValue(id, out var l)) out_[id] = l = new();
            l.Add(new Track(r.Text("position") ?? "", r.Text("title") ?? "", r.Text("duration")));
        }
        return out_;
    }

    /// Gemmer (erstatter) sanglisten for én udgivelse og husker, at den er hentet.
    public void SaveTracks(int releaseId, IReadOnlyList<Track> tracks) => Db.Transaction(() => WriteTracks(releaseId, tracks));

    /// Uden egen transaktion (bruges også, når poster fra skyen lægges ind).
    internal void WriteTracks(long releaseId, IReadOnlyList<Track> tracks)
    {
        Db.Run("DELETE FROM release_tracks WHERE release_id = ?", releaseId);
        for (int i = 0; i < tracks.Count; i++)
            Db.Run("INSERT INTO release_tracks(release_id, idx, position, title, duration) VALUES(?, ?, ?, ?, ?)",
                   releaseId, (long)i, tracks[i].Position, tracks[i].Title, tracks[i].Duration);
        Db.Run("UPDATE releases SET tracks_fetched_at = ? WHERE discogs_release_id = ?", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0, releaseId);
    }

    /// Udgivelser i samlingen, hvis sangliste ikke er hentet endnu (laveste ID først).
    public List<int> ReleasesWithoutTracks() =>
        Db.Query("""
            SELECT DISTINCT r.discogs_release_id AS id FROM releases r JOIN copies c ON c.release_id = r.discogs_release_id
            WHERE r.tracks_fetched_at IS NULL ORDER BY r.discogs_release_id
            """).Select(r => (int)r.Long("id")!.Value).ToList();

    /// (hentet, i alt) for udgivelser i samlingen.
    public (int Done, int Total) TrackProgress()
    {
        var r = Db.Query("""
            SELECT COUNT(DISTINCT r.discogs_release_id) AS total,
                   COUNT(DISTINCT CASE WHEN r.tracks_fetched_at IS NOT NULL THEN r.discogs_release_id END) AS done
            FROM releases r JOIN copies c ON c.release_id = r.discogs_release_id
            """).FirstOrDefault();
        return ((int)(r?.Long("done") ?? 0), (int)(r?.Long("total") ?? 0));
    }
}

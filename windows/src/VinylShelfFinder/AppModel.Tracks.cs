using VinylShelfFinder.Core;

namespace VinylShelfFinder;

// Sanglister fra Discogs i baggrunden, så man kan søge på en sang (port af AppModel+Tracks.swift).
// Starter efter en Discogs-synkronisering (eller med "Hent sanglister" i Indstillinger › Discogs) og henter kun
// de udgivelser, der mangler. Én ad gangen gennem Discogs-køen, så resten af appen ikke rammer grænsen.
public sealed partial class AppModel
{
    private (int Done, int Total) _trackProgress;
    public (int Done, int Total) TrackProgress { get => _trackProgress; private set => Set(ref _trackProgress, value); }
    private bool _fetchingTracks;
    public bool FetchingTracks { get => _fetchingTracks; private set => Set(ref _fetchingTracks, value); }

    public void RefreshTrackProgress()
    {
        try { TrackProgress = Store.TrackProgress(); } catch { }
    }

    /// Fra Indstillinger: læser tokenet og starter hentningen.
    public void FetchTracksNow()
    {
        string? token = null;
        try { token = _token.Load(); } catch { }
        if (token is not null) FetchTracks(token);
    }

    private void FetchTracks(string token)
    {
        if (IsDemo || FetchingTracks) return;
        List<int> missing;
        try { missing = Store.ReleasesWithoutTracks(); } catch { return; }
        RefreshTrackProgress();
        if (missing.Count == 0) return;
        FetchingTracks = true;
        _ = FetchTracksAsync(new DiscogsClient(token), missing);
    }

    private async Task FetchTracksAsync(DiscogsClient client, List<int> missing)
    {
        int sinceReload = 0;
        try
        {
            foreach (var id in missing)
            {
                try
                {
                    var tracks = await client.TracklistAsync(id);
                    Store.SaveTracks(id, tracks);
                }
                catch (DiscogsException e) when (e.IsNotFound)
                {
                    // Findes ikke længere på Discogs: husk den som hentet (uden sange), så den ikke prøves igen og igen.
                    Store.SaveTracks(id, Array.Empty<Track>());
                }
                catch (Exception)
                {
                    break; // fx ingen forbindelse: prøv igen ved næste synkronisering
                }
                RefreshTrackProgress();
                // Søgningen får de nye sange med jævne mellemrum (ikke for hver plade).
                if (++sinceReload >= 25) { sinceReload = 0; Reload(); }
            }
        }
        finally
        {
            FetchingTracks = false;
            Reload();
        }
    }
}

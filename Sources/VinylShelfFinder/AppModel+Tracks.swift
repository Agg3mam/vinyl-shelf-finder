import Foundation
import VinylCore

// Sanglister fra Discogs i baggrunden, så man kan søge på en sang. Samme forløb som Windows (AppModel.Tracks.cs).
// Starter efter en Discogs-synkronisering (eller med "Hent sanglister" i Indstillinger › Discogs) og henter kun
// de udgivelser, der mangler. Én ad gangen gennem Discogs-køen, så resten af appen ikke rammer grænsen.
extension AppModel {
    func refreshTrackProgress() {
        trackProgress = (try? store.trackProgress()) ?? (0, 0)
    }

    var fetchingTracks: Bool { trackTask != nil }

    /// Fra Indstillinger: læser tokenet (kan give en nøglering-dialog) og starter hentningen.
    func fetchTracksNow() {
        guard !isDemo, let token = Keychain.loadToken() else { return }
        fetchTracks(token: token)
    }

    func fetchTracks(token: String) {
        guard !isDemo, trackTask == nil else { return }
        let missing = (try? store.releasesWithoutTracks()) ?? []
        refreshTrackProgress()
        guard !missing.isEmpty else { return }
        let client = DiscogsClient(token: token)
        trackTask = Task { [weak self] in
            var sinceReload = 0
            for id in missing {
                guard !Task.isCancelled, let self else { break }
                do {
                    let tracks = try await client.tracklist(releaseID: id)
                    try self.store.saveTracks(releaseID: id, tracks)
                } catch DiscogsError.http(404) {
                    // Findes ikke længere på Discogs: husk den som hentet (uden sange), så den ikke prøves igen og igen.
                    try? self.store.saveTracks(releaseID: id, [])
                } catch {
                    break // fx ingen forbindelse: prøv igen ved næste synkronisering
                }
                sinceReload += 1
                self.refreshTrackProgress()
                // Søgningen får de nye sange med jævne mellemrum (ikke for hver plade).
                if sinceReload >= 25 { sinceReload = 0; self.reload() }
            }
            self?.trackTask = nil
            self?.reload()
        }
    }
}

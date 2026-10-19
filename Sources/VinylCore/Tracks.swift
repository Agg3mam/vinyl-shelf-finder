import Foundation

// Sanglister fra Discogs, så man kan søge på en sang uden at huske albummet.
// Port: windows/src/VinylCore/Tracks.cs. Hentes i baggrunden én udgivelse ad gangen (Discogs' grænse),
// og følger med til de andre enheder via kontoen (feltet "tracks" i udgivelsens post).

extension DiscogsClient {
    /// Sanglisten for én udgivelse (/releases/{id}).
    public func tracklist(releaseID: Int) async throws -> [Track] {
        try Self.parseTracklist(try await get("/releases/\(releaseID)"))
    }

    /// Kun sange: overskrifter (`heading`) springes over, og et nummer delt i dele (`index`) giver delene.
    public static func parseTracklist(_ data: Data) throws -> [Track] {
        struct T: Decodable {
            let position: String?
            let type_: String?
            let title: String?
            let duration: String?
            let sub_tracks: [T]?
        }
        struct R: Decodable { let tracklist: [T]? }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw DiscogsError.decoding("sanglisten") }
        func tracks(_ list: [T]) -> [Track] {
            list.flatMap { t -> [Track] in
                switch t.type_ ?? "track" {
                case "heading": return []
                case "index": return tracks(t.sub_tracks ?? [])
                default:
                    let title = (t.title ?? "").trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return [] }
                    let d = (t.duration ?? "").trimmingCharacters(in: .whitespaces)
                    return [Track(position: (t.position ?? "").trimmingCharacters(in: .whitespaces), title: title,
                                  duration: d.isEmpty ? nil : d)]
                }
            }
        }
        return tracks(r.tracklist ?? [])
    }
}

extension ShelfStore {
    /// Alle hentede sanglister.
    func loadTracks() throws -> [Int: [Track]] {
        var out: [Int: [Track]] = [:]
        for r in try db.query("SELECT release_id, position, title, duration FROM release_tracks ORDER BY release_id, idx") {
            out[Int(r["release_id"]!.int!), default: []].append(
                Track(position: r["position"]?.text ?? "", title: r["title"]?.text ?? "", duration: r["duration"]?.text))
        }
        return out
    }

    /// Gemmer (erstatter) sanglisten for én udgivelse og husker, at den er hentet.
    public func saveTracks(releaseID: Int, _ tracks: [Track]) throws {
        try db.transaction { try writeTracks(releaseID: releaseID, tracks) }
    }

    /// Uden egen transaktion (bruges også, når poster fra skyen lægges ind).
    func writeTracks(releaseID: Int, _ tracks: [Track]) throws {
        try db.run("DELETE FROM release_tracks WHERE release_id = ?", releaseID)
        for (i, t) in tracks.enumerated() {
            try db.run("INSERT INTO release_tracks(release_id, idx, position, title, duration) VALUES(?, ?, ?, ?, ?)",
                       releaseID, i, t.position, t.title, t.duration)
        }
        try db.run("UPDATE releases SET tracks_fetched_at = ? WHERE discogs_release_id = ?", Date().timeIntervalSince1970, releaseID)
    }

    /// Udgivelser i samlingen, hvis sangliste ikke er hentet endnu (nyeste i samlingen først er ligegyldigt; laveste ID først).
    public func releasesWithoutTracks() throws -> [Int] {
        try db.query("""
            SELECT DISTINCT r.discogs_release_id AS id FROM releases r JOIN copies c ON c.release_id = r.discogs_release_id
            WHERE r.tracks_fetched_at IS NULL ORDER BY r.discogs_release_id
            """).compactMap { $0["id"]?.int.map(Int.init) }
    }

    /// (hentet, i alt) for udgivelser i samlingen.
    public func trackProgress() throws -> (done: Int, total: Int) {
        let r = try db.query("""
            SELECT COUNT(DISTINCT r.discogs_release_id) AS total,
                   COUNT(DISTINCT CASE WHEN r.tracks_fetched_at IS NOT NULL THEN r.discogs_release_id END) AS done
            FROM releases r JOIN copies c ON c.release_id = r.discogs_release_id
            """).first
        return (Int(r?["done"]?.int ?? 0), Int(r?["total"]?.int ?? 0))
    }
}

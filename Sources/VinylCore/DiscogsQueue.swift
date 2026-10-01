import Foundation

// Fælles kø og cache for alle Discogs-kald i appen.
// Discogs tillader ca. 60 kald i minuttet (glidende vindue). Før lavede hver skærm sine egne kald,
// så hurtige klik gennem mange album kunne ramme grænsen og give pludselige ventetider.

/// Token-bucket: højst `capacity` kald i et hug, derefter `perMinute` i minuttet.
/// Ren værdi (tiden gives udefra), så den kan tjekkes uden at vente.
/// Værste fald i ét minut er `capacity + perMinute` kald; standarden 15 + 45 = 60.
public struct TokenBucket: Sendable, Equatable {
    public let capacity: Double
    public let perSecond: Double
    public private(set) var tokens: Double
    private var updated: TimeInterval
    /// Ingen kald før dette tidspunkt (fx når Discogs selv siger, at kvoten næsten er brugt).
    public private(set) var pausedUntil: TimeInterval = 0

    public init(capacity: Int = 15, perMinute: Int = 45, now: TimeInterval) {
        self.capacity = Double(max(1, capacity))
        self.perSecond = Double(max(1, perMinute)) / 60
        self.tokens = self.capacity
        self.updated = now
    }

    private mutating func refill(_ now: TimeInterval) {
        guard now > updated else { return }
        tokens = min(capacity, tokens + (now - updated) * perSecond)
        updated = now
    }

    /// Tager et kald, hvis det er muligt (returnerer 0). Ellers: sekunder til næste forsøg.
    public mutating func take(now: TimeInterval) -> TimeInterval {
        if now < pausedUntil { return pausedUntil - now }
        refill(now)
        if tokens >= 1 { tokens -= 1; return 0 }
        return (1 - tokens) / perSecond
    }

    /// Ingen kald i `seconds` sekunder, og bagefter starter spanden tom.
    public mutating func pause(_ seconds: TimeInterval, now: TimeInterval) {
        pausedUntil = max(pausedUntil, now + seconds)
        tokens = 0
        updated = max(updated, pausedUntil)
    }
}

/// Én fælles kø for alle Discogs-kald i appen. Kald, man venter på (søgning, udgaver, ønskeliste),
/// går foran baggrundskald (priser, Værdi-opdatering).
public actor DiscogsRateLimiter {
    public enum Priority: Sendable { case interactive, background }

    public static let shared = DiscogsRateLimiter()

    private var bucket: TokenBucket
    private var waitingInteractive = 0
    private let clock: @Sendable () -> TimeInterval

    public init(capacity: Int = 15, perMinute: Int = 45,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.bucket = TokenBucket(capacity: capacity, perMinute: perMinute, now: clock())
    }

    /// Venter, til der må sendes et kald. Kaster `CancellationError`, hvis opgaven annulleres.
    public func acquire(_ priority: Priority) async throws {
        if priority == .interactive { waitingInteractive += 1 }
        defer { if priority == .interactive { waitingInteractive -= 1 } }
        while true {
            try Task.checkCancellation()
            // Et baggrundskald venter, så længe et interaktivt kald står i kø.
            let wait: TimeInterval
            if priority == .background && waitingInteractive > 0 {
                wait = 0.1
            } else {
                wait = bucket.take(now: clock())
                if wait == 0 { return }
            }
            try await Task.sleep(nanoseconds: UInt64(min(max(wait, 0.05), 30) * 1_000_000_000))
        }
    }

    /// Discogs' svar fortæller, hvor mange kald der er tilbage i minuttet. Er der næsten ingen,
    /// holdes der pause for alle (i stedet for kun for det ene kald, der fik svaret).
    public func observe(remaining: Int?) {
        guard let remaining, remaining < 3 else { return }
        bucket.pause(3, now: clock())
    }

    /// Discogs svarede 429 (for mange kald): pause for alle.
    public func backOff(seconds: TimeInterval) {
        bucket.pause(seconds, now: clock())
    }
}

/// Lille cache i hukommelsen for Discogs-svar (søgninger og udgaver), så samme søgning eller
/// album ikke hentes igen inden for `maxAge`. Ens kald, der er i gang samtidig, lægges sammen
/// til ét. Kun vellykkede svar gemmes. De ældst brugte smides ud, når der er mere end `maxEntries`.
public actor DiscogsResponseCache {
    private struct Entry { let data: Data; let stored: TimeInterval; var used: UInt64 }

    public let maxEntries: Int
    public let maxAge: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var counter: UInt64 = 0

    public init(maxEntries: Int = 100, maxAge: TimeInterval = 10 * 60,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxEntries = max(1, maxEntries)
        self.maxAge = maxAge
        self.clock = clock
    }

    public var count: Int { entries.count }

    /// Svaret for `key` fra cachen, eller hentet med `load` (kun ét kald ad gangen pr. nøgle).
    public func data(for key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        counter += 1
        if var hit = entries[key] {
            if clock() - hit.stored <= maxAge {
                hit.used = counter
                entries[key] = hit
                return hit.data
            }
            entries[key] = nil
        }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await load() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        store(data, for: key)
        return data
    }

    private func store(_ data: Data, for key: String) {
        counter += 1
        entries[key] = Entry(data: data, stored: clock(), used: counter)
        while entries.count > maxEntries, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
    }

    public func removeAll() {
        entries.removeAll()
    }
}

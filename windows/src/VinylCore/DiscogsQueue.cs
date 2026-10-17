using System.Diagnostics;

namespace VinylShelfFinder.Core;

// Fælles kø og cache for alle Discogs-kald i appen.
// Discogs tillader ca. 60 kald i minuttet (glidende vindue). Før lavede hver skærm sine egne kald,
// så hurtige klik gennem mange album kunne ramme grænsen og give pludselige ventetider.

/// Token-bucket: højst Capacity kald i et hug, derefter perMinute i minuttet.
/// Ren værdi (tiden gives udefra i sekunder), så den kan tjekkes uden at vente.
/// Værste fald i ét minut er capacity + perMinute kald; standarden 15 + 45 = 60.
public struct TokenBucket : IEquatable<TokenBucket>
{
    public double Capacity { get; }
    public double PerSecond { get; }
    public double Tokens { get; private set; }
    private double _updated;
    /// Ingen kald før dette tidspunkt (fx når Discogs selv siger, at kvoten næsten er brugt).
    public double PausedUntil { get; private set; }

    public TokenBucket(int capacity = 15, int perMinute = 45, double now = 0)
    {
        Capacity = Math.Max(1, capacity);
        PerSecond = Math.Max(1, perMinute) / 60.0;
        Tokens = Capacity;
        _updated = now;
        PausedUntil = 0;
    }

    private void Refill(double now)
    {
        if (!(now > _updated)) return;
        Tokens = Math.Min(Capacity, Tokens + (now - _updated) * PerSecond);
        _updated = now;
    }

    /// Tager et kald, hvis det er muligt (returnerer 0). Ellers: sekunder til næste forsøg.
    public double Take(double now)
    {
        if (now < PausedUntil) return PausedUntil - now;
        Refill(now);
        if (Tokens >= 1) { Tokens -= 1; return 0; }
        return (1 - Tokens) / PerSecond;
    }

    /// Ingen kald i seconds sekunder, og bagefter starter spanden tom.
    public void Pause(double seconds, double now)
    {
        PausedUntil = Math.Max(PausedUntil, now + seconds);
        Tokens = 0;
        _updated = Math.Max(_updated, PausedUntil);
    }

    public bool Equals(TokenBucket o) =>
        Capacity == o.Capacity && PerSecond == o.PerSecond && Tokens == o.Tokens && _updated == o._updated && PausedUntil == o.PausedUntil;
    public override bool Equals(object? obj) => obj is TokenBucket b && Equals(b);
    public override int GetHashCode() => HashCode.Combine(Capacity, PerSecond, Tokens, _updated, PausedUntil);
}

/// Prioritet i den fælles kø.
public enum DiscogsPriority { Interactive, Background }

/// Én fælles kø for alle Discogs-kald i appen. Kald, man venter på (søgning, udgaver, ønskeliste),
/// går foran baggrundskald (priser, Værdi-opdatering).
public sealed class DiscogsRateLimiter
{
    // Skal stå før Shared (statiske felter initialiseres i rækkefølge).
    private static readonly Stopwatch Uptime = Stopwatch.StartNew();
    /// Sekunder siden start (monoton, som systemUptime på Mac).
    public static double MonotonicSeconds() => Uptime.Elapsed.TotalSeconds;

    public static DiscogsRateLimiter Shared { get; } = new();

    private readonly object _lock = new();
    private TokenBucket _bucket;
    private int _waitingInteractive;
    private readonly Func<double> _clock;
    private readonly double _maxSleep;

    /// maxSleep: længste ventetid (sekunder) før køen ser på uret igen. Checks med et falsk ur
    /// sætter den lavt, så de ikke venter rigtige sekunder.
    public DiscogsRateLimiter(int capacity = 15, int perMinute = 45, Func<double>? clock = null, double maxSleep = 30)
    {
        _clock = clock ?? MonotonicSeconds;
        _maxSleep = Math.Max(0.01, maxSleep);
        _bucket = new TokenBucket(capacity, perMinute, _clock());
    }

    /// Venter, til der må sendes et kald. Kaster OperationCanceledException, hvis opgaven annulleres.
    public async Task AcquireAsync(DiscogsPriority priority, CancellationToken ct = default)
    {
        if (priority == DiscogsPriority.Interactive) Interlocked.Increment(ref _waitingInteractive);
        try
        {
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                // Et baggrundskald venter, så længe et interaktivt kald står i kø.
                double wait;
                if (priority == DiscogsPriority.Background && Volatile.Read(ref _waitingInteractive) > 0)
                {
                    wait = 0.1;
                }
                else
                {
                    lock (_lock) wait = _bucket.Take(_clock());
                    if (wait == 0) return;
                }
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(Math.Max(wait, 0.05), _maxSleep)), ct).ConfigureAwait(false);
            }
        }
        finally
        {
            if (priority == DiscogsPriority.Interactive) Interlocked.Decrement(ref _waitingInteractive);
        }
    }

    /// Discogs' svar fortæller, hvor mange kald der er tilbage i minuttet. Er der næsten ingen,
    /// holdes der pause for alle (i stedet for kun for det ene kald, der fik svaret).
    public void Observe(int? remaining)
    {
        if (remaining is not int r || r >= 3) return;
        lock (_lock) _bucket.Pause(3, _clock());
    }

    /// Discogs svarede 429 (for mange kald): pause for alle.
    public void BackOff(double seconds)
    {
        lock (_lock) _bucket.Pause(seconds, _clock());
    }
}

/// Lille cache i hukommelsen for Discogs-svar (søgninger og udgaver), så samme søgning eller
/// album ikke hentes igen inden for MaxAge. Ens kald, der er i gang samtidig, lægges sammen
/// til ét. Kun vellykkede svar gemmes. De ældst brugte smides ud, når der er mere end MaxEntries.
public sealed class DiscogsResponseCache
{
    private sealed class Entry
    {
        public required byte[] Data;
        public required double Stored;
        public ulong Used;
    }

    public int MaxEntries { get; }
    /// Sekunder.
    public double MaxAge { get; }
    private readonly Func<double> _clock;
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly Dictionary<string, Task<byte[]>> _inFlight = new();
    private ulong _counter;

    public DiscogsResponseCache(int maxEntries = 100, double maxAge = 10 * 60, Func<double>? clock = null)
    {
        MaxEntries = Math.Max(1, maxEntries);
        MaxAge = maxAge;
        _clock = clock ?? DiscogsRateLimiter.MonotonicSeconds;
    }

    public int Count { get { lock (_lock) return _entries.Count; } }

    /// Svaret for key fra cachen, eller hentet med load (kun ét kald ad gangen pr. nøgle).
    /// ct afbryder kun ventetiden for denne kalder; et fælles kald kører færdigt.
    public Task<byte[]> DataAsync(string key, Func<Task<byte[]>> load, CancellationToken ct = default)
    {
        Task<byte[]> task;
        lock (_lock)
        {
            _counter++;
            if (_entries.TryGetValue(key, out var hit))
            {
                if (_clock() - hit.Stored <= MaxAge)
                {
                    hit.Used = _counter;
                    return Task.FromResult(hit.Data);
                }
                _entries.Remove(key);
            }
            if (!_inFlight.TryGetValue(key, out task!))
            {
                // Låsen holdes, mens opgaven lægges i _inFlight, så den først kan fjerne sig selv bagefter.
                task = Task.Run(async () =>
                {
                    try
                    {
                        var data = await load().ConfigureAwait(false);
                        lock (_lock) { _inFlight.Remove(key); Store(data, key); }
                        return data;
                    }
                    catch
                    {
                        lock (_lock) _inFlight.Remove(key);
                        throw;
                    }
                });
                _inFlight[key] = task;
            }
        }
        return ct.CanBeCanceled ? task.WaitAsync(ct) : task;
    }

    // Kaldes med låsen holdt.
    private void Store(byte[] data, string key)
    {
        _counter++;
        _entries[key] = new Entry { Data = data, Stored = _clock(), Used = _counter };
        while (_entries.Count > MaxEntries)
        {
            var oldest = _entries.MinBy(e => e.Value.Used).Key;
            _entries.Remove(oldest);
        }
    }

    public void RemoveAll()
    {
        lock (_lock) _entries.Clear();
    }
}

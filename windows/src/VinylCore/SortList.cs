using System.Globalization;

namespace VinylShelfFinder.Core;

/// Én linje i sorteringslisten. `Number` er pladsen i hele hylden (1, 2, 3 …); kopier, der er ude
/// af reolen, har ingen plads og intet nummer. `Location` er null for kopier uden plads endnu.
public sealed record SortListEntry(int? Number, RecordItem Item, Location? Location);

/// Sorteringslisten: hele rækkefølgen for én hylde (plader eller cd'er), så man kan stille den op
/// derhjemme. Discogs blander plader og cd'er; her står hver hylde for sig.
public static class SortList
{
    /// Med reoler: den fysiske rækkefølge, sektion for sektion, og til sidst kopierne uden plads (sorteret).
    /// Uden reoler: hele hylden sorteret efter reglerne (eller Discogs' rækkefølge).
    public static List<SortListEntry> Build(Library lib, SortRules rules)
    {
        var entries = new List<SortListEntry>();
        int n = 0;
        foreach (var loc in lib.Locations)
        {
            if (!lib.Sections.TryGetValue(loc.Id, out var ids)) continue;
            foreach (var id in ids)
            {
                if (lib.Item(id) is not RecordItem it) continue;
                entries.Add(new SortListEntry(it.Copy.Status.IsOnShelf() ? ++n : null, it, loc));
            }
        }
        foreach (var it in rules.Sorted(lib.Unplaced.Select(lib.Item).OfType<RecordItem>()))
            entries.Add(new SortListEntry(it.Copy.Status.IsOnShelf() ? ++n : null, it, null));
        return entries;
    }

    /// Kun linjer, der kan sættes flueben ved (dem, der står på hylden).
    public static int Countable(IEnumerable<SortListEntry> entries) => entries.Count(e => e.Number is not null);

    /// Den første linje uden flueben (til "Næste").
    public static SortListEntry? NextUnchecked(IEnumerable<SortListEntry> entries, IReadOnlySet<long> done) =>
        entries.FirstOrDefault(e => e.Number is not null && !done.Contains(e.Item.Id));
}

public sealed partial class ShelfStore
{
    /// "sort_checked_vinyl", "sort_checked_cd", "sort_checked_vinyl.jazz" …
    internal static string SortCheckedKey(ShelfKind k) => $"sort_checked_{k.RawValue}";

    /// Kopierne, der er sat flueben ved i sorteringslisten for én hylde.
    public HashSet<long> SortChecked(Medium medium) => SortChecked(new ShelfKind(medium));

    public HashSet<long> SortChecked(ShelfKind kind)
    {
        var raw = Setting(SortCheckedKey(kind)) ?? "";
        return raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                  .Select(s => long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : (long?)null)
                  .OfType<long>().ToHashSet();
    }

    public void SetSortChecked(Medium medium, long copyId, bool isChecked) => SetSortChecked(new ShelfKind(medium), copyId, isChecked);

    public void SetSortChecked(ShelfKind kind, long copyId, bool isChecked)
    {
        var set = SortChecked(kind);
        if (isChecked ? !set.Add(copyId) : !set.Remove(copyId)) return;
        SaveSortChecked(kind, set);
    }

    public void ClearSortChecked(Medium medium) => ClearSortChecked(new ShelfKind(medium));
    public void ClearSortChecked(ShelfKind kind) => SaveSortChecked(kind, new HashSet<long>());

    private void SaveSortChecked(ShelfKind kind, HashSet<long> set) =>
        SetSetting(SortCheckedKey(kind), string.Join(",", set.OrderBy(x => x).Select(x => x.ToString(CultureInfo.InvariantCulture))));
}

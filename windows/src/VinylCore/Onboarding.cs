namespace VinylShelfFinder.Core;

// Port af Sources/VinylCore/Onboarding.swift.

/// Hjælpere til den første opdeling af samlingen i reoler og sektioner.
public static class LayoutPlanner
{
    public sealed class SectionPlan
    {
        public Guid Id { get; } = Guid.NewGuid();
        public int Shelf { get; set; }
        public string Section { get; set; }
        public int Count { get; set; }

        public SectionPlan(int shelf, string section, int count)
        {
            Shelf = shelf; Section = section; Count = count;
        }
    }

    public static string SectionLetter(int i)
    {
        const string letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        return i >= 0 && i < letters.Length ? letters[i].ToString() : $"S{i + 1}";
    }

    /// Fordeler `total` plader jævnt over sektionerne (reol for reol).
    public static List<SectionPlan> EvenPlan(int total, IReadOnlyList<int> sectionsPerShelf)
    {
        var plans = new List<SectionPlan>();
        for (int s = 0; s < sectionsPerShelf.Count; s++)
            for (int i = 0; i < Math.Max(1, sectionsPerShelf[s]); i++)
                plans.Add(new SectionPlan(s + 1, SectionLetter(i), 0));
        if (plans.Count == 0) return plans;
        int @base = total / plans.Count, extra = total % plans.Count;
        for (int i = 0; i < plans.Count; i++) plans[i].Count = @base + (i < extra ? 1 : 0);
        return plans;
    }

    /// Ændrer antallet i sektion `index` ved at flytte grænsen til næste sektion
    /// (eller forrige, hvis det er den sidste). Summen bevares.
    public static void Adjust(List<SectionPlan> plans, int index, int newCount)
    {
        if (index < 0 || index >= plans.Count || plans.Count <= 1) return;
        int neighbor = index + 1 < plans.Count ? index + 1 : index - 1;
        int pool = plans[index].Count + plans[neighbor].Count;
        int c = Math.Max(0, Math.Min(newCount, pool));
        plans[index].Count = c;
        plans[neighbor].Count = pool - c;
    }

    /// Opdeler en sorteret liste efter planen.
    public static List<List<T>> Split<T>(IReadOnlyList<T> items, IReadOnlyList<SectionPlan> plan)
    {
        var output = new List<List<T>>();
        int i = 0;
        for (int n = 0; n < plan.Count; n++)
        {
            int end = n == plan.Count - 1 ? items.Count : Math.Min(items.Count, i + plan[n].Count);
            output.Add(items.Skip(i).Take(end - i).ToList());
            i = end;
        }
        return output;
    }
}

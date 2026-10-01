import SwiftUI
import AppKit
import VinylCore

// MARK: - Hvad skal jeg høre?
//
// Midterkolonnen er betjeningen: filtre, "Giv mig en plade" og én kompakt linje med det
// aktuelle forslag. Selve pladen vises kun ét sted – som plade-detalje (pladeskærm) i
// højre kolonne, fordi `pickRecord()` også vælger pladen.

struct ListenView: View {
    @Environment(AppModel.self) private var model
    /// Kun til snapshot: vis denne plade i stedet for et tilfældigt valg (deterministisk).
    var previewPick: Int64? = nil

    var body: some View {
        let items = model.library.allItems
        let genres = ListenPicker.genres(in: items)
        let candidates = ListenPicker.candidates(items, library: model.library, filter: model.listenFilter, stats: model.stats)
        // Ingen kandidater → intet (gammelt) forslag.
        let pickID = candidates.isEmpty ? nil : (previewPick ?? model.currentPick)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ListenFilterForm(genres: genres)
                    .frame(height: genres.isEmpty ? 104 : 142)
                PickButton(disabled: candidates.isEmpty)
                if candidates.isEmpty {
                    NoMatchNote()
                } else {
                    Text("\(candidates.count) plader matcher · plader du ikke har hørt længe foreslås oftere · mellemrum = ny plade")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pickID {
                    CurrentPickLine(pickID: pickID)
                        .padding(.top, Spacing.xs)
                } else if !candidates.isEmpty {
                    Label("Tryk “Giv mig en plade” (eller mellemrum), så foreslår appen en plade.", systemImage: "dice")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.xs)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // 1 pt luft over rullefladen: rører den værktøjslinjen, viser macOS en lys
        // værktøjslinje-flade hen over hele vinduet – også over den mørke plade-detalje.
        .padding(.top, 1)
        .navigationTitle("Hvad skal jeg høre?")
        .onAppear {
            // Højre kolonne skal vise det samme forslag som midterkolonnen.
            if previewPick == nil, !candidates.isEmpty, let p = model.currentPick, model.library.item(p) != nil {
                model.selection = p
            }
        }
        .onChange(of: candidates.isEmpty) { _, empty in
            guard previewPick == nil else { return }
            if empty {
                if model.selection == model.currentPick { model.selection = nil }
            } else if model.selection == nil, let p = model.currentPick, model.library.item(p) != nil {
                model.selection = p
            }
        }
    }
}

private struct ListenFilterForm: View {
    @Environment(AppModel.self) private var model
    let genres: [String]

    var body: some View {
        @Bindable var model = model
        let decades = ListenPicker.decades(in: model.library.allItems)

        Form {
            Picker("Hvilke", selection: $model.listenFilter.freshness) {
                ForEach(ListenFilter.Freshness.allCases) { Text($0.label).tag($0) }
            }
            if !genres.isEmpty {
                Picker("Genre", selection: $model.listenFilter.genre) {
                    Text("Alle genrer").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Picker("Årti", selection: $model.listenFilter.decade) {
                Text("Alle årtier").tag(Int?.none)
                ForEach(decades, id: \.self) { Text("\(String($0))'erne").tag(Int?.some($0)) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        // Formens egen yderkant fjernes, så den flugter med resten af indholdet.
        .padding(.horizontal, -Spacing.l)
    }
}

private struct PickButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let disabled: Bool

    var body: some View {
        Button {
            // Mellemrum er genvej til knappen, men en tast-genvej fanges før tekstfelter.
            // Skriver brugeren i et tekstfelt i samme vindue (fx "Sortering" i
            // plade-detaljen ved siden af), skal mellemrummet i teksten – ikke give en ny plade.
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                editor.insertText(" ", replacementRange: editor.selectedRange())
                return
            }
            model.pickRecord()
        } label: {
            Label {
                Text("Giv mig en plade")
            } icon: {
                Image(systemName: "dice")
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? nil : model.currentPick)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(disabled)
    }
}

/// Ingen plader matcher: sig venligt, hvilket filter man kan løsne.
private struct NoMatchNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var message: String {
        let f = model.listenFilter
        let items = model.library.allItems
        func matches(_ g: ListenFilter) -> Bool {
            !ListenPicker.candidates(items, library: model.library, filter: g, stats: model.stats).isEmpty
        }
        var tips: [String] = []
        if f.genre != nil, matches({ var g = f; g.genre = nil; return g }()) { tips.append("“Alle genrer”") }
        if f.decade != nil, matches({ var g = f; g.decade = nil; return g }()) { tips.append("“Alle årtier”") }
        if f.freshness != .any, matches({ var g = f; g.freshness = .any; return g }()) { tips.append("“Alle plader”") }
        if tips.isEmpty {
            return matches(ListenFilter())
                ? "Ingen plader passer til den kombination. Nulstil et par af filtrene, så kommer der forslag igen."
                : "Der står ingen plader i reolen endnu, som kan foreslås."
        }
        let list = tips.count == 1 ? tips[0] : tips.dropLast().joined(separator: ", ") + " eller " + tips.last!
        return "Ingen plader passer til filtrene lige nu. Prøv \(list) – så er der plader at vælge imellem."
    }
}

/// Det aktuelle forslag som én kompakt linje (lille cover og titel). Selve pladen står i
/// højre kolonne. Ved et nyt forslag toner den gamle linje helt ud, før den nye toner ind,
/// så to titler aldrig ses oven i hinanden.
private struct CurrentPickLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pickID: Int64
    @ViewState private var shown: Int64?
    @ViewState private var visible = true

    var body: some View {
        let id = shown ?? pickID
        Group {
            if let it = model.library.item(id) {
                Button { model.selection = it.id } label: { row(it) }
                    .buttonStyle(.plain)
                    .help("Vis forslaget")
            }
        }
        .opacity(visible ? 1 : 0)
        .task(id: pickID) {
            guard shown != pickID else { return }
            guard shown != nil, !reduceMotion else {
                shown = pickID
                visible = true
                return
            }
            withAnimation(.easeOut(duration: 0.08)) { visible = false }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            shown = pickID
            withAnimation(.easeIn(duration: 0.14)) { visible = true }
        }
    }

    private func row(_ it: RecordItem) -> some View {
        HStack(spacing: Spacing.s) {
            CoverView(release: it.release, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Forslag").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(it.title).font(.headline).lineLimit(2)
                Text(it.artist).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: Spacing.xs)
            if let loc = model.library.location(of: it.id) {
                LocationBadge(text: loc.shortName)
                    .help(loc.name)
            }
        }
        .padding(Spacing.s)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Registrerer en afspilning fra en knap og giver besked, hvis den ikke blev talt med
/// (samme plade er allerede registreret for lidt siden).
@MainActor @Observable
final class PlayFeedback {
    static let shared = PlayFeedback()
    private(set) var duplicateCopy: Int64?
    private(set) var duplicateToken = 0

    static func logPlay(_ model: AppModel, _ copyID: Int64) {
        if !model.logPlay(copyID) {
            shared.duplicateCopy = copyID
            shared.duplicateToken += 1
        }
    }
}

/// Checkmærket på "Spillet": en kort bekræftelse (bounce), hver gang pladen
/// registreres – også via ⌘L i menuen. Ingen bevægelse ved "Reducér bevægelse".
struct PlayedIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copyID: Int64

    var body: some View {
        let count = model.stats.count[copyID] ?? 0
        Image(systemName: "checkmark.circle")
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : count)
    }
}

struct PlayCountLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copyID: Int64
    /// Tekstfarve. Standard er systemets sekundære; pladeskærme sender `Ink.secondary`.
    var ink: Color? = nil

    var body: some View {
        let n = model.stats.count[copyID] ?? 0
        Group {
            if let last = model.stats.lastPlayed[copyID] {
                // Kun tallet tæller op; resten af sætningen skifter uden at sløre.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("Hørt")
                    Text("\(n)")
                        .contentTransition(Motion.numberTransition(reduceMotion))
                        .animation(Motion.number(reduceMotion), value: n)
                    Text("\(n == 1 ? "gang" : "gange") · sidst \(DanishDate.relative(last))")
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Aldrig registreret som spillet")
            }
        }
        .font(.caption)
        .foregroundStyle(ink.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

// MARK: - Lyttelog  (følger systemets lyse/mørke tilstand – ingen scene)

/// Hver række i lyttelogen har sit eget id – samme plade kan stå i både "Mest spillet"
/// og "Seneste" (og flere gange i "Seneste"), uden at flere rækker markeres på én gang.
enum PlaysRow: Hashable {
    case most(copy: Int64)
    case recent(play: Int64, copy: Int64)

    var copyID: Int64 {
        switch self {
        case .most(let c), .recent(_, let c): return c
        }
    }
}

struct PlaysView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var row: PlaysRow?

    var body: some View {
        let stats = model.stats

        List(selection: $row) {
            Section {
                PlaysStats()
                    .padding(.vertical, Spacing.xs)
                    .selectionDisabled()
            }

            if stats.plays.isEmpty {
                Label("Tryk “Spillet” på en plade, når du har hørt den – så bygges loggen op her.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else {
                MostPlayedSection()
                RecentPlaysSection()
            }
        }
        .listStyle(.inset)
        // Se `ListenView`: undgår det lyse bånd over den mørke plade-detalje.
        .padding(.top, 1)
        .navigationTitle("Lyttelog")
        .onChange(of: row) { _, r in
            if let r { model.selection = r.copyID }
        }
        .onChange(of: model.selection) { _, s in
            if row?.copyID != s { row = nil }
        }
    }
}

private struct PlaysStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        let onShelf = model.library.allItems.filter { $0.copy.inDiscogs }
        let neverPlayed = onShelf.filter { stats.count[$0.id] == nil }.count
        let monthAgo = Date().addingTimeInterval(-30 * 86400)

        let a = PlayStat(label: "Afspilninger", value: "\(stats.plays.count)", symbol: "play.circle.fill")
        let b = PlayStat(label: "Sidste 30 dage", value: "\(stats.plays(since: monthAgo))", symbol: "calendar")
        let c = PlayStat(label: "Forskellige plader", value: "\(stats.count.count)", symbol: "opticaldisc")
        let d = PlayStat(label: "Aldrig spillet", value: "\(neverPlayed)", symbol: "moon.zzz.fill")

        // Bred: én række. Smal: 2 × 2, så etiketterne ikke brydes midt i ord.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) { a; b; c; d }
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                GridRow { a; b }
                GridRow { c; d }
            }
        }
    }
}

private struct PlayStat: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Label(label, systemImage: symbol)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MostPlayedSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Mest spillet") {
            ForEach(model.stats.mostPlayed(limit: 10), id: \.copyID) { entry in
                if let it = model.library.item(entry.copyID) {
                    HStack(spacing: Spacing.s) {
                        RecordRow(item: it)
                        Text("\(entry.count)×").font(.callout.monospacedDigit().weight(.semibold))
                    }
                    .tag(PlaysRow.most(copy: it.id))
                }
            }
        }
    }
}

private struct RecentPlaysSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Seneste") {
            ForEach(model.stats.plays.prefix(50)) { play in
                if let it = model.library.item(play.copyID) {
                    HStack(spacing: Spacing.s) {
                        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                            Text(it.fullName).lineLimit(2)
                            Text(DanishDate.dateTime(play.playedAt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: Spacing.s)
                        Button {
                            model.deletePlay(play.id)
                        } label: {
                            Label("Fortryd", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                    }
                    .tag(PlaysRow.recent(play: play.id, copy: it.id))
                }
            }
        }
    }
}

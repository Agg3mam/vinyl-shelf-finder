import SwiftUI
import VinylCore

/// "Hvad skal jeg høre?" som på Mac (samme filtre og `ListenPicker`: plader, du ikke har hørt længe, foreslås oftere).
/// "Giv mig en plade" får Cover Flow til at snurre hen til forslaget. Hvid baggrund som Cover Flow på Mac.
struct ListenView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var center = 0
    /// Pladen, Cover Flow snurrer hen til (nil, når den er landet).
    @State private var spinTarget: Int?
    @State private var open: RecordRoute?

    var body: some View {
        @Bindable var model = model
        let lib = model.library
        let shelf = lib.locations.flatMap { lib.items(in: $0.id) }
        let all = lib.allItems
        let cands = ListenPicker.candidates(all, library: lib, filter: model.listenFilter, stats: model.stats)
        let genres = ListenPicker.genres(in: all)
        let decades = ListenPicker.decades(in: all)
        ScrollView {
            VStack(spacing: 14) {
                if model.media.count > 1 {
                    Picker("Hylde", selection: $model.medium) {
                        ForEach(model.media) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                PhoneCoverFlow(items: shelf, center: $center, spin: $spinTarget) { open = RecordRoute(medium: model.medium, copyID: $0.id) }
                    .frame(height: 260)
                CoverFlowCaption(item: shelf.indices.contains(center) ? shelf[center] : nil, library: lib, showsSection: true) {
                    open = RecordRoute(medium: model.medium, copyID: $0.id)
                }
                Button { spin(cands, shelf) } label: {
                    Label("Giv mig en plade", systemImage: "dice")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(cands.isEmpty || spinTarget != nil)
                .padding(.horizontal)
                Text(cands.isEmpty ? noMatch(all, lib)
                     : "\(cands.count) \(model.medium.plural) matcher · \(model.medium.plural) du ikke har hørt længe foreslås oftere")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                VStack(spacing: 0) {
                    filterRow("Hvilke") {
                        Picker("Hvilke", selection: $model.listenFilter.freshness) {
                            ForEach(ListenFilter.Freshness.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if !genres.isEmpty {
                        Divider().padding(.leading)
                        filterRow("Genre") {
                            Picker("Genre", selection: $model.listenFilter.genre) {
                                Text("Alle genrer").tag(String?.none)
                                ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                    }
                    Divider().padding(.leading)
                    filterRow("Årti") {
                        Picker("Årti", selection: $model.listenFilter.decade) {
                            Text("Alle årtier").tag(Int?.none)
                            ForEach(decades, id: \.self) { Text("\(String($0))'erne").tag(Int?.some($0)) }
                        }
                    }
                }
                .background(Color(white: 0.95), in: .rect(cornerRadius: 14))
                .padding(.horizontal)
            }
            .padding(.vertical)
            .padding(.bottom, 40)
        }
        .whiteStage()
        .navigationTitle("Hvad skal jeg høre?")
        .navigationDestination(item: $open) { RecordView(route: $0) }
        .onAppear {
            if let p = model.currentPick, let i = shelf.firstIndex(where: { $0.id == p }) { center = i }
        }
        .onChange(of: model.medium) { center = 0 }
    }

    private func filterRow(_ title: String, @ViewBuilder _ picker: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            picker().pickerStyle(.menu).labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Tilfældig plade (vægtet som på Mac); Cover Flow snurrer derhen (se `PhoneCoverFlow.spin`).
    private func spin(_ cands: [RecordItem], _ shelf: [RecordItem]) {
        var rng = SystemRandomNumberGenerator()
        guard let pick = ListenPicker.pick(from: cands, stats: model.stats, avoiding: model.recentPicks, using: &rng),
              let target = shelf.firstIndex(where: { $0.id == pick.id }) else { return }
        model.rememberPick(pick.id)
        spinTarget = target
    }

    /// Ingen plader matcher: sig venligt, hvilket filter man kan løsne (samme tekster som Mac).
    private func noMatch(_ items: [RecordItem], _ lib: Library) -> String {
        let f = model.listenFilter
        func matches(_ g: ListenFilter) -> Bool { !ListenPicker.candidates(items, library: lib, filter: g, stats: model.stats).isEmpty }
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

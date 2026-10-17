import SwiftUI
import VinylCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Demo-tilstanden bruger eksempelplader i stedet for Discogs, så trin 1 regnes for klaret.
    private var step1Done: Bool { model.hasToken || model.isDemo }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.medium == .cd ? "Dine cd'er" : "Vinyl Shelf Finder").font(.system(size: 34, weight: .heavy))
                        Spacer()
                        if model.showsMediumPicker { MediumPicker() }
                    }
                    Text(model.medium == .cd
                         ? "Cd'erne får deres egne reoler og sektioner. Dine plader og deres placeringer røres ikke."
                         : "Find dine plader i reolen. Tre trin, så er du i gang.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                StepBox(number: 1, title: "Forbind til Discogs", done: step1Done) { ConnectStep() }
                // Trinnene bliver færdige i rækkefølge: trin 2 krydses aldrig af før trin 1.
                StepBox(number: 2, title: "Hent din samling fra Discogs", done: step1Done && !model.library.copies.isEmpty) { ImportStep() }
                    .disabled(!model.hasToken)
                    .opacity(step1Done ? 1 : 0.5)
                StepBox(number: 3, title: "Fortæl hvor reoler og sektioner starter og slutter", done: false) { LayoutStep() }
                    .disabled(model.library.copies.isEmpty)
                    .opacity(model.library.copies.isEmpty ? 0.5 : 1)
            }
            // Næste trin lyser blødt op, når det forrige er færdigt.
            .animation(Motion.state(reduceMotion), value: model.hasToken)
            .animation(Motion.state(reduceMotion), value: model.library.copies.isEmpty)
            .padding(Spacing.xl)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Kom i gang")
    }
}

struct StepBox<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                // Tallet bliver til et flueben, når trinnet er færdigt (skalering + fade;
                // kun fade med Reduce Motion). Farven skifter samtidig.
                ZStack {
                    if done {
                        Image(systemName: "checkmark").fontWeight(.bold)
                            .transition(Motion.badgeTransition(reduceMotion))
                    } else {
                        Text("\(number)")
                            .transition(Motion.badgeTransition(reduceMotion))
                    }
                }
                    .font(.headline)
                    .frame(width: 28, height: 28)
                    .background(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint), in: Circle())
                    .foregroundStyle(.white)
                    .animation(Motion.state(reduceMotion), value: done)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(done ? "Trin \(number), færdigt" : "Trin \(number)")
                Text(title).font(.title3.weight(.semibold))
            }
            content
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ConnectStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var token = ""
    @ViewState private var busy = false

    var body: some View {
        Group {
            if model.hasToken {
                Text("Forbundet som **\(model.username ?? "?")**. Tokenet ligger i macOS' nøglering.")
                    .transition(.opacity)
            } else if model.isDemo {
                Text("Demo: appen bruger eksempelplader og forbinder ikke til Discogs.")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                form.transition(.opacity)
            }
        }
        .animation(Motion.state(reduceMotion), value: model.hasToken)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Gå til [discogs.com/settings/developers](https://www.discogs.com/settings/developers), klik på “Generate new token”, og indsæt koden her. Den gemmes i macOS' nøglering – aldrig i filer eller logs.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Discogs-token", text: $token, prompt: Text("Indsæt dit Discogs-token"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                Button(action: connect) {
                    if busy { ProgressView().controlSize(.small) } else { Text("Forbind") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty || busy)
            }
        }
    }

    private func connect() {
        // `onSubmit` respekterer ikke knappens `disabled` – undgå dobbelt forbind/sync.
        guard !busy, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            if await model.connect(token: token) {
                token = ""
                await model.sync(showReport: false)
            }
            busy = false
        }
    }
}

struct ImportStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            switch model.syncState {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(total > 0 ? "\(done) af \(total)" : "Henter…").monospacedDigit()
                    .contentTransition(Motion.numberTransition(reduceMotion))
                    .animation(Motion.number(reduceMotion), value: done)
            case .failed(let msg):
                // Fejlen toner ind (se `.animation` nederst).
                Text(msg).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                Spacer()
                Button("Prøv igen") { Task { await model.sync(showReport: false) } }
            case .idle:
                if model.library.copies.isEmpty {
                    Button("Hent samlingen") { Task { await model.sync(showReport: false) } }
                } else {
                    Text("Din samling indeholder **\(model.library.copies.count)** \(model.medium.plural).")
                    Spacer()
                    Button("Hent igen") { Task { await model.sync(showReport: false) } }
                }
            }
        }
        // Kun faseskift animeres – ikke hver fremdriftsopdatering.
        .animation(Motion.state(reduceMotion), value: model.syncState.phase)
    }
}

struct LayoutStep: View {
    @Environment(AppModel.self) private var model
    @ViewState private var sectionsPerShelf: [Int] = [2, 2, 2]
    @ViewState private var plan: [LayoutPlanner.SectionPlan] = []
    @ViewState private var confirmReplace = false

    private var sortedItems: [RecordItem] {
        model.rules.sorted(model.library.allItems.filter { $0.copy.inDiscogs })
    }

    var body: some View {
        let items = sortedItems
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Samlingen sorteres efter reglerne herunder – ligesom \(model.medium == .vinyl ? "pladerne" : "cd'erne") står i din reol. Angiv hvor mange reoler og sektioner du har; \(model.medium.plural) fordeles jævnt, og du justerer grænserne, så de passer med virkeligheden.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            QuickSortRules()

            HStack(alignment: .top, spacing: Spacing.l) {
                VStack(alignment: .leading) {
                    Stepper("Reoler: \(sectionsPerShelf.count)", onIncrement: {
                        sectionsPerShelf.append(sectionsPerShelf.last ?? 2)
                    }, onDecrement: {
                        if sectionsPerShelf.count > 1 { sectionsPerShelf.removeLast() }
                    })
                    ForEach(sectionsPerShelf.indices, id: \.self) { i in
                        Stepper("\(model.medium.shelfWord) \(i + 1): \(sectionCount(i)) \(sectionCount(i) == 1 ? "sektion" : "sektioner")", value: sectionBinding(i), in: 1...26)
                            .padding(.leading, Spacing.s)
                    }
                    Button("Fordel jævnt") { redistribute(items.count) }
                        .padding(.top, Spacing.xxs)
                }
                .frame(width: 260, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    let ranges = rangeStarts()
                    ForEach(plan.indices, id: \.self) { i in
                        let start = ranges[i], end = start + plan[i].count
                        HStack(alignment: .top) {
                            Text("Reol \(plan[i].shelf) · \(plan[i].section)")
                                .font(.callout.weight(.semibold)).frame(width: 90, alignment: .leading)
                            // Grænsekontrol: bindingen kan blive læst for en række, der lige er
                            // fjernet (færre reoler/sektioner), og så ville `plan[i]` crashe.
                            Stepper("", value: Binding(
                                get: { i < plan.count ? plan[i].count : 0 },
                                set: { if i < plan.count { LayoutPlanner.adjust(&plan, index: i, to: $0) } }), in: 0...items.count)
                                .labelsHidden()
                            Text("\(plan[i].count)").monospacedDigit().frame(width: 40, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 0) {
                                if plan[i].count > 0, start < items.count {
                                    Text("fra \(items[start].fullName)").lineLimit(1)
                                    Text("til \(items[min(end, items.count) - 1].fullName)").lineLimit(1)
                                } else {
                                    Text("(tom)")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Text("\(model.medium.title) \(rangeText()) – i alt \(items.count).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.forceOnboarding {
                    Button("Annullér") { model.forceOnboarding = false }
                }
                Button("Opret reol") {
                    if model.library.locations.isEmpty { model.createLayout(plan) } else { confirmReplace = true }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(plan.isEmpty || items.isEmpty)
            }
        }
        .onAppear {
            // Start med den nuværende opdeling (reoler og sektioner), hvis der er en.
            let current = model.library.shelves.map { shelf in
                model.library.locations.filter { $0.shelf == shelf }.count
            }.filter { $0 > 0 }
            if !current.isEmpty, current != sectionsPerShelf {
                sectionsPerShelf = current   // `onChange` fordeler pladerne
            } else {
                redistribute(items.count)
            }
        }
        .onChange(of: sectionsPerShelf) { redistribute(items.count) }
        .onChange(of: model.library.copies.count) { redistribute(sortedItems.count) }
        .confirmationDialog("Erstat den nuværende reolstruktur?", isPresented: $confirmReplace) {
            Button("Erstat alle placeringer", role: .destructive) { model.createLayout(plan) }
        } message: {
            Text(model.medium == .vinyl
                 ? "Alle nuværende fysiske placeringer erstattes med den sorterede rækkefølge. Historikken bevares."
                 : "Cd'ernes nuværende placeringer erstattes med den sorterede rækkefølge. Pladerne røres ikke. Historikken bevares.")
        }
    }

    private func sectionCount(_ i: Int) -> Int { i < sectionsPerShelf.count ? sectionsPerShelf[i] : 1 }

    /// Grænsekontrolleret binding (se ovenfor) – `$sectionsPerShelf[i]` crasher, når
    /// en reol fjernes med "Reoler"-stepperen.
    private func sectionBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { sectionCount(i) },
                set: { if i < sectionsPerShelf.count { sectionsPerShelf[i] = $0 } })
    }

    private func redistribute(_ total: Int) {
        plan = LayoutPlanner.evenPlan(total: total, sectionsPerShelf: sectionsPerShelf)
    }

    private func rangeStarts() -> [Int] {
        var starts: [Int] = [], acc = 0
        for p in plan { starts.append(acc); acc += p.count }
        return starts
    }

    private func rangeText() -> String {
        var acc = 0
        var shelfRanges: [Int: (Int, Int)] = [:]
        for p in plan {
            let s = acc + 1, e = acc + p.count
            acc = e
            if let cur = shelfRanges[p.shelf] { shelfRanges[p.shelf] = (cur.0, e) } else { shelfRanges[p.shelf] = (s, e) }
        }
        return shelfRanges.keys.sorted().map { "\(model.medium.shelfWord) \($0): \(shelfRanges[$0]!.0)–\(shelfRanges[$0]!.1)" }.joined(separator: " · ")
    }
}

/// De vigtigste sorteringsregler direkte i onboarding.
struct QuickSortRules: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rules = model.rules
        VStack(alignment: .leading, spacing: Spacing.xs) {
        Toggle("Præcis samme rækkefølge som i min Discogs-samling (kunstner A–Z)", isOn: Binding(
            get: { rules.useDiscogsOrder }, set: { var r = rules; r.useDiscogsOrder = $0; model.updateRules(r) }))
            .fontWeight(.medium)
        HStack(spacing: Spacing.m) {
            Toggle("Ignorér “The”", isOn: Binding(
                get: { rules.artistArticles.contains { $0.lowercased() == "the" } },
                set: { on in
                    var r = rules
                    r.artistArticles.removeAll { $0.lowercased() == "the" }
                    if on { r.artistArticles.insert("The", at: 0) }
                    model.updateRules(r)
                }))
            Toggle("Æ Ø Å efter Z", isOn: Binding(get: { rules.danishAlphabet }, set: { var r = rules; r.danishAlphabet = $0; model.updateRules(r) }))
            Picker("Samme kunstner", selection: Binding(get: { rules.withinArtist }, set: { var r = rules; r.withinArtist = $0; model.updateRules(r) })) {
                ForEach(SortRules.WithinArtist.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        .disabled(rules.useDiscogsOrder)
        .opacity(rules.useDiscogsOrder ? 0.5 : 1)
        }
        .toggleStyle(.checkbox)
    }
}

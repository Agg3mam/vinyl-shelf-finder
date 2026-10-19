import SwiftUI
import VinylCore

/// Plade-detaljen som "pladeskærm" (samme udtryk som Find i reolen): mørk scene med
/// pladens sløret cover bagved og accent fra coveret. Kun placeringsblokken og
/// knapperne er glas; naboer og målkort er almindeligt indhold på diskrete flader.
struct RecordDetailView: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64
    @ViewState private var showSortEditor = false
    @ViewState private var showTracks = false
    @ViewState private var confirmDelete = false
    /// Visningen genbruges, når man skifter plade (ingen `.id` på hele skærmen – så kan
    /// baggrund og farvetone krydsfade). Derfor nulstilles pladespecifik tilstand og
    /// scroll-position ved hvert skift.
    @ViewState private var scrollPosition = ScrollPosition(edge: .top)
    /// Kun til snapshot: `ImageRenderer` tegner ikke indholdet af en `ScrollView`,
    /// så snapshottet renderer den samme stak uden scroll.
    var scrolls = true

    var body: some View {
        if let n = model.library.neighbors(of: copyID, count: model.neighborCount) {
            Group {
                if scrolls {
                    ScrollView { page(n) }
                        .scrollPosition($scrollPosition)
                        // Blød kant under værktøjslinjen (sløret scene) – ikke en lys flade.
                        .scrollEdgeEffectStyle(.soft, for: .top)
                } else {
                    page(n).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .overlay(alignment: .bottom) {
                PlayedToast(copyID: copyID).padding(.bottom, Spacing.l)
            }
            .recordStage(n.target.release)
            .navigationTitle(n.target.title)
            .onChange(of: copyID) {
                showSortEditor = false
                showTracks = model.resultTracks[copyID] != nil
                confirmDelete = false
                scrollPosition.scrollTo(edge: .top)
            }
        }
    }

    private func page(_ n: Library.Neighbors) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            header(n.target)
            notices(n.target)
            if let loc = n.location, let pos = n.position {
                DetailLocationPanel(location: loc, position: pos, count: n.sectionCount,
                                    away: !n.target.copy.status.isOnShelf)
                NeighborStack(n: n)
                DetailActions(item: n.target)
            } else {
                UnplacedPanel(copyID: copyID)
            }
            if !n.target.release.tracks.isEmpty {
                DisclosureGroup("Sange (\(n.target.release.tracks.count))", isExpanded: $showTracks) {
                    TrackList(tracks: n.target.release.tracks, highlight: model.resultTracks[copyID])
                        .padding(.top, Spacing.xs)
                }
                .foregroundStyle(Ink.secondary)
            }
            DisclosureGroup("Sortering", isExpanded: $showSortEditor) {
                SortOverrideEditor(item: n.target).padding(.top, Spacing.xs)
                    .id(n.target.id)
            }
            .foregroundStyle(Ink.secondary)
            // Discogs-nummeret og iMusic er detaljer: små og sekundære, nederst.
            HStack(spacing: Spacing.m) {
                Link(destination: n.target.release.discogsURL) {
                    Text("Se pladen på Discogs (#\(String(n.target.release.id)))")
                }
                .font(.caption)
                .foregroundStyle(Ink.tertiary)
                .tint(Ink.tertiary)
                IMusicOfferLine(barcodes: [], artist: n.target.artist, title: n.target.title,
                                preferVinyl: (n.target.release.format ?? "").localizedCaseInsensitiveContains("vinyl"),
                                compact: true)
            }
        }
        .foregroundStyle(Ink.primary)
        .padding(Spacing.l)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func header(_ it: RecordItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.m + Spacing.xxs) {
            CoverView(release: it.release, size: 132)
                .modifier(CoverShadow())
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(it.artist).font(.title2).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(it.title)
                    .font(Typo.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(it.detailLine).font(.callout).foregroundStyle(Ink.tertiary).lineLimit(2)
                if let m = model.market[it.release.id] {
                    MarketLine(market: m)
                }
                PlayCountLine(copyID: it.id, ink: Ink.secondary)
                StatusMenu(item: it)
                    .id(it.id)
                    .padding(.top, Spacing.xxs)
            }
        }
    }

    @ViewBuilder
    private func notices(_ it: RecordItem) -> some View {
        if !it.copy.inDiscogs {
            Notice(icon: "exclamationmark.triangle.fill", color: Ink.warning,
                   text: "Denne plade er ikke længere i din Discogs Collection. Den fysiske placering er bevaret.") {
                if it.copy.removedFromDiscogsAt != nil {
                    Button("Behold i reolen") { model.keepLocalOnly(it.id) }
                        .buttonStyle(.stageSecondary)
                }
                Button("Slet lokalt…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.stageSecondary)
            }
            .confirmationDialog("Slet \(it.fullName) fra den lokale samling?", isPresented: $confirmDelete) {
                Button("Slet plade og placering", role: .destructive) { model.deleteCopy(it.id) }
            } message: {
                Text("Pladens fysiske placering fjernes. Naboerne rykker automatisk sammen.")
            }
        }
        if let away = it.awayMessage {
            // Pladen tæller ikke med i reolens nummerering, men appen husker dens plads.
            let placed = model.library.locationOfCopy[it.id] != nil
            Notice(icon: it.copy.status.symbol, color: Ink.warning,
                   text: placed ? "\(away). Appen husker dens plads, så du kan sætte den tilbage samme sted." : "\(away).") {
                Button("Sæt tilbage på plads…") { model.startReturn(it.id) }
                    .buttonStyle(.stageSecondary)
                    .help(placed ? "Vis præcis, hvor pladen skal stå" : "Find en plads til pladen i reolen")
            }
        }
    }
}

/// Placeringsblokken: den ene fremhævede glasflade på plade-detaljen.
private struct DetailLocationPanel: View {
    @Environment(\.coverTone) private var tone
    let location: Location
    let position: Int
    let count: Int
    /// Pladen er ude af reolen: placeringen er dens plads, når den sættes tilbage.
    var away = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Eyebrow(away ? "Plejer at stå i" : "Står i")
            ViewThatFits(in: .horizontal) {
                PlacementLine(location: location, tone: tone).font(Typo.location)
                PlacementLine(location: location, tone: tone).font(Typo.locationCompact)
            }
            ShelfSpines(position: position, count: count, accent: tone.accent)
            Text("\(away ? "Plads" : location.medium.singular.capitalized) \(position) af \(count) fra venstre")
                .font(.callout.monospacedDigit()).foregroundStyle(Ink.secondary)
        }
        .padding(Spacing.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanel(tone: tone))
    }
}

/// Handlingsknapperne som én glasgruppe. "Find i reolen" er den prominente.
private struct DetailActions: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem

    var body: some View {
        // Bred kolonne: knapper og "Naboer" på én linje. Smal: "Naboer" under knapperne,
        // så ingen knaptekst klippes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) {
                buttons
                Spacer(minLength: Spacing.s)
                neighborPicker
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                buttons
                neighborPicker
            }
        }
    }

    private var buttons: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button { model.moveCopy = item.id } label: {
                    Label("Rediger placering", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.stageSecondary)
                .help("Flyt pladen (⇧⌘M)")

                Button { PlayFeedback.logPlay(model, item.id) } label: {
                    Label { Text("Spillet") } icon: { PlayedIcon(copyID: item.id) }
                }
                .buttonStyle(.stageSecondary)
                .help("Registrér i lyttelog (⌘L)")

                Button { model.findModeCopy = item.id } label: {
                    Label("Find i reolen", systemImage: "scope")
                }
                .buttonStyle(.stagePrimary)
                .help("Find i reolen (⌘F)")
            }
            .controlSize(.large)
        }
    }

    private var neighborPicker: some View {
        @Bindable var model = model
        return Picker("Naboer", selection: $model.neighborCount) {
            Text("1").tag(1)
            Text("3").tag(3)
            Text("5").tag(5)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Antal plader før/efter")
    }
}

/// Diskret indholdsflade på scenen (ikke glas – glas er forbeholdt chrome).
enum ContentSurface {
    static let fill = adaptive(light: .black.withAlphaComponent(0.045), dark: .white.withAlphaComponent(0.07))
    static let radius: CGFloat = 10
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

struct Notice<Actions: View>: View {
    let icon: String
    let color: Color
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                HStack { actions }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: ContentSurface.shape)
    }
}

struct StatusMenu: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem

    var body: some View {
        Menu {
            StatusChoices(copyID: item.id)
            Divider()
            MediumChoice(copyID: item.id)
        } label: {
            // En plade uden plads i reolen er ikke "På plads", selv om status er standard.
            if item.copy.status == .home && model.library.locationOfCopy[item.id] == nil {
                Label("Ikke placeret", systemImage: "square.dashed")
            } else {
                Label(item.copy.status.label, systemImage: item.copy.status.symbol)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
    }
}

/// Statusvalgene i plade-detaljens menu og i højrekliksmenuen. "Udlånt…" og
/// "Opbevaret andet sted…" spørger efter navn/sted; "På plads…" for en plade, der er
/// ude, åbner "Sæt tilbage"-guiden. "På væggen" sættes direkte.
struct StatusChoices: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64

    var body: some View {
        let away = model.isAway(copyID)
        ForEach(CopyStatus.allCases) { s in
            Button { model.chooseStatus(copyID, s) } label: {
                Label(s.wantsNote || (s == .home && away) ? "\(s.label)…" : s.label, systemImage: s.symbol)
            }
        }
    }
}

/// Kort, tydelig bekræftelse nederst på pladeskærmen, når pladen registreres som spillet
/// (knappen eller ⌘L). Toner ud af sig selv. Ingen bevægelse ved "Reducér bevægelse".
struct PlayedToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverTone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copyID: Int64
    @ViewState private var visible = false
    @ViewState private var token = 0
    @ViewState private var duplicate = false
    private static let registered = "Registreret som spillet"
    private static let already = "Allerede registreret for lidt siden"

    var body: some View {
        let key = [copyID, Int64(model.stats.count[copyID] ?? 0)]
        Label(duplicate ? Self.already : Self.registered,
              systemImage: duplicate ? "checkmark.circle" : "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(tone.onAccent)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(tone.accent, in: Capsule())
            .modifier(CoverShadow())
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .allowsHitTesting(false)
            .accessibilityHidden(!visible)
            .onChange(of: key) { old, new in
                // Kun når antallet stiger for den samme plade – ikke ved pladeskift eller fortryd.
                if old[0] == new[0] && new[1] > old[1] {
                    duplicate = false
                    token += 1
                } else if old[0] != new[0] {
                    visible = false
                }
            }
            .onChange(of: PlayFeedback.shared.duplicateToken) {
                guard PlayFeedback.shared.duplicateCopy == copyID else { return }
                duplicate = true
                token += 1
            }
            .onAppear {
                // Registreret i samme øjeblik, som pladen blev vist (fx ⌘L lige efter et valg).
                if let last = model.stats.lastPlayed[copyID], Date().timeIntervalSince(last) < 1.5 {
                    duplicate = false
                    token += 1
                }
            }
            .task(id: token) {
                guard token > 0 else { return }
                withAnimation(Motion.fade(reduceMotion)) { visible = true }
                AccessibilityNotification.Announcement(duplicate ? Self.already : Self.registered).post()
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.6)) { visible = false }
            }
    }
}

// MARK: - Naboer

struct NeighborStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let n: Library.Neighbors

    var body: some View {
        list
            // Skift mellem 1/3/5 naboer: rækkerne toner ind/ud, målkortet glider på plads.
            .animation(Motion.rows(reduceMotion), value: n.before.count + n.after.count)
    }

    private var list: some View {
        let section = n.location?.section ?? ""
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            // Overskriften vises kun, når der faktisk står plader før (ikke først i sektionen).
            if !n.before.isEmpty {
                Eyebrow("← \(n.before.count > 1 ? "\(n.before.count) før" : "Lige før")")
            }

            if n.reachedSectionStart {
                SectionEdgeNote(text: "Starten af sektion \(section)",
                                detail: n.previousSection.map { p in
                                    p.last.map { "Forrige sektion (\(p.location.name)) slutter med \($0.fullName)" }
                                        ?? "Forrige sektion (\(p.location.name)) er tom"
                                })
            }
            // Vis fjerneste først, så listen læses i fysisk rækkefølge (venstre → højre).
            ForEach(n.before.reversed()) { it in NeighborRow(item: it) }
            ForEach(n.absentBetweenBefore.reversed()) { it in AbsentRow(item: it) }

            TargetCard(item: n.target)
                .padding(.vertical, Spacing.xxs)

            ForEach(n.absentBetweenAfter) { it in AbsentRow(item: it) }
            ForEach(n.after) { it in NeighborRow(item: it) }
            if n.reachedSectionEnd {
                SectionEdgeNote(text: "Slutningen af sektion \(section)",
                                detail: n.nextSection.map { nx in
                                    nx.first.map { "Næste sektion (\(nx.location.name)) starter med \($0.fullName)" }
                                        ?? "Næste sektion (\(nx.location.name)) er tom"
                                })
            }

            if !n.after.isEmpty {
                Eyebrow("\(n.after.count > 1 ? "\(n.after.count) efter" : "Lige efter") →")
            }
        }
    }
}

struct NeighborRow: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem

    var body: some View {
        Button { model.reveal(item.id) } label: {
            HStack(spacing: Spacing.s) {
                CoverView(release: item.release, size: 44)
                    .modifier(CoverShadow())
                // Kunstner og titel har forrang; detaljelinjen giver plads først.
                VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                    Text(item.artist).font(.callout).foregroundStyle(Ink.secondary).lineLimit(2)
                    Text(item.title).font(.body.weight(.medium)).foregroundStyle(Ink.primary).lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                Spacer(minLength: Spacing.s)
                Text(item.detailLine).font(.caption2).foregroundStyle(Ink.tertiary).lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
            .padding(Spacing.xs)
            .contentShape(Rectangle())
            .background(ContentSurface.fill, in: ContentSurface.shape)
        }
        .buttonStyle(.plain)
        .help("Vis \(item.fullName)")
    }
}

/// En plade, der normalt står her, men er ude af reolen. Naboerne står tæt sammen uden den.
struct AbsentRow: View {
    let item: RecordItem
    var body: some View {
        Label("\(item.fullName) · \(item.copy.status.listText(note: item.copy.statusNote)) – står ikke i reolen",
              systemImage: item.copy.status.symbol)
            .font(.caption).foregroundStyle(Ink.secondary)
            .padding(.leading, Spacing.xs)
    }
}

/// Målpladen i rækken: accentkant og en svag accentflade. Intet glas (indhold).
struct TargetCard: View {
    @Environment(\.coverTone) private var tone
    let item: RecordItem
    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "arrowtriangle.right.fill").foregroundStyle(tone.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(item.artist).font(.callout.weight(.semibold)).foregroundStyle(Ink.secondary)
                Text(item.title.uppercased()).font(.title3.weight(.heavy)).foregroundStyle(Ink.primary)
            }
            Spacer()
        }
        .padding(Spacing.m)
        .background(tone.accent.opacity(0.14), in: ContentSurface.shape)
        .overlay(ContentSurface.shape.strokeBorder(tone.accent, lineWidth: 2))
    }
}

struct SectionEdgeNote: View {
    let text: String
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
            HStack {
                Rectangle().fill(Ink.tertiary).frame(height: 1)
                Text(text.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Ink.secondary).fixedSize()
                Rectangle().fill(Ink.tertiary).frame(height: 1)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

// MARK: - Uplaceret plade

struct UnplacedPanel: View {
    @Environment(AppModel.self) private var model
    let copyID: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Ikke placeret i reolen endnu", systemImage: "square.dashed")
                .font(.headline).foregroundStyle(Ink.warning)
            if let s = model.library.suggestPlacement(for: copyID, rules: model.rules),
               let loc = model.library.location(s.locationID) {
                Text("Foreslået plads: **\(loc.name)**, mellem")
                if let b = s.before.flatMap(model.library.item) {
                    NeighborRow(item: b)
                } else {
                    SectionEdgeNote(text: "Starten af sektionen", detail: nil)
                }
                if let t = model.library.item(copyID) { TargetCard(item: t) }
                if let a = s.after.flatMap(model.library.item) {
                    NeighborRow(item: a)
                } else {
                    SectionEdgeNote(text: "Slutningen af sektionen", detail: nil)
                }
                GlassEffectContainer(spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        Button("Placér her") { model.move(copyID, to: s.locationID, index: s.index) }
                            .buttonStyle(.stagePrimary)
                        Button("Vælg anden placering…") { model.moveCopy = copyID }
                            .buttonStyle(.stageSecondary)
                    }
                    .controlSize(.large)
                }
            } else {
                Text("Opret først reoler og sektioner.")
            }
        }
    }
}

// MARK: - Sorteringsnavn

struct SortOverrideEditor: View {
    @Environment(AppModel.self) private var model
    let item: RecordItem
    @ViewState private var artist = ""
    @ViewState private var title = ""
    @ViewState private var artistRule = ""

    var body: some View {
        Form {
            LabeledContent("Sorteres som") {
                Text("\(model.rules.sortArtist(item.artist, override: item.copy.sortArtistOverride)) / \(model.rules.sortTitle(item.title, override: item.copy.sortTitleOverride))")
                    .textSelection(.enabled)
            }
            TextField("Kunstnerregel for alle “\(item.artist)”", text: $artistRule, prompt: Text("fx Dylan, Bob"))
            TextField("Kun denne plade – kunstner", text: $artist, prompt: Text("(standard)"))
            TextField("Kun denne plade – titel", text: $title, prompt: Text("(standard)"))
            HStack {
                Spacer()
                Button("Gem sortering") {
                    var r = model.rules
                    r.artistOverrides[item.artist] = artistRule.isEmpty ? nil : artistRule
                    model.updateRules(r)
                    model.setSortOverrides(item.id, artist: artist, title: title)
                }
            }
            Text("Påvirker kun forslag til nye plader. Den fysiske rækkefølge ændres ikke – flyt selv pladen, hvis den skal stå et andet sted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            artist = item.copy.sortArtistOverride ?? ""
            title = item.copy.sortTitleOverride ?? ""
            artistRule = model.rules.artistOverrides[item.artist] ?? ""
        }
    }
}

/// Sanglisten på pladen. Sangen, man søgte på, er fremhævet.
struct TrackList: View {
    let tracks: [Track]
    var highlight: Track?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(t.position).monospacedDigit().foregroundStyle(Ink.tertiary).frame(minWidth: 30, alignment: .leading)
                    Text(t.title).foregroundStyle(t == highlight ? Ink.primary : Ink.secondary)
                        .fontWeight(t == highlight ? .semibold : .regular)
                    Spacer(minLength: Spacing.s)
                    if let d = t.duration { Text(d).monospacedDigit().foregroundStyle(Ink.tertiary) }
                }
                .font(.callout)
            }
        }
    }
}

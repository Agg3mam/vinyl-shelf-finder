import SwiftUI
import VinylCore

/// "Find i reolen": hvor pladen står, hvad der står ved siden af, og "Spillet".
/// Samme tekster som på Mac (Library.referenceAdvice); coveret ligger sløret bag skærmen.
struct RecordView: View {
    @Environment(PhoneModel.self) private var model
    let route: RecordRoute
    @State private var playedTick = 0
    @AppStorage("look_style") private var lookStyle = LookStyle.standard
    @State private var skippedTick = 0
    @State private var showTracks = false
    /// Kort bekræftelse på knappen efter "Spillet".
    @State private var feedback: String?

    var body: some View {
        let lib = model.library(route.medium)
        if let item = lib.item(route.copyID) {
            content(item, lib)
        } else {
            ContentUnavailableView("Pladen findes ikke længere", systemImage: "questionmark.square.dashed")
        }
    }

    private func content(_ item: RecordItem, _ lib: Library) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(item)
                if let loc = lib.location(of: item.id), let adv = lib.referenceAdvice(for: item.id), let n = lib.neighbors(of: item.id) {
                    let away = !item.copy.status.isOnShelf
                    let position = n.position ?? 1
                    LocationCard(location: loc, position: position, count: n.sectionCount,
                                 title: away ? "Her plejer den at stå" : "Gå til",
                                 hint: "\(away ? "Plads" : "Nr.") \(position) af \(n.sectionCount) fra venstre")
                    if away {
                        Label("\(item.copy.status.label)\(item.copy.statusNote.map { ": \($0)" } ?? "")", systemImage: item.copy.status.symbol)
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    }
                    ReferenceCard(title: "Start ved", ref: adv.primary, medium: route.medium)
                    if let s = adv.secondary { ReferenceCard(title: "Så", ref: s, medium: route.medium) }
                    hints(adv, n)
                    NavigationLink(value: SectionRoute(medium: route.medium, locationID: loc.id)) {
                        Label("Vis hele sektion \(loc.shortName)", systemImage: "list.number")
                    }
                    .buttonStyle(.glass)
                } else {
                    Label("Pladen har endnu ingen fysisk placering.", systemImage: "questionmark.square.dashed")
                        .font(.title3)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: .rect(cornerRadius: 20))
                }
                playLine(item)
                if !item.release.tracks.isEmpty { trackList(item.release.tracks) }
            }
            .padding()
            .padding(.bottom, 60)
        }
        .background { CoverBackdrop(url: item.release.coverURL ?? item.release.thumbURL) }
        .navigationTitle(item.artist)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) {
            Button {
                if model.logPlay(item.id) { playedTick += 1; feedback = "Registreret" }
                else { skippedTick += 1; feedback = "Allerede registreret" }
            } label: {
                Label(feedback ?? "Spillet", systemImage: feedback == nil ? "play.fill" : "checkmark")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.symbolEffect(.replace))
            }
            .task(id: playedTick + skippedTick) {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { feedback = nil }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .sensoryFeedback(.success, trigger: playedTick)
            .sensoryFeedback(.warning, trigger: skippedTick)
        }
    }

    @ViewBuilder
    private func header(_ item: RecordItem) -> some View {
        let url = item.release.coverURL ?? item.release.thumbURL
        // "Covers i fokus" (Konto › Indstillinger › Udseende): coveret fylder hele bredden.
        let layout = lookStyle.bigCovers ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
        layout {
            if lookStyle.bigCovers {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { CoverImage(url: url, corner: 14, release: item.release) }
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(radius: 12, y: 6)
            } else {
                CoverImage(url: url, size: 130, corner: 10, release: item.release)
                    .shadow(radius: 12, y: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.artist).font(.title3.weight(.semibold))
                Text(item.title).font(.title2.weight(.bold)).fontWidth(lookStyle.condensedTitles ? .condensed : nil)
                if !item.pressingLine.isEmpty { Text(item.pressingLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                if let f = item.release.format, !f.isEmpty { Text(f).font(.footnote).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
    }

    @ViewBuilder private func hints(_ adv: Library.ReferenceAdvice, _ n: Library.Neighbors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint = adv.artistBlockHint { Label(hint, systemImage: "rectangle.stack") }
            if let edge = adv.sectionEdgeHint {
                Label(edge, systemImage: n.reachedSectionEnd ? "arrow.right.to.line" : "arrow.left.to.line")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Sanglisten. Sangen, man søgte på, er fremhævet.
    private func trackList(_ tracks: [Track]) -> some View {
        DisclosureGroup("Sange (\(tracks.count))", isExpanded: $showTracks) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(t.position).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading)
                        Text(t.title).fontWeight(t == route.track ? .semibold : .regular)
                        Spacer(minLength: 8)
                        if let d = t.duration { Text(d).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .onAppear { if route.track != nil { showTracks = true } }
    }

    @ViewBuilder private func playLine(_ item: RecordItem) -> some View {
        let count = model.stats.count[item.id] ?? 0
        if count > 0, let last = model.stats.lastPlayed[item.id] {
            Label("Spillet \(count) \(count == 1 ? "gang" : "gange"), senest \(last.formatted(.relative(presentation: .named)))",
                  systemImage: "music.note.list")
                .font(.footnote).foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

/// Reol, sektion og plads. Indhold (ikke betjening), så den bruger et materiale og ikke glas.
private struct LocationCard: View {
    let location: Location
    let position: Int
    let count: Int
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            PlacementLine(location: location)
            ShelfSpines(position: position, count: count, accent: location.category?.color ?? AppAccent.color)
            Text(hint).font(.system(size: 19, weight: .medium).width(.condensed).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
    }
}

/// En referenceplade ("Find først" / "Dernæst") med cover og forklaring.
private struct ReferenceCard: View {
    let title: String
    let ref: Library.Reference
    let medium: ShelfKind

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let it = ref.item {
                CoverImage(url: it.release.thumbURL ?? it.release.coverURL, size: 56, release: it.release)
            } else {
                Image(systemName: ref.side == .sectionStart ? "arrow.left.to.line" : "arrow.right.to.line")
                    .font(.title2).frame(width: 56, height: 56)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                if let it = ref.item { Text(it.fullName).font(.subheadline.weight(.semibold)) }
                Text(ref.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// Coveret sløret bag pladeskærmen (som "scenen" på Mac).
struct CoverBackdrop: View {
    let url: String?
    @AppStorage("look_style") private var lookStyle = LookStyle.standard

    var body: some View {
        // Stilen bestemmer baggrunden under det slørede cover; "Farve fra coveret" farver hele skærmen kraftigere.
        let base = lookStyle.palette != nil ? AppAccent.background : Color(uiColor: .systemBackground)
        let strong = lookStyle.strongCoverTint
        ZStack {
            Rectangle().fill(base)
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().blur(radius: strong ? 60 : 50).saturation(strong ? 1.5 : 1).opacity(strong ? 1 : 0.55)
                }
            }
            if strong {
                Rectangle().fill(base.opacity(0.5))
            } else {
                LinearGradient(colors: [.clear, base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

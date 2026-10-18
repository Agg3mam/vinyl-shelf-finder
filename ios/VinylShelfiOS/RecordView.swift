import SwiftUI
import VinylCore

/// "Find i reolen": hvor pladen står, hvad der står ved siden af, og "Spillet".
/// Samme tekster som på Mac (Library.referenceAdvice); coveret ligger sløret bag skærmen.
struct RecordView: View {
    @Environment(PhoneModel.self) private var model
    let route: RecordRoute
    @State private var playedTick = 0
    @State private var skippedTick = 0
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
                                 hint: "\(away ? "Plads" : loc.medium.singular.capitalized) \(position) af \(n.sectionCount) fra venstre")
                    if away {
                        Label("\(item.copy.status.label)\(item.copy.statusNote.map { ": \($0)" } ?? "")", systemImage: item.copy.status.symbol)
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    }
                    ReferenceCard(title: "Find først", ref: adv.primary, medium: route.medium)
                    if let s = adv.secondary { ReferenceCard(title: "Dernæst", ref: s, medium: route.medium) }
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

    private func header(_ item: RecordItem) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            CoverImage(url: item.release.coverURL ?? item.release.thumbURL, size: 130, corner: 10)
                .shadow(radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.artist).font(.title3.weight(.semibold))
                Text(item.title).font(.title2.weight(.bold))
                Text(item.detailLine).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
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
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            PlacementLine(location: location).font(.title.weight(.bold))
            ShelfSpines(position: position, count: count)
            Text(hint).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
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
    let medium: Medium

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let it = ref.item {
                CoverImage(url: it.release.thumbURL ?? it.release.coverURL, size: 56)
            } else {
                Image(systemName: ref.side == .sectionStart ? "arrow.left.to.line" : "arrow.right.to.line")
                    .font(.title2).frame(width: 56, height: 56)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().blur(radius: 50).opacity(0.55)
                }
            }
            LinearGradient(colors: [.clear, Color(uiColor: .systemBackground).opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

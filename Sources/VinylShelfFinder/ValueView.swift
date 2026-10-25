import SwiftUI
import VinylCore

struct ValueView: View {
    @Environment(AppModel.self) private var model

    enum SortMode: String, CaseIterable, Identifiable {
        case price, demand, rare, scarce
        var id: String { rawValue }
        var label: String {
            switch self {
            case .price: return "Højeste pris"
            case .demand: return "Mest efterspurgt"
            case .rare: return "Færrest ejere"
            case .scarce: return "Færrest til salg"
            }
        }
    }

    @ViewState private var sort: SortMode = .price

    private var rows: [(item: RecordItem, market: MarketInfo?)] {
        // Samme rækkefølge som i reolen ("The"-reglen, A-ha/ABBA osv.) ved lige værdier
        // og for plader uden priser.
        let shelfOrder = model.rules.sorted(model.library.allItems.filter { $0.copy.inDiscogs })
        let items = shelfOrder.map { ($0, model.market[$0.release.id]) }
        func key(_ m: MarketInfo?) -> Double? {
            guard let m else { return nil }
            switch sort {
            case .price: return m.lowestPrice
            case .demand: return m.demand
            case .rare: return m.have.map { -Double($0) }
            case .scarce: return m.numForSale.map { -Double($0) }
            }
        }
        // Stabil sortering på værdien; ved lige værdi bevares reolens rækkefølge.
        return items.enumerated().sorted { a, b in
            switch (key(a.element.1), key(b.element.1)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { (item: $0.element.0, market: $0.element.1) }
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows
        // Kun priser i den valgte valuta må lægges sammen. Efter et valutaskift står
        // de gamle priser stadig i den gamle valuta, indtil de er hentet igen.
        let priced = rows.compactMap { $0.market }.filter { $0.currency == model.currency }.compactMap(\.lowestPrice)
        List(selection: $model.selection) {
            Section {
                ValueHeader(pricedCount: priced.count, total: rows.count, sum: priced.reduce(0, +))
                    .selectionDisabled()
            }
            Section {
                if rows.isEmpty {
                    Text("Ingen plader fra din Discogs-samling endnu.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(rows, id: \.item.id) { row in
                    ValueRow(item: row.item, market: row.market, sort: sort).tag(row.item.id)
                }
            } header: {
                Picker("Sortér", selection: $sort) {
                    ForEach(SortMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .listStyle(.inset)
        .navigationTitle("Værdi")
    }
}

struct ValueHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pricedCount: Int
    let total: Int
    let sum: Double

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Discogs' estimat for samlingen").font(Typo.eyebrow).foregroundStyle(.secondary)
            if let v = model.collectionValue {
                HStack(spacing: 0) {
                    stat("Min", v.minimum)
                    stat("Median", v.median, big: true)
                    stat("Max", v.maximum)
                }
                Text("Baseret på faktiske salg på Discogs · opdateret \(v.fetchedAt.danskDatoTid)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Ikke hentet endnu.").foregroundStyle(.secondary)
            }

            Divider()

            if pricedCount > 0 {
                Text("Sum af laveste udbudspriser: **\(sum.formatted(.currency(code: model.currency)))**")
                    .contentTransition(Motion.numberTransition(reduceMotion))
                    .animation(Motion.number(reduceMotion), value: sum)
                Text("\(pricedCount) af \(total) plader er til salg på Discogs lige nu. Laveste pris er det billigste eksemplar i dag – uanset stand og pressing-kvalitet – ikke nødvendigvis hvad din plade er værd.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                switch model.valueState {
                case .running(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done)/\(total)").monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(Motion.numberTransition(reduceMotion))
                        .animation(Motion.number(reduceMotion), value: done)
                case .failed(let msg):
                    Text(msg).foregroundStyle(.red).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    Spacer()
                    Button("Prøv igen") { Task { await model.refreshValues() } }
                case .idle:
                    Button {
                        Task { await model.refreshValues() }
                    } label: {
                        Label(model.market.isEmpty ? "Hent værdier" : "Opdater værdier", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasToken)
                    Spacer()
                    Picker("Valuta", selection: $model.currency) {
                        ForEach(MarketCurrency.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .fixedSize()
                }
            }
            // Skift mellem knap, fremdrift og fejl toner blødt – fremdriftstallene selv
            // animeres kun lokalt ovenfor.
            .animation(Motion.state(reduceMotion), value: model.valueState.phase)
            if !model.hasToken {
                Text(model.isDemo ? "Demo-tilstanden henter ikke værdier fra Discogs." : "Forbind til Discogs i Indstillinger for at hente værdier.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .idle = model.valueState, !model.market.isEmpty {
                Text("Priser ældre end 7 dage hentes igen. Tager ca. 1 sekund pr. plade (Discogs' grænse).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func stat(_ label: String, _ value: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(big ? .title2.weight(.bold) : .title3.weight(.medium)).monospacedDigit()
                .contentTransition(Motion.numberTransition(reduceMotion))
                .animation(Motion.number(reduceMotion), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ValueRow: View {
    let item: RecordItem
    let market: MarketInfo?
    let sort: ValueView.SortMode

    var body: some View {
        HStack(spacing: Spacing.s) {
            CoverView(release: item.release, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fullName).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(item.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            VStack(alignment: .trailing, spacing: 2) {
                if let m = market {
                    Text(m.lowestPrice.map { $0.formatted(.currency(code: m.currency)) } ?? "–")
                        .fontWeight(sort == .price ? .semibold : .regular).monospacedDigit()
                    Text(secondary(m)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("ikke hentet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func secondary(_ m: MarketInfo) -> String {
        switch sort {
        case .demand: return m.demand.map { "\($0.formatted(.number.precision(.fractionLength(2)))) ønsker pr. ejer" } ?? ""
        case .rare: return m.have.map { "\($0) ejere" } ?? ""
        default: return m.numForSale.map { "\($0) til salg" } ?? ""
        }
    }
}

/// Kompakt linje til plade-detaljen.
struct MarketLine: View {
    let market: MarketInfo

    var body: some View {
        HStack(spacing: 10) {
            if let p = market.lowestPrice {
                Label("Fra \(p.formatted(.currency(code: market.currency)))", systemImage: "tag")
            } else {
                Label("Ikke til salg lige nu", systemImage: "tag.slash")
            }
            if let n = market.numForSale { Text("· \(n) til salg") }
            if let h = market.have, let w = market.want { Text("· \(h) har / \(w) ønsker") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Discogs-markedsdata hentet \(market.fetchedAt.danskDatoTid)")
    }
}

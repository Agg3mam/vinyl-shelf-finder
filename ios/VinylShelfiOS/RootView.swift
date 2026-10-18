import SwiftUI
import VinylCore

/// Navigation: en plade eller en sektion på en bestemt hylde (plader eller cd'er).
struct RecordRoute: Hashable { let medium: Medium; let copyID: Int64 }
struct SectionRoute: Hashable { let medium: Medium; let locationID: Int64 }

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @State private var query = ""
    @State private var tab = AppTab.shelves

    enum AppTab: Hashable { case shelves, scan, account, search }

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.cloudLoggedIn && !model.hasShelves {
                // Første gang: data kommer fra kontoen, så log ind først.
                NavigationStack { AccountView(welcome: true) }
            } else {
                tabs
            }
        }
        .sheet(item: $model.openedSection) { s in
            NavigationStack {
                SectionView(route: SectionRoute(medium: s.medium, locationID: s.locationID))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Luk", systemImage: "xmark") { model.openedSection = nil }
                        }
                    }
                    .navigationDestination(for: RecordRoute.self) { RecordView(route: $0) }
            }
        }
        .alert("Hvilke reoler skal bruges?", isPresented: Binding(get: { model.cloudChoice != nil }, set: { if !$0 { model.cloudChoice = nil } }),
               presenting: model.cloudChoice) { _ in
            Button("Brug kontoens reoler") { model.resolveCloudChoice(.useCloud) }
            Button("Brug telefonens reoler") { model.resolveCloudChoice(.useThisDevice) }
            Button("Senere", role: .cancel) { model.postponeCloudChoice() }
        } message: { c in
            Text("Kontoen har \(c.cloudSections) sektioner, og telefonen har \(c.localSections) andre. Pladerne, lyttelog og flueben flettes, men reolerne skal komme ét sted fra. Vælger du telefonens reoler, forsvinder kontoens reoler også på dine andre enheder. Før reoler slettes, gemmes en sikkerhedskopi.")
        }
        .alert("Der opstod en fejl", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Reol", systemImage: "books.vertical", value: AppTab.shelves) {
                NavigationStack {
                    ShelvesView()
                        .navigationDestination(for: SectionRoute.self) { SectionView(route: $0) }
                        .navigationDestination(for: RecordRoute.self) { RecordView(route: $0) }
                }
            }
            Tab("Scan", systemImage: "qrcode.viewfinder", value: AppTab.scan) {
                NavigationStack { ScanView() }
            }
            Tab("Konto", systemImage: "person.crop.circle", value: AppTab.account) {
                NavigationStack { AccountView(welcome: false) }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    SearchView(query: query)
                        .navigationDestination(for: RecordRoute.self) { RecordView(route: $0) }
                        .navigationDestination(for: SectionRoute.self) { SectionView(route: $0) }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Kunstner, titel, katalognummer …")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

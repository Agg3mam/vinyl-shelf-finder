import SwiftUI
import VisionKit
import VinylCore

/// Scanner QR-koden på et reolskilt og åbner sektionen.
struct ScanView: View {
    @Environment(PhoneModel.self) private var model
    @State private var unknownCode = false
    @State private var scanning = true

    var body: some View {
        Group {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner(isScanning: scanning) { code in
                    if !model.openScanned(code) { unknownCode = true }
                }
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    Text(unknownCode ? "Koden hører ikke til en af dine sektioner." : "Peg kameraet på QR-koden på et reolskilt.")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            } else {
                ContentUnavailableView("Kameraet kan ikke scanne her", systemImage: "qrcode.viewfinder",
                                       description: Text("Giv appen adgang til kameraet under Indstillinger › Vinyl Shelf. Du kan også scanne skiltet med Kamera-appen – så åbner sektionen her."))
            }
        }
        .navigationTitle("Scan skilt")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanning = true; unknownCode = false }
        .onDisappear { scanning = false }
        // Når en sektion åbnes, holder scanneren pause, så den ikke åbner den igen og igen.
        .onChange(of: model.openedSection) { _, opened in scanning = opened == nil }
    }
}

/// VisionKits scanner, kun QR-koder.
private struct QRScanner: UIViewControllerRepresentable {
    let isScanning: Bool
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        if isScanning, !vc.isScanning { try? vc.startScanning() }
        if !isScanning, vc.isScanning { vc.stopScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue { found(text); return }
            }
        }
    }
}

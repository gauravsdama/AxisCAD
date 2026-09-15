import SwiftUI
import AppKit

/// Supplier hand-off for production-ready CAD components. Downloads stay under
/// the user's control, then import through Axis' normal revision-safe STEP flow.
struct ComponentMarketplaceView: View {
    let onImportSTEP: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let sources: [(String, String, String, String)] = [
        ("McMaster-Carr", "Fasteners, bearings, wheels, springs, hardware", "cube.transparent", "https://www.mcmaster.com/cad-models/"),
        ("TraceParts", "Manufacturer CAD catalog and configured components", "shippingbox", "https://www.traceparts.com/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Component Marketplace").font(.title2.weight(.bold))
                    Text("Find a verified supplier model, download STEP, then place it in this Axis document.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            ForEach(sources, id: \.0) { source in
                HStack(spacing: 14) {
                    Image(systemName: source.2).font(.title2).foregroundStyle(Color.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.0).font(.headline)
                        Text(source.1).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Browse catalog") {
                        if let url = URL(string: source.3) { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.bordered)
                }
                .padding(14).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            Divider()
            HStack {
                Image(systemName: "arrow.down.doc").foregroundStyle(Color.mint)
                Text("Already downloaded a STEP file?")
                Spacer()
                Button("Import STEP…", action: onImportSTEP).buttonStyle(.borderedProminent)
            }
            Text("Tip: use the catalog's STEP format. Axis preserves the imported model as a revision-safe source part.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24).frame(width: 650, height: 430).preferredColorScheme(.dark)
    }
}

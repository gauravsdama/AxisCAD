import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let panel = Color(red: 0.075, green: 0.095, blue: 0.102)
private let dividerColor = Color(red: 0.15, green: 0.19, blue: 0.20)
private let mint = Color(red: 0.40, green: 0.93, blue: 0.71)

extension UTType {
    static let axisCADProject = UTType(exportedAs: "com.axis.cadstudio.project", conformingTo: .json)
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var prompt = ""
    @State private var validationErrors: [String] = []
    @State private var isSketchEditing = false
    @State private var isDrawingOpen = false
    @State private var isAssemblyOpen = false
    @State private var kernelValidation: CADKernelValidation?
    @State private var isKernelWorking = false
    // Start every restored document from an informative 3/4 view rather than
    // whichever plane happens to be the model's tallest axis.
    @State private var cameraRequest = CADCameraRequest(id: 0, preset: .isometric)
    @State private var gizmoMode = CADTransformGizmoMode.translate
    @State private var uniformScale = true
    @State private var isTerminalOpen = false
    @State private var isMarketplaceOpen = false
    @StateObject private var terminalSession = TerminalSession()
    private let monitor = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            HSplitView {
                featureSidebar.frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                VStack(spacing: 0) {
                    viewport
                    assistantDock.frame(height: 142)
                }.frame(minWidth: 520)
                inspector.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            }
            .padding(.top, 54)
            topBar.zIndex(1)
        }
        .onOpenURL { openExternalDocument($0) }
        .frame(minWidth: 1050, minHeight: 680)
        .background(Color(red: 0.05, green: 0.067, blue: 0.072))
        .preferredColorScheme(.dark)
        // Escape is a universal, non-destructive route out of any temporary
        // workspace. No tool or mode should ever strand a user in its UI.
        .onExitCommand { returnToModel() }
        .onReceive(monitor) { _ in store.reloadIfChanged() }
        .alert("Axis CAD", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
        .sheet(isPresented: $isTerminalOpen) {
            TerminalView(session: terminalSession, workingDirectory: store.dataDirectory)
        }
        .sheet(isPresented: $isMarketplaceOpen) {
            ComponentMarketplaceView(onImportSTEP: { isMarketplaceOpen = false; importSTEP() })
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "triangle.inset.filled").foregroundStyle(mint)
                Text("AXIS").font(.system(size: 16, weight: .bold, design: .rounded))
                Text("CAD STUDIO").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(width: 220, alignment: .leading)
            Menu {
                Button("New part", systemImage: "doc.badge.plus") { newDocument() }
                    .keyboardShortcut("n")
                Button("Open…", systemImage: "folder") { openDocument() }
                    .keyboardShortcut("o")
                if !store.recentDocumentPaths.isEmpty {
                    Menu("Open Recent") {
                        ForEach(store.recentDocumentPaths, id: \.self) { recentPath in
                            Button(URL(fileURLWithPath: recentPath).lastPathComponent) { openRecent(recentPath) }
                        }
                    }
                }
                Button("Import STEP…", systemImage: "cube.transparent") { importSTEP() }
                Button("Save", systemImage: "square.and.arrow.down") { saveDocument() }
                    .keyboardShortcut("s")
                Button("Save As…", systemImage: "square.and.arrow.down") { saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                if !store.checkpointSummaries.isEmpty {
                    Menu("Recover Checkpoint") {
                        ForEach(store.checkpointSummaries.prefix(12)) { checkpoint in
                            Button("r\(checkpoint.revision) · \(checkpoint.name)") { restoreCheckpoint(checkpoint) }
                        }
                    }
                }
                Divider()
                Button("Export STL…", systemImage: "shippingbox") { exportDocument() }
                Button("Export STEP…", systemImage: "cube.transparent") { exportSTEP() }
                if !store.assemblyInstances.isEmpty { Button("Export Assembly STEP…", systemImage: "square.3.layers.3d") { exportAssemblySTEP() } }
            } label: { Label("File", systemImage: "doc").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            if isInSecondaryWorkspace {
                Button(action: returnToModel) {
                    Label("Back to Model", systemImage: "chevron.backward.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(mint)
                .foregroundStyle(.black)
                .help("Return to the 3D model (Esc)")
                Text(activeWorkspaceName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(mint)
            }
            toolButton(isSketchEditing ? "Finish sketch" : "Edit sketch", isSketchEditing ? "checkmark.circle" : "pencil.and.outline") {
                if !["sketch", "profile_sketch"].contains(store.selectedFeature?.kind ?? "") { store.selectedFeatureId = "sketch-base" }
                isDrawingOpen = false
                isSketchEditing.toggle()
            }
            Menu {
                Menu("New profile sketch") {
                    Button("XY plane") { createProfileSketch("XY") }
                    Button("XZ plane") { createProfileSketch("XZ") }
                    Button("YZ plane") { createProfileSketch("YZ") }
                }
                Divider()
                Button("Add box", systemImage: "cube") { store.addPrimitive(kind: "box") }
                Button("Add cylinder", systemImage: "cylinder") { store.addPrimitive(kind: "cylinder") }
                Button("Add cone", systemImage: "cone") { store.addPrimitive(kind: "cone") }
                Button("Add sphere", systemImage: "circle.fill") { store.addPrimitive(kind: "sphere") }
                Button("Add torus", systemImage: "circle.dotted.circle") { store.addPrimitive(kind: "torus") }
                Divider()
                Button("Component marketplace…", systemImage: "shippingbox.and.arrow.backward") { isMarketplaceOpen = true }
            } label: { Label("Part", systemImage: "cube").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button(isAssemblyOpen ? "Back to model workspace" : "Open assembly workspace") { isAssemblyOpen.toggle(); isSketchEditing = false; isDrawingOpen = false }
                Divider()
                if let selected = store.selectedFeature, store.assemblySourceCandidates.contains(where: { $0.id == selected.id }) {
                    Button("Create instance of \(selected.name)", systemImage: "square.3.layers.3d") { createAssemblyInstance(selected.id) }
                } else {
                    Menu("Create instance from…") {
                        ForEach(store.assemblySourceCandidates) { source in Button(source.name) { createAssemblyInstance(source.id) } }
                    }
                }
                if let selected = store.selectedFeature, selected.kind == "assembly_instance" {
                    if selected.params["fixed"] != 1, store.drivingMates(for: selected.id).isEmpty { Button("Fix \(selected.name)", systemImage: "pin.fill") { createFixedMate(selected.id) } }
                    if store.positionDrivingMate(for: selected.id) == nil {
                        Menu("Mate center to…") {
                            ForEach(store.assemblyInstances.filter { $0.id != selected.id }) { reference in Button(reference.name) { createCoincidentMate(reference.id, selected.id) } }
                        }
                        Menu("Space 10 mm from…") {
                            ForEach(store.assemblyInstances.filter { $0.id != selected.id }) { reference in Button(reference.name) { createDistanceMate(reference.id, selected.id) } }
                        }
                    }
                    if store.positionDrivingMate(for: selected.id) == nil, store.orientationDrivingMate(for: selected.id) == nil {
                        Menu("Align XY plane to…") { ForEach(store.assemblyInstances.filter { $0.id != selected.id }) { reference in Button(reference.name) { createPlaneMate(reference.id, selected.id) } } }
                        Menu("Align Z axis to…") { ForEach(store.assemblyInstances.filter { $0.id != selected.id }) { reference in Button(reference.name) { createConcentricMate(reference.id, selected.id) } } }
                    }
                    if store.orientationDrivingMate(for: selected.id) == nil {
                        Menu("Set 90° angle to…") { ForEach(store.assemblyInstances.filter { $0.id != selected.id }) { reference in Button(reference.name) { createAngleMate(reference.id, selected.id) } } }
                    }
                }
            } label: { Label("Assembly", systemImage: "square.3.layers.3d").font(.system(size: 11, weight: .medium)).foregroundStyle(isAssemblyOpen ? mint : .secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            toolButton("Inspect", "ruler") { validationErrors = store.validate() }
            toolButton(isDrawingOpen ? "Close drawing" : "Drawings", "doc.text") {
                isSketchEditing = false
                isDrawingOpen.toggle()
            }
            Menu {
                Button("Fit all", systemImage: "viewfinder") { requestCamera(.fit) }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Isometric", systemImage: "cube") { requestCamera(.isometric) }
                Button("Front", systemImage: "rectangle.front.fill") { requestCamera(.front) }.keyboardShortcut("1", modifiers: .command)
                Button("Right", systemImage: "rectangle.righthalf.filled") { requestCamera(.right) }.keyboardShortcut("2", modifiers: .command)
                Button("Top", systemImage: "rectangle.tophalf.filled") { requestCamera(.top) }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Overall assembly") { requestCamera(.reviewOverview) }
                Button("Recline & leg support") { requestCamera(.reviewRecline) }
                Button("Cockpit & displays") { requestCamera(.reviewCockpit) }
                Button("Base & stability") { requestCamera(.reviewBase) }
            } label: { Label("View", systemImage: "view.3d").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            Button { requestCamera(.fit) } label: { Label("Fit view", systemImage: "viewfinder").font(.system(size: 11, weight: .medium)) }
                .foregroundStyle(.secondary).keyboardShortcut("0", modifiers: .command).help("Fit full model (⌘0)")
            Button { requestCamera(.front) } label: { Label("Front", systemImage: "rectangle.front.fill").font(.system(size: 11, weight: .medium)) }
                .foregroundStyle(.secondary).keyboardShortcut("1", modifiers: .command).help("Front view (⌘1)")
            Button { requestCamera(.right) } label: { Label("Side", systemImage: "rectangle.righthalf.filled").font(.system(size: 11, weight: .medium)) }
                .foregroundStyle(.secondary).keyboardShortcut("2", modifiers: .command).help("Side view (⌘2)")
            Button { requestCamera(.top) } label: { Label("Top", systemImage: "rectangle.tophalf.filled").font(.system(size: 11, weight: .medium)) }
                .foregroundStyle(.secondary).keyboardShortcut("3", modifiers: .command).help("Top view (⌘3)")
            Menu {
                Button("Overall assembly") { requestCamera(.reviewOverview) }
                Button("Recline & leg support") { requestCamera(.reviewRecline) }
                Button("Cockpit & displays") { requestCamera(.reviewCockpit) }
                Button("Base & stability") { requestCamera(.reviewBase) }
            } label: { Label("Review", systemImage: "photo.on.rectangle.angled").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Terminal") { isTerminalOpen = true }.buttonStyle(.bordered)
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).keyboardShortcut("z")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Checkpoint") { try? store.checkpoint(label: "manual") }.buttonStyle(.bordered)
            Button("Export") { exportDocument() }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(panel)
        .overlay(alignment: .bottom) { Rectangle().fill(dividerColor).frame(height: 1) }
    }

    private func toolButton(_ title: String, _ icon: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)) }.foregroundStyle(.secondary)
    }

    private var isInSecondaryWorkspace: Bool { isSketchEditing || isDrawingOpen || isAssemblyOpen }

    private var activeWorkspaceName: String {
        if isSketchEditing { return "Sketch workspace" }
        if isDrawingOpen { return "Drawing workspace" }
        if isAssemblyOpen { return "Assembly workspace" }
        return "Model workspace"
    }

    private func returnToModel() {
        guard isInSecondaryWorkspace else { return }
        isSketchEditing = false
        isDrawingOpen = false
        isAssemblyOpen = false
        store.status = "Returned to 3D model · Esc exits temporary workspaces"
        requestCamera(.fit)
    }

    private var featureSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(isAssemblyOpen ? "ASSEMBLY" : "MODEL", trailing: "plus")
            HStack {
                Image(systemName: "cube.transparent").foregroundStyle(mint)
                Text(store.document.name)
                if store.hasUnsavedChanges {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).help("Unsaved project changes")
                }
                Spacer()
                Text(store.projectURL?.lastPathComponent ?? "UNSAVED AXISCAD").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
                .padding(10).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 10)
            if isAssemblyOpen {
                let mass = store.assemblyMassSummary
                HStack(spacing: 6) {
                    Image(systemName: "scalemass").foregroundStyle(mint)
                    Text("MASS \(mass.totalMassGrams.formatted(.number.precision(.fractionLength(0...2)))) g")
                    Spacer()
                    Text("\(mass.assignedInstanceCount)/\(mass.totalInstanceCount) assigned")
                }.font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12)
                Text("INSTANCES · \(store.assemblyInstances.count)").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 6)
                ForEach(store.assemblyInstances) { feature in featureRow(feature) }
                Text("MATES · \(store.assemblyMates.count)").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                ForEach(store.assemblyMates) { feature in featureRow(feature) }
                Text("SOURCE PARTS").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                ForEach(store.assemblySourceCandidates) { feature in featureRow(feature) }
            } else {
                Text("BODY 01").font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 6)
                ForEach(store.document.features) { feature in featureRow(feature) }
            }
            sectionTitle("CHANGE HISTORY", trailing: "arrow.up.right").padding(.top, 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.document.operations.prefix(20)) { operation in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(operation.author == "ai" || operation.author == "codex" ? mint : .blue).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(operation.kind.replacingOccurrences(of: "_", with: " ").capitalized).font(.system(size: 10, weight: .semibold))
                                if let parameter = operation.parameter, let value = operation.value { Text("\(parameter) → \(value.formatted()) \(store.document.units)").font(.caption2).foregroundStyle(.secondary) }
                                Text("\(operation.author.uppercased()) · r\(operation.revision)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }.padding(.vertical, 9).overlay(alignment: .bottom) { Rectangle().fill(dividerColor.opacity(0.55)).frame(height: 1) }
                    }
                }.padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
        }.background(panel)
    }

    private func featureRow(_ feature: CADFeature) -> some View {
        Button { store.selectedFeatureId = feature.id } label: {
            HStack(spacing: 9) {
                if feature.kind == "assembly_mate" {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                } else {
                    Button { store.setVisibility(featureId: feature.id, visible: !feature.visible) } label: { Image(systemName: feature.visible ? "eye" : "eye.slash").font(.caption2).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
                if feature.kind == "imported_step" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("IMPORTED STEP"); Spacer(); Text("BODY \(Int(feature.params["body_number"] ?? 1))") }
                            .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Label("Retained BRep · editable downstream", systemImage: "checkmark.seal.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(mint)
                        Text(feature.assetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Missing asset").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text("Use Move Body, booleans, modifiers, materials, instances, validation, and STEP export normally.").font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                Image(systemName: icon(for: feature.kind)).frame(width: 16).foregroundStyle(feature.id == store.selectedFeatureId ? mint : .secondary)
                Text(feature.name).lineLimit(1)
                Spacer()
                if feature.kind == "assembly_instance", feature.params["fixed"] == 1 { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(mint) }
            }.padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(feature.id == store.selectedFeatureId ? mint.opacity(0.11) : .clear)
        .overlay(alignment: .leading) { if feature.id == store.selectedFeatureId { Rectangle().fill(mint).frame(width: 2) } }
    }

    private var viewport: some View {
        ZStack(alignment: .topLeading) {
            if isSketchEditing {
                if let feature = store.selectedFeature, feature.kind == "profile_sketch" {
                    ProfileSketchEditorView(feature: feature, units: store.document.units, onAdd: { entity in
                        do { try store.addSketchEntity(sketchId: feature.id, entity: entity) } catch { store.lastError = error.localizedDescription }
                    }, onDelete: { entityId in
                        do { try store.deleteSketchEntity(sketchId: feature.id, entityId: entityId) } catch { store.lastError = error.localizedDescription }
                    }, onToggleConstruction: { entityId in
                        do { try store.toggleSketchEntityConstruction(sketchId: feature.id, entityId: entityId) } catch { store.lastError = error.localizedDescription }
                    }, onAddConstraint: { constraint in
                        do { try store.addSketchConstraint(sketchId: feature.id, constraint: constraint) } catch { store.lastError = error.localizedDescription }
                    }, onUpdateConstraint: { constraintId, value in
                        do { try store.updateSketchConstraintValue(sketchId: feature.id, constraintId: constraintId, value: value) } catch { store.lastError = error.localizedDescription }
                    }, onTrimExtend: { lineId, referenceLineId, endpoint, mode in
                        do { try store.trimOrExtendSketchLine(sketchId: feature.id, lineId: lineId, referenceLineId: referenceLineId, endpoint: endpoint, mode: mode) } catch { store.lastError = "\(mode.capitalized) failed: choose a crossing reference and the endpoint on the side to change." }
                    }, onExtrude: {
                        do { try store.createExtrusion(sketchId: feature.id); isSketchEditing = false } catch { store.lastError = "Close the profile before extruding." }
                    }, onFinish: { isSketchEditing = false })
                } else {
                    SketchEditorView(solution: SketchSolver.solve(document: store.document), units: store.document.units) { width, height, diameter, offset in
                        do { try store.setSketchDimensions(width: width, height: height, holeDiameter: diameter, holeOffset: offset) }
                        catch { store.lastError = store.lastError ?? error.localizedDescription }
                    }
                    .id(store.document.revision)
                }
            } else if isDrawingOpen {
                DrawingSheetView(sheet: CADDrawingSheet.make(document: store.document), onExportPDF: exportDrawingPDF, onExportDXF: exportDrawingDXF, onReturnToModel: { isDrawingOpen = false })
            } else {
                MetalViewport(document: store.motionPreviewDocument, selectedFeatureId: store.selectedFeatureId, selectedSurface: store.selectedSurface, sectionPlane: store.sectionPlane, measurementProbe: store.measurementProbe, isolatedFeatureId: store.isolatedFeatureId, explodedDistance: store.explodedDistance, showsTransformGizmo: !store.isMeasuring && store.explodedDistance == 0 && store.motionStudy == nil && isTransformableSelection, gizmoMode: gizmoMode, uniformScale: uniformScale, kernelMeshes: store.kernelRenderMeshes, cameraRequest: cameraRequest, onSelect: { hit in
                    if store.motionStudy != nil {
                        store.selectedFeatureId = hit?.featureId
                        store.status = hit.map { "Selected \($0.featureId) in motion preview" } ?? "Selection cleared"
                    } else if store.isMeasuring {
                        store.addMeasurementPoint(hit)
                    } else {
                        store.selectSurface(hit)
                        store.status = hit.map { surface in
                            let name = store.document.features.first { $0.id == surface.featureId }?.name ?? surface.featureId
                            return surface.topologyEdgeId.map { "Selected \(name) · BRep edge E\($0)" }
                                ?? surface.topologyFaceId.map { "Selected \(name) · BRep face F\($0)" }
                                ?? "Selected \(name) · surface triangle \(surface.triangleIndex)"
                        } ?? "Selection cleared"
                    }
                }, onMove: { featureId, x, y, z in
                    do { try store.setTransform(featureId: featureId, x: x, y: y, z: z) }
                    catch { store.lastError = error.localizedDescription }
                }, onRotate: { featureId, x, y, z in
                    do { try store.setRotation(featureId: featureId, x: x, y: y, z: z) }
                    catch { store.lastError = error.localizedDescription }
                }, onScale: { featureId, x, y, z in
                    do { try store.setScale(featureId: featureId, x: x, y: y, z: z) }
                    catch { store.lastError = error.localizedDescription }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 12) {
                    Label("Perspective", systemImage: "view.3d")
                    Text(store.document.units)
                    Spacer()
                    Text(store.isKernelRendering ? "KERNEL REBUILD…" : "GPU · METAL 4")
                    Text("REV \(store.document.revision)")
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).padding(12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VIEW ORIENTATION").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Button("Fit all") { requestCamera(.fit) }
                        Button("Front") { requestCamera(.front) }
                        Button("Side") { requestCamera(.right) }
                        Button("Top") { requestCamera(.top) }
                    }
                    HStack(spacing: 5) {
                        Button("Hero") { requestCamera(.reviewOverview) }
                        Button("Recline") { requestCamera(.reviewRecline) }
                        Button("Cockpit") { requestCamera(.reviewCockpit) }
                        Button("Base") { requestCamera(.reviewBase) }
                    }
                    Text("Drag to orbit · Scroll/pinch to zoom · ⇧ drag to pan")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .padding(9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .buttonStyle(.bordered)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                // Keep this below the status ribbon. Previously both overlays
                // shared the top-left corner, making the view controls appear
                // to be missing even though they were present.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 42)
                .padding(.leading, 12)
                .zIndex(2)
                VStack(spacing: 2) {
                    Text("Z ↑").foregroundStyle(.blue)
                    HStack(spacing: 8) {
                        Text("X →").foregroundStyle(.red)
                        Text("Y ◉").foregroundStyle(.green)
                    }
                    Text("WORLD AXES").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12).padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Button { requestCamera(.fit) } label: { Label("Fit", systemImage: "viewfinder") }
                    Menu {
                        Button("Isometric", systemImage: "cube") { requestCamera(.isometric) }
                        Button("Front", systemImage: "square") { requestCamera(.front) }
                        Button("Top", systemImage: "square.tophalf.filled") { requestCamera(.top) }
                        Button("Right", systemImage: "square.righthalf.filled") { requestCamera(.right) }
                    } label: { Label("View", systemImage: "view.3d") }
                    Menu {
                        Button("Overall assembly", systemImage: "cube") { requestCamera(.reviewOverview) }
                        Button("Recline & leg support", systemImage: "person.fill") { requestCamera(.reviewRecline) }
                        Button("Cockpit & displays", systemImage: "display.3") { requestCamera(.reviewCockpit) }
                        Button("Base & stability", systemImage: "circle.grid.cross") { requestCamera(.reviewBase) }
                    } label: { Label("Review", systemImage: "photo.on.rectangle.angled") }
                    .help("Project review snapshots selected from the assembly's ergonomic, cockpit, and base requirements")
                    if isTransformableSelection {
                        Picker("Gizmo", selection: $gizmoMode) {
                            Text("Move").tag(CADTransformGizmoMode.translate)
                            Text("Rotate").tag(CADTransformGizmoMode.rotate)
                            Text("Scale").tag(CADTransformGizmoMode.scale)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 168)
                        if gizmoMode == .scale {
                            Toggle("Uniform", isOn: $uniformScale).toggleStyle(.button)
                                .help(uniformScale ? "Uniform scaling is locked" : "Scale one world axis at a time")
                        }
                    }
                    if store.isolatedFeatureId != nil {
                        Button("Show All", systemImage: "square.stack.3d.up") { store.setIsolatedFeature(nil) }
                    } else if let selected = store.selectedFeatureId {
                        Button("Isolate", systemImage: "square.dashed") { store.setIsolatedFeature(selected) }
                    }
                    if isAssemblyOpen, !store.assemblyInstances.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                            Slider(value: Binding(get: { store.explodedDistance }, set: { store.setExplodedDistance($0) }), in: 0...100, step: 1).frame(width: 90)
                            Text("\(Int(store.explodedDistance)) mm").frame(width: 42, alignment: .trailing)
                        }.help("Non-destructive exploded assembly view")
                    }
                    Button { store.toggleMeasurementMode() } label: {
                        Label(store.isMeasuring ? "Measuring" : "Measure", systemImage: "ruler")
                    }
                    .tint(store.isMeasuring ? .yellow : nil)
                    .disabled(store.motionStudy != nil || store.explodedDistance > 0)
                    if store.measurementProbe != nil {
                        Button { store.clearMeasurement() } label: { Image(systemName: "xmark") }
                            .help("Clear measurement")
                    }
                    Menu {
                        Button("X plane") { store.setSection(axis: "x") }
                        Button("Y plane") { store.setSection(axis: "y") }
                        Button("Z plane") { store.setSection(axis: "z") }
                        if store.sectionPlane != nil { Divider(); Button("Clear section", role: .destructive) { store.clearSection() } }
                    } label: { Label(store.sectionPlane == nil ? "Section" : "Section \(store.sectionPlane!.axis.uppercased())", systemImage: "square.split.diagonal.2x2") }
                    if let section = store.sectionPlane {
                        TextField("Offset", value: sectionOffsetBinding, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 58).multilineTextAlignment(.trailing)
                        Button(section.flipped ? "Flip ✓" : "Flip") { store.setSection(axis: section.axis, offset: section.offset, flipped: !section.flipped) }
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 34).padding(.trailing, 12)
                if let probe = store.measurementProbe {
                    VStack {
                        HStack {
                            measurementOverlay(probe)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.top, 72).padding(.leading, 12)
                    .allowsHitTesting(false)
                }
                VStack { Spacer(); HStack { Label("Native renderer", systemImage: "circle.fill").foregroundStyle(mint); Spacer(); Text(viewportHint) }.font(.system(size: 9, design: .monospaced)).padding(12) }
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("PROPERTIES", trailing: "ellipsis")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                if let feature = store.selectedFeature {
                let measurement = CADMeasurement.measure(document: store.document, kernelMeshes: store.kernelRenderMeshes)
                Label(feature.kind.uppercased(), systemImage: icon(for: feature.kind)).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(mint).padding(.top, 12)
                Text(feature.name).font(.system(size: 19, weight: .semibold, design: .rounded)).padding(.vertical, 7)
                Divider().padding(.bottom, 12)
                if feature.kind == "assembly_instance" {
                    let drivingMate = store.drivingMate(for: feature.id), drivingMates = store.drivingMates(for: feature.id), dof = store.assemblyDegreesOfFreedom(for: feature)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("ASSEMBLY INSTANCE"); Spacer(); Text(feature.params["fixed"] == 1 ? "FIXED · 0 DOF" : drivingMate == nil ? "FREE · 6 DOF" : "MATED · \(dof) DOF") }
                            .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text(store.instanceSource(feature)?.name ?? feature.inputFeatureIds?.first ?? "Missing source").font(.system(size: 11, weight: .semibold))
                        if !drivingMates.isEmpty { Text("Driven by \(drivingMates.map(\.name).joined(separator: " + "))").font(.caption2).foregroundStyle(.secondary) }
                        if feature.params["fixed"] != 1, drivingMates.isEmpty {
                            Button("Fix instance") { createFixedMate(feature.id) }.buttonStyle(.bordered).controlSize(.small)
                        }
                        if store.positionDrivingMate(for: feature.id) == nil, feature.params["fixed"] != 1, !store.assemblyInstances.filter({ $0.id != feature.id }).isEmpty {
                            Menu("Mate center to…") {
                                ForEach(store.assemblyInstances.filter { $0.id != feature.id }) { reference in Button(reference.name) { createCoincidentMate(reference.id, feature.id) } }
                            }.buttonStyle(.bordered).controlSize(.small)
                            Menu("Space 10 mm from…") {
                                ForEach(store.assemblyInstances.filter { $0.id != feature.id }) { reference in Button(reference.name) { createDistanceMate(reference.id, feature.id) } }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        if store.positionDrivingMate(for: feature.id) == nil, store.orientationDrivingMate(for: feature.id) == nil, feature.params["fixed"] != 1 {
                            Menu("Align XY plane to…") { ForEach(store.assemblyInstances.filter { $0.id != feature.id }) { reference in Button(reference.name) { createPlaneMate(reference.id, feature.id) } } }.buttonStyle(.bordered).controlSize(.small)
                            Menu("Align Z axis to…") { ForEach(store.assemblyInstances.filter { $0.id != feature.id }) { reference in Button(reference.name) { createConcentricMate(reference.id, feature.id) } } }.buttonStyle(.bordered).controlSize(.small)
                        }
                        if store.orientationDrivingMate(for: feature.id) == nil, feature.params["fixed"] != 1 {
                            Menu("Set 90° angle to…") { ForEach(store.assemblyInstances.filter { $0.id != feature.id }) { reference in Button(reference.name) { createAngleMate(reference.id, feature.id) } } }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "assembly_mate" {
                    let type = Int(feature.params["mate_type"] ?? -1), fixed = type == 0, distance = type == 2, plane = type == 3, concentric = type == 4, angleMate = type == 5
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("ASSEMBLY MATE"); Spacer(); Text(fixed ? "FIXED" : distance ? "DISTANCE" : plane ? "PLANE · 1 DOF" : concentric ? "CONCENTRIC · 2 DOF" : angleMate ? "ANGLE · ORIENTATION" : "COINCIDENT") }
                            .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text(fixed ? "Grounds \(feature.inputFeatureIds?.first ?? "instance")" : "\(feature.inputFeatureIds?.last ?? "instance") follows \(feature.inputFeatureIds?.first ?? "reference")")
                            .font(.system(size: 11, weight: .semibold))
                        if angleMate {
                            Text("ANGLE · SPIN").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                ForEach(["angle", "spin"], id: \.self) { key in
                                    TextField(key.uppercased(), value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            HStack(spacing: 5) {
                                ForEach(["hinge_axis_x", "hinge_axis_y", "hinge_axis_z"], id: \.self) { key in
                                    TextField("HINGE \(key.suffix(1).uppercased())", value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            Text("Orientation-only: compose with one coincident or distance mate; spin stays explicit.").font(.caption2).foregroundStyle(.secondary)
                        } else if concentric {
                            Text("AXIAL SLIDE · SPIN").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                ForEach(["reference_axis_x", "reference_axis_y", "reference_axis_z", "axial_offset", "spin"], id: \.self) { key in
                                    TextField(key == "axial_offset" ? "SLIDE" : key == "spin" ? "SPIN°" : key.suffix(1).uppercased(), value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            Button(feature.params["opposed"] == 1 ? "Use aligned axes" : "Oppose axes") {
                                do { try store.setParameter(featureId: feature.id, key: "opposed", value: feature.params["opposed"] == 1 ? 0 : 1) } catch { store.lastError = error.localizedDescription }
                            }.buttonStyle(.bordered).controlSize(.small)
                            Text("Axes remain concentric while axial slide and spin regenerate explicitly.").font(.caption2).foregroundStyle(.secondary)
                        } else if plane {
                            Text("NORMAL OFFSET").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                ForEach(["reference_normal_x", "reference_normal_y", "reference_normal_z", "distance", "spin"], id: \.self) { key in
                                    TextField(key == "distance" ? "MM" : key == "spin" ? "SPIN°" : key.suffix(1).uppercased(), value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            Button(feature.params["opposed"] == 1 ? "Use aligned normals" : "Oppose normals") {
                                do { try store.setParameter(featureId: feature.id, key: "opposed", value: feature.params["opposed"] == 1 ? 0 : 1) } catch { store.lastError = error.localizedDescription }
                            }.buttonStyle(.bordered).controlSize(.small)
                            Text("Aligns local face normals and anchor points; spin about the normal remains editable.").font(.caption2).foregroundStyle(.secondary)
                        } else if distance {
                            Text("AXIS · DISTANCE").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                ForEach(["axis_x", "axis_y", "axis_z", "distance"], id: \.self) { key in
                                    TextField(key == "distance" ? "MM" : key.suffix(1).uppercased(), value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            Text("The axis is normalized automatically; distance stays positive and regenerative.").font(.caption2).foregroundStyle(.secondary)
                        } else if !fixed {
                            Text("OFFSET").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                ForEach(["x", "y", "z"], id: \.self) { axis in
                                    TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "offset_\(axis)"), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                            Text("Offsets are solved from the reference instance and regenerate through both local anchors.").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !fixed {
                            Divider().padding(.vertical, 2)
                            if let study = store.motionStudy, study.mateId == feature.id {
                                HStack { Text("MOTION PREVIEW"); Spacer(); Text("\(study.value.formatted(.number.precision(.fractionLength(0...2))))") }
                                    .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                Picker("Driver", selection: Binding(get: { study.parameter }, set: { store.setMotionParameter($0) })) {
                                    ForEach(store.motionParameters(for: feature), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").uppercased()).tag($0) }
                                }.labelsHidden().pickerStyle(.menu)
                                HStack(spacing: 5) {
                                    TextField("MIN", value: Binding(get: { store.motionStudy?.minimum ?? 0 }, set: { store.setMotionRange(minimum: $0, maximum: store.motionStudy?.maximum ?? 1) }), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder)
                                    TextField("MAX", value: Binding(get: { store.motionStudy?.maximum ?? 1 }, set: { store.setMotionRange(minimum: store.motionStudy?.minimum ?? 0, maximum: $0) }), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder)
                                }
                                Slider(value: Binding(get: { store.motionStudy?.progress ?? 0 }, set: { store.setMotionProgress($0) }), in: 0...1)
                                HStack {
                                    Button(study.playing ? "Pause" : "Play") { store.toggleMotionPlayback() }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                                    Button("Close") { store.clearMotionStudy() }.buttonStyle(.bordered)
                                }.controlSize(.small)
                                Text("GPU-only solved-pose preview; document revision and exports stay unchanged.").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Button("Preview mate motion") {
                                    do { try store.configureMotionStudy(mateId: feature.id) } catch { store.lastError = error.localizedDescription }
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if let surface = store.selectedSurface, surface.featureId == feature.id {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("SURFACE")
                            Spacer()
                            Text(surface.topologyEdgeId.map { "BREP EDGE E\($0)" } ?? surface.topologyFaceId.map { "BREP FACE F\($0)" } ?? "MESH TRIANGLE \(surface.triangleIndex)")
                        }
                            .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Hit \(compact(Double(surface.position.x))), \(compact(Double(surface.position.y))), \(compact(Double(surface.position.z))) \(store.document.units)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("Normal \(compact(Double(surface.normal.x))), \(compact(Double(surface.normal.y))), \(compact(Double(surface.normal.z)))")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        if let faces = surface.topologyEdgeFaceIds, faces.count == 2 {
                            Text("Adjacent faces F\(faces[0]) · F\(faces[1])")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        if let edge = store.selectedTopologyEdge {
                            Text("\(edge.hasExactLength ? "Length" : "Polyline length") \(compact(edge.measuredLength)) \(store.document.units)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            if let radius = edge.radius {
                                Text("Radius \(compact(radius)) \(store.document.units) · analytic circle")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            } else if !edge.hasExactLength {
                                Text("Curved-edge estimate from \(edge.segmentCount) BRep display segments")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if let face = store.selectedTopologyFace {
                            Text("\(face.areaExact ? "Area" : "Tessellated area") \(compact(face.area)) \(store.document.units)²")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text("\(face.surfaceKind.capitalized) surface\(face.radius.map { " · radius \(compact($0)) \(store.document.units)" } ?? "")")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if let probe = store.measurementProbe {
                    measurementInspector(probe).padding(.bottom, 12)
                }
                if !store.clearanceCandidates.isEmpty || store.clearanceResult != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("CLEARANCE").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            if store.isCheckingClearance { ProgressView().controlSize(.small) }
                        }
                        if let result = store.clearanceResult {
                            Text(result.classification == "interference" ? "Interference" : result.classification == "touching" ? "Touching" : "Clear")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(result.intersecting ? .red : mint)
                            Text("\(abs(result.distance).formatted(.number.precision(.fractionLength(0...3)))) \(store.document.units) · \(result.secondFeatureId)")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text("A \(compact(result.pointA.x)), \(compact(result.pointA.y)), \(compact(result.pointA.z))  →  B \(compact(result.pointB.x)), \(compact(result.pointB.y)), \(compact(result.pointB.z))")
                                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Menu("Compare with body…") {
                            ForEach(store.clearanceCandidates) { candidate in
                                Button(candidate.name) { Task { await store.checkClearance(to: candidate.id) } }
                            }
                        }
                        .buttonStyle(.bordered).disabled(store.isCheckingClearance)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if ["edge_fillet", "edge_chamfer"].contains(feature.kind), let mode = feature.params["selector_mode"] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EDGE INTENT").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text(mode == 1
                            ? feature.params["selector_face_id"].map { "Nearest edge on BRep face F\(Int($0))" } ?? "Nearest edge to selected point"
                            : mode == 2 ? "Edges parallel to direction" : mode == 3 ? "Stable BRep edge E\(Int(feature.params["selector_edge_id"] ?? 0))" : "All eligible edges")
                            .font(.system(size: 11, weight: .semibold))
                        if mode > 0 {
                            Text("\(compact(feature.params["selector_x"] ?? 0)), \(compact(feature.params["selector_y"] ?? 0)), \(compact(feature.params["selector_z"] ?? 0))")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "assembly_instance" || store.assemblySourceCandidates.contains(where: { $0.id == feature.id }) {
                    let material = store.material(for: feature)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("MATERIAL").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            if feature.kind == "assembly_instance" { Text("SOURCE PART").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary) }
                        }
                        Picker("Material", selection: Binding(get: { material }, set: { preset in
                            do { try store.setMaterial(featureId: feature.id, preset: preset) } catch { store.lastError = error.localizedDescription }
                        })) {
                            ForEach(CADMaterialPreset.allCases) { preset in Text(preset.name).tag(preset) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        if material != .unassigned {
                            Text("Density \(material.density.formatted(.number.precision(.fractionLength(5)))) g/mm³")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        if feature.kind == "assembly_instance" {
                            let mass = store.assemblyMassSummary
                            Text("Assembly \(mass.totalMassGrams.formatted(.number.precision(.fractionLength(0...2)))) g · mesh-derived preview")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "sweep_feature" {
                    let frameMode = CADSweepFrameMode(rawValue: Int((feature.params["frame_mode"] ?? 0).rounded())) ?? .minimumTwist
                    let guideCount = Int((feature.params["guide_point_count"] ?? 0).rounded())
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SECTION ORIENTATION").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            if guideCount > 0 { Text("RAIL CONTROLLED").font(.system(size: 8, design: .monospaced)).foregroundStyle(mint) }
                        }
                        Picker("Orientation", selection: Binding(get: { frameMode }, set: { mode in
                            do { try store.setParameter(featureId: feature.id, key: "frame_mode", value: Double(mode.rawValue)) } catch { store.lastError = error.localizedDescription }
                        })) {
                            ForEach(CADSweepFrameMode.allCases) { mode in Text(mode.name).tag(mode) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        if frameMode == .fixedUp {
                            HStack(spacing: 5) {
                                Text("UP").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 24, alignment: .leading)
                                ForEach(["x", "y", "z"], id: \.self) { axis in
                                    TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "up_\(axis)"), format: .number.precision(.fractionLength(0...3)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        if guideCount > 0 {
                            ForEach(0..<guideCount, id: \.self) { pointIndex in
                                HStack(spacing: 5) {
                                    Text("R\(pointIndex + 1)").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 24, alignment: .leading)
                                    ForEach(["x", "y", "z"], id: \.self) { axis in
                                        TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "guide_\(pointIndex)_\(axis)"), format: .number.precision(.fractionLength(0...2)))
                                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                            Text("The rail overrides the orientation mode and points each section toward the corresponding rail position.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(frameMode == .minimumTwist ? "Parallel transport minimizes unwanted roll." : frameMode == .curvature ? "Sections follow local path curvature with flip suppression." : "The up vector is projected perpendicular to the path.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "sweep_feature", let segmentCountValue = feature.params["path_segment_count"] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("PATH GUIDE").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(segmentCountValue.rounded())) SEGMENTS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        ForEach(0..<Int(segmentCountValue.rounded()), id: \.self) { segmentIndex in
                            let isArc = feature.params["path_\(segmentIndex)_kind"] == 1
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(segmentIndex + 1) · \(isArc ? "ARC" : "LINE")").font(.system(size: 9, weight: .semibold, design: .monospaced))
                                ForEach(isArc ? ["start", "mid", "end"] : ["start", "end"], id: \.self) { role in
                                    HStack(spacing: 5) {
                                        Text(role == "start" ? "S" : role == "mid" ? "M" : "E").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 12)
                                        ForEach(["x", "y", "z"], id: \.self) { axis in
                                            TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "path_\(segmentIndex)_\(role)_\(axis)"), format: .number.precision(.fractionLength(0...2)))
                                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                        }
                                    }
                                }
                            }
                        }
                        let continuity = CADSweepContinuityMode(rawValue: Int((feature.params["continuity_mode"] ?? 0).rounded())) ?? .position
                        Picker("Join continuity", selection: Binding(get: { continuity }, set: { mode in
                            do { try store.setParameter(featureId: feature.id, key: "continuity_mode", value: Double(mode.rawValue)) } catch { store.lastError = error.localizedDescription }
                        })) {
                            ForEach(CADSweepContinuityMode.allCases) { mode in Text(mode.name).tag(mode) }
                        }.pickerStyle(.menu)
                        if continuity != .position {
                            HStack {
                                Text("Angular tolerance").font(.system(size: 10))
                                Spacer()
                                TextField("Degrees", value: parameterBinding(featureId: feature.id, key: "tangent_tolerance"), format: .number.precision(.fractionLength(0...2)))
                                    .textFieldStyle(.roundedBorder).frame(width: 76).multilineTextAlignment(.trailing)
                                Text("°").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Text("Connected line and true circular-arc segments; coordinate edits rebuild the BRep.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "sweep_feature", let pointCountValue = feature.params["path_point_count"] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SPLINE GUIDE").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(pointCountValue.rounded())) POINTS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        ForEach(0..<Int(pointCountValue.rounded()), id: \.self) { pointIndex in
                            HStack(spacing: 5) {
                                Text("P\(pointIndex + 1)").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 20, alignment: .leading)
                                ForEach(["x", "y", "z"], id: \.self) { axis in
                                    TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "path_\(pointIndex)_\(axis)"), format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        let tangentMode = Int((feature.params["tangent_mode"] ?? 0).rounded())
                        Toggle("Endpoint tangent handles", isOn: Binding(get: { tangentMode != 0 }, set: { enabled in
                            do { try store.setParameter(featureId: feature.id, key: "tangent_mode", value: enabled ? 3 : 0) } catch { store.lastError = error.localizedDescription }
                        })).toggleStyle(.switch).controlSize(.small)
                        if tangentMode != 0 {
                            ForEach(["start", "end"], id: \.self) { endpoint in
                                HStack(spacing: 5) {
                                    Text(endpoint == "start" ? "T0" : "T1").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 20, alignment: .leading)
                                    ForEach(["x", "y", "z"], id: \.self) { axis in
                                        TextField(axis.uppercased(), value: parameterBinding(featureId: feature.id, key: "\(endpoint)_tangent_\(axis)"), format: .number.precision(.fractionLength(0...2)))
                                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                        }
                        Text("The curve passes through every point; edits rebuild the BRep and Metal mesh.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "sweep_feature", let stationCountValue = feature.params["scale_station_count"] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("VARIABLE PROFILE").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(stationCountValue.rounded())) STATIONS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 5) {
                            Text("ENDPOINT").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                            Text("PATH").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                            Text("SCALE").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                        }
                        ForEach(0..<Int(stationCountValue.rounded()), id: \.self) { stationIndex in
                            HStack(spacing: 5) {
                                Text("S\(stationIndex + 1)").font(.system(size: 9, weight: .semibold, design: .monospaced)).frame(width: 50, alignment: .leading)
                                TextField("0…1", value: parameterBinding(featureId: feature.id, key: "scale_station_\(stationIndex)_position"), format: .number.precision(.fractionLength(0...3)))
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                TextField("×", value: parameterBinding(featureId: feature.id, key: "scale_station_\(stationIndex)_factor"), format: .number.precision(.fractionLength(0...3)))
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            }
                        }
                        Text("Stations interpolate continuously between start and end scale; positions must stay ordered.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                if feature.kind == "sweep_feature", let sectionCountValue = feature.params["profile_station_count"] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("MORPH SECTIONS").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(sectionCountValue.rounded()) + 1) PROFILES").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        ForEach(0..<Int(sectionCountValue.rounded()), id: \.self) { sectionIndex in
                            let inputs = feature.inputFeatureIds ?? []
                            let sectionId = sectionIndex + 1 < inputs.count ? inputs[sectionIndex + 1] : ""
                            HStack(spacing: 6) {
                                Text(store.document.features.first(where: { $0.id == sectionId })?.name ?? "Section \(sectionIndex + 2)")
                                    .font(.system(size: 9, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0…1", value: parameterBinding(featureId: feature.id, key: "profile_station_\(sectionIndex)_position"), format: .number.precision(.fractionLength(0...3)))
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 76)
                            }
                        }
                        Text("Section perimeters are automatically resampled and seam-aligned; edit any source sketch to regenerate the solid.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.bottom, 12)
                }
                HStack { Text("PARAMETERS").font(.caption2.monospaced()).foregroundStyle(.secondary); Spacer(); Text(store.document.units).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                ForEach(feature.params.keys.filter { !$0.hasPrefix("selector_") && !$0.hasPrefix("path_") && !$0.hasPrefix("scale_station_") && !$0.hasPrefix("profile_station_") && !$0.hasPrefix("guide_") && !$0.hasPrefix("up_") && !$0.contains("_tangent_") && !$0.contains("_anchor_") && !$0.contains("_normal_") && !$0.contains("_axis_") && !["fixed", "mate_type", "opposed", "material_id", "density", "color_r", "color_g", "color_b", "body_number", "frame_mode", "tangent_mode", "continuity_mode", "tangent_tolerance"].contains($0) && !(feature.kind == "assembly_mate" && ($0.hasPrefix("offset_") || $0.hasPrefix("axis_") || $0 == "distance" || $0 == "spin" || $0 == "angle" || $0 == "axial_offset")) }.sorted(), id: \.self) { key in
                    HStack {
                        Text(key.capitalized).font(.system(size: 11))
                        Spacer()
                        if ["symmetric", "closed"].contains(key) {
                            Toggle("", isOn: Binding(get: { (feature.params[key] ?? 0) != 0 }, set: { value in
                                do { try store.setParameter(featureId: feature.id, key: key, value: value ? 1 : 0) } catch { store.lastError = error.localizedDescription }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        } else {
                            TextField(key, value: parameterBinding(featureId: feature.id, key: key), format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder).frame(width: 76).multilineTextAlignment(.trailing)
                            Text(parameterUnit(key)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(validationErrors.isEmpty ? "Geometry parameters valid" : "Validation needs attention", systemImage: validationErrors.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(validationErrors.isEmpty ? mint : .orange)
                    Text(validationErrors.first ?? "No invalid dimensions in revision \(store.document.revision)").font(.caption2).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 20)
                Button("Validate selection") { validationErrors = store.validate() }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 10)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("MODEL MEASURE"); Spacer(); Text("MESH") }
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    Text("\(compact(measurement.size.x)) × \(compact(measurement.size.y)) × \(compact(measurement.size.z)) \(store.document.units)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    HStack {
                        Text("Volume \(compact(measurement.volume)) mm³")
                        Spacer()
                        Text("\(measurement.triangleCount) tris")
                    }.font(.caption2).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 10)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("EXACT GEOMETRY").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        if isKernelWorking { ProgressView().controlSize(.mini) }
                    }
                    if let kernelValidation {
                        Label(kernelValidation.ok ? "Closed manifold · STEP ready" : "STEP ready · mesh warning", systemImage: kernelValidation.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(kernelValidation.ok ? mint : .orange)
                        Text("Kernel volume \(compact(kernelValidation.volume)) mm³ · \(kernelValidation.boundaryEdgeSegments) boundary edges")
                            .font(.caption2).foregroundStyle(.secondary)
                        Label(kernelValidation.stepRoundtrip.passed ? "STEP file reopens · bounds within 0.1 mm" : "STEP reopen needs attention", systemImage: kernelValidation.stepRoundtrip.passed ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(kernelValidation.stepRoundtrip.passed ? Color.mint : Color.orange)
                        if let error = kernelValidation.stepRoundtrip.volumeRelativeError, error > 0.01 {
                            Text("STEP re-import volume metric \(String(format: "%.3f", error * 100))% difference")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let error = kernelValidation.volumeRelativeError {
                            Text("Analytic reference deviation \(String(format: "%.3f", error * 100))%")
                                .font(.caption2).foregroundStyle(error <= 0.01 ? Color.secondary : Color.orange)
                        }
                    } else {
                        Text("The exact geometry engine loads only when needed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Check Solid") { validateWithKernel() }
                        Button("STEP…") { exportSTEP() }
                    }.buttonStyle(.bordered).disabled(isKernelWorking)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 10)
                if feature.kind == "sketch" {
                    let solved = SketchSolver.solve(document: store.document)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(solved.constraintCount) constraints").font(.system(size: 10, weight: .semibold))
                        Text(solved.isFullyConstrained ? "0 degrees of freedom" : "\(solved.degreesOfFreedom) degree of freedom").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                    Button(isSketchEditing ? "Finish sketch" : "Edit sketch") { isSketchEditing.toggle() }
                        .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.top, 8)
                }
                if feature.kind == "profile_sketch" {
                    let profile = CADProfileSketch.solve(feature: feature)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(profile.entities.count) profile entities").font(.system(size: 10, weight: .semibold))
                        Text(profile.isClosed ? "Closed profile · ready to extrude" : profile.errors.isEmpty ? "Open profile · continue drawing" : "Invalid profile · fix the reported geometry").font(.caption2).foregroundStyle(profile.isClosed ? Color.mint : Color.orange)
                        if let error = profile.errors.last { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }.padding(.top, 12)
                    Button(isSketchEditing ? "Finish sketch" : "Edit sketch") { isSketchEditing.toggle() }
                        .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.top, 8)
                    if profile.isClosed {
                        Button("Extrude 20 \(store.document.units)") {
                            do { try store.createExtrusion(sketchId: feature.id); isSketchEditing = false } catch { store.lastError = error.localizedDescription }
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                        Menu("Revolve 360° about…") {
                            Button("X axis") { createRevolve(feature.id, axis: SIMD3(1, 0, 0)) }
                            Button("Y axis") { createRevolve(feature.id, axis: SIMD3(0, 1, 0)) }
                            Button("Z axis") { createRevolve(feature.id, axis: SIMD3(0, 0, 1)) }
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                        Menu("Sweep 40 \(store.document.units) along…") {
                            Button("X axis") { createSweep(feature.id, end: SIMD3(40, 0, 0)) }
                            Button("Y axis") { createSweep(feature.id, end: SIMD3(0, 40, 0)) }
                            Button("Z axis") { createSweep(feature.id, end: SIMD3(0, 0, 40)) }
                            Divider()
                            Button("Variable profile · center 1.6×") { createVariableSweep(feature.id) }
                            Button("Line + arc path · 3 segments") { createCompositeSweep(feature.id) }
                            Button("Spline · 4 guide points") { createSplineSweep(feature.id) }
                            Button("Spline + orientation rail") { createRailSweep(feature.id) }
                            Button("Helix · R10, pitch 8 × 4") { createHelixSweep(feature.id) }
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                        if !loftCandidates(for: feature.id).isEmpty {
                            Menu("Morph sweep with…") {
                                ForEach(loftCandidates(for: feature.id)) { other in
                                    Button("\(other.name) · end section") {
                                        do {
                                            try store.createSweep(sketchId: feature.id, profileSections: [CADSweepProfileSection(sketchId: other.id, position: 1)])
                                            isSketchEditing = false
                                        } catch { store.lastError = error.localizedDescription }
                                    }
                                }
                            }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                            Menu("Loft with…") {
                                ForEach(loftCandidates(for: feature.id)) { other in
                                    Button("\(other.name) · \(compact(other.params["offset"] ?? 0)) \(store.document.units)") {
                                        do { try store.createLoft(sketchIds: [feature.id, other.id]); isSketchEditing = false }
                                        catch { store.lastError = error.localizedDescription }
                                    }
                                }
                            }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                        }
                        if !solidCandidates.isEmpty {
                            Menu("Pocket 20 \(store.document.units) through…") {
                                ForEach(solidCandidates) { target in
                                    Button(target.name) {
                                        do { try store.createPocket(targetFeatureId: target.id, sketchId: feature.id); isSketchEditing = false }
                                        catch { store.lastError = error.localizedDescription }
                                    }
                                }
                            }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 6)
                        }
                    }
                }
                if modifierInputKinds.contains(feature.kind), !booleanCandidates(for: feature.id).isEmpty {
                    Menu("Boolean with…") {
                        ForEach(booleanCandidates(for: feature.id)) { candidate in
                            Menu(candidate.name) {
                                Button("Union") { createBoolean("union", feature.id, candidate.id) }
                                Button("Subtract") { createBoolean("difference", feature.id, candidate.id) }
                                Button("Intersect") { createBoolean("intersection", feature.id, candidate.id) }
                            }
                        }
                    }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 8)
                }
                if modifierInputKinds.contains(feature.kind) {
                    Menu("Add modifier…") {
                        Button(store.selectedSurface?.featureId == feature.id ? "Fillet nearest edge" : "Fillet all edges") { createModifier("edge_fillet", feature.id) }
                        Button(store.selectedSurface?.featureId == feature.id ? "Chamfer nearest edge" : "Chamfer all edges") { createModifier("edge_chamfer", feature.id) }
                        Button("Shell") { createModifier("shell_feature", feature.id) }
                        Divider()
                        Button("Linear pattern") { createModifier("linear_pattern", feature.id) }
                        Button("Circular pattern") { createModifier("circular_pattern", feature.id) }
                    }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 8)
                }
                if ["profile_sketch", "extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "box", "cylinder", "cone", "sphere", "torus", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform", "assembly_instance", "assembly_mate"].contains(feature.kind) {
                    Button("Delete feature", role: .destructive) { store.deleteFeature(featureId: feature.id) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.top, 8)
                }
                }
                }.padding(.bottom, 14)
            }
            Text(store.status).font(.caption2).foregroundStyle(.secondary).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(dividerColor).frame(height: 1) }
        }.padding(.horizontal, 16).background(panel)
    }

    private var assistantDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Group { if store.isAIWorking { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles").foregroundStyle(mint) } }.frame(width: 28, height: 28).background(mint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading) { Text("Axis assistant").font(.system(size: 11, weight: .semibold)); Text("Document-aware · Codex MCP connected").font(.caption2).foregroundStyle(.secondary) }
                TextField("Describe a CAD change, or select geometry first…", text: $prompt).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 42).background(Color.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 5)).onSubmit(runPrompt).disabled(store.isAIWorking)
                Button(store.isAIWorking ? "Working…" : "Run", action: runPrompt).buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black).keyboardShortcut(.return, modifiers: []).disabled(store.isAIWorking)
            }.padding(16)
        HStack { Circle().fill(mint).frame(width: 6, height: 6); Text(store.status); Spacer(); Text("Scroll = zoom · ⇧ drag = pan · drag = orbit").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
        }.background(Color(red: 0.06, green: 0.08, blue: 0.085)).overlay(alignment: .top) { Rectangle().fill(dividerColor).frame(height: 1) }
    }

    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack { Text(title); Spacer(); Image(systemName: trailing) }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 38)
    }

    private func parameterBinding(featureId: String, key: String) -> Binding<Double> {
        Binding(get: { store.document.features.first { $0.id == featureId }?.params[key] ?? 0 }, set: { value in
            do { try store.setParameter(featureId: featureId, key: key, value: value) } catch { store.lastError = error.localizedDescription }
        })
    }

    private var sectionOffsetBinding: Binding<Double> {
        Binding(get: { store.sectionPlane?.offset ?? 0 }, set: { value in
            guard let section = store.sectionPlane else { return }
            store.setSection(axis: section.axis, offset: value, flipped: section.flipped)
        })
    }

    private func measurementOverlay(_ probe: CADMeasurementProbe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(probe.end == nil ? "FIRST POINT" : "MEASUREMENT", systemImage: "ruler")
                .font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.yellow)
            if let distance = probe.distance, let delta = probe.delta {
                Text("\(measurementValue(distance)) \(store.document.units)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("ΔX \(measurementValue(Double(delta.x)))  ΔY \(measurementValue(Double(delta.y)))  ΔZ \(measurementValue(Double(delta.z)))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("Click a second surface point")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.yellow.opacity(0.35)))
    }

    private func measurementInspector(_ probe: CADMeasurementProbe) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("POINT MEASURE"); Spacer(); Text(probe.end == nil ? "1 / 2" : "COMPLETE") }
                .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            if let distance = probe.distance, let delta = probe.delta {
                Text("Distance \(measurementValue(distance)) \(store.document.units)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("ΔX \(measurementValue(Double(delta.x))) · ΔY \(measurementValue(Double(delta.y))) · ΔZ \(measurementValue(Double(delta.z))) \(store.document.units)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else {
                Text("Choose the second point in the viewport.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func measurementValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private var viewportHint: String {
        if store.isMeasuring {
            return "Measure · click \(store.measurementProbe?.end == nil && store.measurementProbe != nil ? "second" : "first") surface point"
        }
        if isTransformableSelection {
            switch gizmoMode {
            case .rotate: return "Drag a colored X/Y/Z ring to rotate · Drag empty space to orbit"
            case .scale: return uniformScale ? "Drag any colored handle to scale uniformly · Drag empty space to orbit" : "Drag a colored X/Y/Z handle to scale that world axis · Drag empty space to orbit"
            case .translate: return "Drag colored X/Y/Z arrows to move · Drag empty space to orbit · ⌥ drag for planar move"
            }
        }
        return "Click to select · Drag to orbit · ⌥ drag a movable primitive"
    }

    private var isTransformableSelection: Bool {
        guard let feature = store.selectedFeature, CADTransformGizmoMath.isTransformable(feature) else { return false }
        if feature.kind == "assembly_instance" {
            if feature.params["fixed"] == 1 { return false }
            if gizmoMode == .translate, store.positionDrivingMate(for: feature.id) != nil { return false }
            if gizmoMode == .rotate, store.orientationDrivingMate(for: feature.id) != nil { return false }
        }
        return true
    }

    private func runPrompt() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !store.isAIWorking else { return }
        prompt = ""
        Task { await store.runCodex(request) }
    }
    private func compact(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
    private func parameterUnit(_ key: String) -> String {
        if key.hasPrefix("rotation_") || key == "angle" || key == "twist_angle" { return "°" }
        if key.hasPrefix("direction_") || key.hasPrefix("axis_") { return "" }
        if key == "count" { return "×" }
        if ["symmetric", "closed", "scale_start", "scale_end"].contains(key) { return "" }
        if key == "helix_turns" { return "turns" }
        return store.document.units
    }
    private func requestCamera(_ preset: CADCameraPreset) {
        cameraRequest = CADCameraRequest(id: cameraRequest.id + 1, preset: preset)
    }
    private var modifierInputKinds: Set<String> { ["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus", "extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform"] }

    private var solidCandidates: [CADFeature] {
        store.document.features.filter { $0.visible && modifierInputKinds.contains($0.kind) }
    }

    private func icon(for kind: String) -> String { ["sketch":"pencil.and.ruler", "profile_sketch":"pencil.and.scribble", "extrude_feature":"square.stack.3d.up", "pocket_feature":"square.stack.3d.down.right", "revolve_feature":"arrow.triangle.2.circlepath", "sweep_feature":"point.topleft.down.to.point.bottomright.curvepath", "loft_feature":"square.stack.3d.forward.dottedline", "pad":"square.stack.3d.up", "pocket":"circle.dashed", "fillet":"rectangle.roundedtop", "box":"cube", "cylinder":"cylinder", "cone":"cone", "sphere":"circle.fill", "torus":"circle.dotted.circle", "imported_step":"cube.transparent", "boolean_union":"square.3.layers.3d", "boolean_difference":"square.2.layers.3d", "boolean_intersection":"square.stack.3d.down.right", "edge_fillet":"rectangle.roundedtop", "edge_chamfer":"square.on.square.dashed", "shell_feature":"square.dashed", "linear_pattern":"square.grid.3x1.below.line.grid.1x2", "circular_pattern":"circle.hexagongrid.fill", "body_transform":"move.3d", "assembly_instance":"square.3.layers.3d", "assembly_mate":"link"].first { $0.key == kind }?.value ?? "cube" }

    private func booleanCandidates(for selectedId: String) -> [CADFeature] {
        return store.document.features.filter { $0.id != selectedId && $0.visible && modifierInputKinds.contains($0.kind) }
    }

    private func loftCandidates(for selectedId: String) -> [CADFeature] {
        store.document.features.filter { feature in
            feature.id != selectedId && feature.visible && feature.kind == "profile_sketch" && CADProfileSketch.solve(feature: feature).isClosed
        }
    }

    private func createBoolean(_ operation: String, _ left: String, _ right: String) {
        do { try store.createBoolean(operation: operation, leftFeatureId: left, rightFeatureId: right) }
        catch { store.lastError = error.localizedDescription }
    }

    private func createModifier(_ kind: String, _ input: String) {
        do { try store.createModifier(kind: kind, inputFeatureId: input) }
        catch { store.lastError = error.localizedDescription }
    }

    private func createProfileSketch(_ plane: String) {
        do { try store.createProfileSketch(plane: plane); isDrawingOpen = false; isSketchEditing = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createRevolve(_ sketchId: String, axis: SIMD3<Double>) {
        do { try store.createRevolve(sketchId: sketchId, axis: axis); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createSweep(_ sketchId: String, end: SIMD3<Double>) {
        do { try store.createSweep(sketchId: sketchId, end: end); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createVariableSweep(_ sketchId: String) {
        do { try store.createSweep(sketchId: sketchId, end: SIMD3(0, 0, 40), scaleStations: [CADSweepScaleStation(position: 0.5, scale: 1.6)]); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createHelixSweep(_ sketchId: String) {
        do { try store.createHelixSweep(sketchId: sketchId); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createSplineSweep(_ sketchId: String) {
        do { try store.createSplineSweep(sketchId: sketchId); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createRailSweep(_ sketchId: String) {
        let path = [SIMD3<Double>(0, 0, 0), SIMD3(0, 10, 12), SIMD3(10, 10, 26), SIMD3(14, 0, 40)]
        let rail = path.map { $0 + SIMD3<Double>(8, 0, 0) }
        do { try store.createSplineSweep(sketchId: sketchId, points: path, guidePoints: rail, startTangent: path[1] - path[0], endTangent: path[3] - path[2]); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createCompositeSweep(_ sketchId: String) {
        do { try store.createCompositeSweep(sketchId: sketchId); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func createAssemblyInstance(_ sourceId: String) {
        do { try store.createAssemblyInstance(sourceFeatureId: sourceId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createFixedMate(_ instanceId: String) {
        do { try store.createFixedMate(instanceId: instanceId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createCoincidentMate(_ referenceId: String, _ movingId: String) {
        do { try store.createCoincidentMate(referenceInstanceId: referenceId, movingInstanceId: movingId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createDistanceMate(_ referenceId: String, _ movingId: String) {
        do { try store.createDistanceMate(referenceInstanceId: referenceId, movingInstanceId: movingId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createPlaneMate(_ referenceId: String, _ movingId: String) {
        do { try store.createPlaneMate(referenceInstanceId: referenceId, movingInstanceId: movingId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createConcentricMate(_ referenceId: String, _ movingId: String) {
        do { try store.createConcentricMate(referenceInstanceId: referenceId, movingInstanceId: movingId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func createAngleMate(_ referenceId: String, _ movingId: String) {
        do { try store.createAngleMate(referenceInstanceId: referenceId, movingInstanceId: movingId); isAssemblyOpen = true }
        catch { store.lastError = error.localizedDescription }
    }

    private func exportDocument() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name).stl"
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { do { try store.exportSTL(to: url) } catch { store.lastError = error.localizedDescription } }
    }

    private func kernelFeatureId() -> String {
        guard let selected = store.selectedFeature else { return "pad-base" }
        return ["sketch", "pad", "pocket", "fillet"].contains(selected.kind) ? "pad-base" : selected.id
    }

    private func validateWithKernel() {
        guard !isKernelWorking else { return }
        let featureId = kernelFeatureId()
        isKernelWorking = true
        store.status = "Checking \(featureId) with the exact geometry engine…"
        Task {
            do {
                let validation = try await KernelService.validate(documentURL: store.documentURL, featureId: featureId)
                kernelValidation = validation
                store.status = validation.ok
                    ? "Solid geometry and closed mesh validated for \(validation.featureId)"
                    : "STEP geometry built; \(validation.boundaryEdgeSegments) mesh boundary edges need review"
            } catch {
                store.lastError = error.localizedDescription
                store.status = "Kernel validation did not complete"
            }
            isKernelWorking = false
        }
    }

    private func exportSTEP() {
        guard !isKernelWorking else { return }
        let featureId = kernelFeatureId()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name)-r\(store.document.revision).step"
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isKernelWorking = true
        store.status = "Building STEP with the exact geometry engine…"
        Task {
            do {
                let exported = try await KernelService.exportStep(documentURL: store.documentURL, featureId: featureId, to: url)
                store.status = "Exported \(exported.featureId) STEP · \(exported.byteCount) bytes"
                kernelValidation = try? await KernelService.validate(documentURL: store.documentURL, featureId: featureId)
            } catch {
                store.lastError = error.localizedDescription
                store.status = "STEP export did not complete"
            }
            isKernelWorking = false
        }
    }

    private func exportAssemblySTEP() {
        guard !isKernelWorking, !store.assemblyInstances.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name)-assembly-r\(store.document.revision).step"
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isKernelWorking = true
        store.status = "Building solved multi-body assembly STEP…"
        Task {
            do {
                let exported = try await KernelService.exportAssemblyStep(documentURL: store.documentURL, to: url)
                store.status = "Exported \(exported.bodyCount)-body assembly · reader round-trip passed · \(exported.byteCount) bytes"
            } catch {
                store.lastError = error.localizedDescription
                store.status = "Assembly STEP export did not complete"
            }
            isKernelWorking = false
        }
    }

    private func newDocument() {
        do { try store.checkpoint(label: "before-new-document"); try store.newDocument(); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.axisCADProject, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.checkpoint(label: "before-open-document"); try store.openDocument(from: url); isSketchEditing = false }
        catch { store.lastError = store.lastError ?? error.localizedDescription }
    }

    private func openExternalDocument(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.checkpoint(label: "before-open-external-document")
            try store.openDocument(from: url)
            isSketchEditing = false
            isDrawingOpen = false
            isAssemblyOpen = false
            kernelValidation = nil
            requestCamera(.fit)
        } catch {
            store.lastError = store.lastError ?? error.localizedDescription
        }
    }

    private func openRecent(_ path: String) {
        do { try store.checkpoint(label: "before-open-recent"); try store.openDocument(from: URL(fileURLWithPath: path)); isSketchEditing = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func restoreCheckpoint(_ checkpoint: CADCheckpointSummary) {
        do { try store.checkpoint(label: "before-restore"); try store.restoreCheckpoint(checkpoint); isSketchEditing = false; isDrawingOpen = false }
        catch { store.lastError = error.localizedDescription }
    }

    private func importSTEP() {
        guard !isKernelWorking else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data, UTType(filenameExtension: "stp") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isKernelWorking = true; store.status = "Inspecting STEP with the STEP reader…"
        Task {
            do { _ = try await store.importSTEP(from: url); requestCamera(.fit) }
            catch { store.lastError = error.localizedDescription; store.status = "STEP import did not complete" }
            isKernelWorking = false
        }
    }

    private func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name).axiscad"
        panel.allowedContentTypes = [.axisCADProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportJSON(to: url) } catch { store.lastError = error.localizedDescription }
    }

    private func saveDocument() {
        guard store.projectURL != nil else { saveDocumentAs(); return }
        do { try store.saveProject() } catch { store.lastError = error.localizedDescription }
    }

    private func exportDrawingPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name)-drawing.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DrawingPDFExporter.write(sheet: CADDrawingSheet.make(document: store.document), to: url)
            store.status = "Exported technical drawing: \(url.lastPathComponent)"
        } catch { store.lastError = error.localizedDescription }
    }

    private func exportDrawingDXF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.document.name)-drawing.dxf"
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DrawingDXFExporter.write(sheet: CADDrawingSheet.make(document: store.document), to: url)
            store.status = "Exported editable drawing: \(url.lastPathComponent)"
        } catch { store.lastError = error.localizedDescription }
    }
}

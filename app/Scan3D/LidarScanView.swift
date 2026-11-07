import SwiftUI
import ARKit
import RealityKit

/// Метод 3: LiDAR-сетка (ARKit scene reconstruction).
@MainActor
final class LidarModel: ObservableObject {
    enum Phase { case scanning, saving, done, failed }

    weak var arView: ARView?
    @Published var phase: Phase = .scanning
    @Published var triangles = 0
    @Published var errorText = ""
    @Published var record: ScanRecord

    private let store: ScanStore

    init(record: ScanRecord, store: ScanStore) {
        self.record = record
        self.store = store
    }

    func start() {
        guard let view = arView else { return }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorText = "Это устройство не поддерживает LiDAR-сетку."
            phase = .failed
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .none
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func restart() { start() }

    func stop() { arView?.session.pause() }

    private var meshAnchors: [ARMeshAnchor] {
        arView?.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    }

    func updateCount() {
        triangles = meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
    }

    func save() {
        let anchors = meshAnchors
        guard !anchors.isEmpty else {
            errorText = "Сетка ещё не построена. Поводите телефоном вокруг объекта."
            phase = .failed
            return
        }
        phase = .saving
        stop()
        let mesh = Self.mesh(from: anchors)
        let export = store.exportFolder(for: record)
        let baseName = record.folderName
        Task {
            do {
                try await Task.detached {
                    try MeshExport.writeAll(mesh, folder: export, baseName: baseName)
                }.value
                record.sizeMM = mesh.sizeMM
                record.triangles = mesh.triangleCount
                store.save(record)
                phase = .done
            } catch {
                errorText = "Не удалось сохранить: \(error.localizedDescription)"
                phase = .failed
            }
        }
    }

    static func mesh(from anchors: [ARMeshAnchor]) -> TriMesh {
        var out = TriMesh()
        for anchor in anchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let p = vBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                points.append(SIMD3<Float>(w.x, w.y, w.z))
            }

            let faces = geometry.faces
            let total = faces.count * faces.indexCountPerPrimitive
            let fBase = faces.buffer.contents()
            var idx: [UInt32] = []
            idx.reserveCapacity(total)
            if faces.bytesPerIndex == 4 {
                let p = fBase.assumingMemoryBound(to: UInt32.self)
                for k in 0..<total { idx.append(p[k]) }
            } else {
                let p = fBase.assumingMemoryBound(to: UInt16.self)
                for k in 0..<total { idx.append(UInt32(p[k])) }
            }
            out.append(points, idx)
        }
        return out
    }
}

private struct LidarARView: UIViewRepresentable {
    let model: LidarModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.debugOptions.insert(.showSceneUnderstanding)
        model.arView = view
        model.start()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct LidarScanView: View {
    @StateObject private var model: LidarModel
    let onClose: (Bool) -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(record: ScanRecord, store: ScanStore, onClose: @escaping (Bool) -> Void) {
        _model = StateObject(wrappedValue: LidarModel(record: record, store: store))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            LidarARView(model: model)
                .ignoresSafeArea()

            switch model.phase {
            case .scanning:
                overlay
            case .saving:
                ProgressView("Сохранение сетки…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .done:
                ResultPanel(
                    sizeMM: model.record.sizeMM,
                    triangles: model.record.triangles,
                    note: "Сохранены STL, OBJ, PLY (мм). Точность LiDAR-сетки около 1 см — для габаритов и привязки, не для точных размеров."
                ) { onClose(true) }
            case .failed:
                ErrorPanel(text: model.errorText) {
                    if model.triangles > 0 {
                        model.phase = .scanning
                    } else {
                        model.stop()
                        onClose(false)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            if model.phase == .scanning { model.updateCount() }
        }
        .onDisappear { model.stop() }
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button("Отмена") {
                    model.stop()
                    onClose(false)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Треугольников: \(model.triangles)")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding()

            Spacer()

            Text("Медленно ведите телефоном по объекту на расстоянии 0,5–3 м. Сетка закрашивает отсканированное.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

            HStack {
                Button("Заново") { model.restart() }
                    .buttonStyle(.bordered)
                Button("Сохранить") { model.save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 30)
        }
    }
}

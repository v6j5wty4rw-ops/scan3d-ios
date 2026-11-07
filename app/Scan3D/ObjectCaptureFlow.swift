import SwiftUI
import RealityKit

/// Методы 1 и 2: Object Capture (фотограмметрия на телефоне с LiDAR).
/// areaMode = true — режим области: съёмка без рамки вокруг предмета.
@MainActor
final class ObjectCaptureModel: ObservableObject {
    enum Phase { case capturing, reconstructing, done, failed }

    @Published var session: ObjectCaptureSession?
    @Published var state: ObjectCaptureSession.CaptureState = .initializing
    @Published var passCompleted = false
    @Published var phase: Phase = .capturing
    @Published var progress: Double = 0
    @Published var errorText = ""
    @Published var record: ScanRecord

    let areaMode: Bool
    private let store: ScanStore
    private let imagesDir: URL
    private let checkpointDir: URL
    private let exportDir: URL
    private var tasks: [Task<Void, Never>] = []

    init(record: ScanRecord, store: ScanStore, areaMode: Bool) {
        self.record = record
        self.store = store
        self.areaMode = areaMode
        imagesDir = store.imagesFolder(for: record)
        checkpointDir = store.checkpointFolder(for: record)
        exportDir = store.exportFolder(for: record)
    }

    func start() {
        guard session == nil, phase == .capturing else { return }
        guard ObjectCaptureSession.isSupported else {
            fail("Это устройство не поддерживает Object Capture (нужен LiDAR).")
            return
        }
        let s = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpointDir
        s.start(imagesDirectory: imagesDir, configuration: config)
        session = s

        tasks.append(Task { [weak self] in
            for await newState in s.stateUpdates {
                self?.handle(newState)
            }
        })
        tasks.append(Task { [weak self] in
            for await completed in s.userCompletedScanPassUpdates {
                self?.passCompleted = completed
            }
        })
    }

    private func handle(_ newState: ObjectCaptureSession.CaptureState) {
        state = newState
        switch newState {
        case .completed:
            session = nil
            reconstruct()
        case .failed(let error):
            session = nil
            fail("Съёмка прервана: \(error.localizedDescription)")
        default:
            break
        }
    }

    var hint: String {
        switch state {
        case .initializing: return "Подготовка камеры…"
        case .ready: return areaMode ? "Наведите камеру на область и нажмите «Начать съёмку»." : "Наведите камеру на деталь."
        case .detecting: return "Подгоните рамку под деталь."
        case .capturing:
            return passCompleted
                ? "Круг пройден. Снимите ещё круг выше/ниже, переверните деталь или завершите."
                : "Медленно обходите деталь по кругу, держите её в кадре."
        case .finishing: return "Сохранение снимков…"
        default: return ""
        }
    }

    var primaryTitle: String? {
        switch state {
        case .ready: return areaMode ? "Начать съёмку" : "Найти деталь"
        case .detecting: return "Начать съёмку"
        case .capturing: return "Завершить съёмку"
        default: return nil
        }
    }

    func primaryAction() {
        guard let s = session else { return }
        switch s.state {
        case .ready:
            if areaMode {
                s.startCapturing()
            } else {
                _ = s.startDetecting()
            }
        case .detecting:
            s.startCapturing()
        case .capturing:
            s.finish()
        default:
            break
        }
    }

    func resetBox() { session?.resetDetection() }
    func newPass() { session?.beginNewScanPass() }
    func newPassAfterFlip() { session?.beginNewScanPassAfterFlip() }

    func cancel() {
        session?.cancel()
        session = nil
        tasks.forEach { $0.cancel() }
    }

    private func fail(_ text: String) {
        errorText = text
        phase = .failed
    }

    private func reconstruct() {
        phase = .reconstructing
        let images = imagesDir
        let checkpoint = checkpointDir
        let export = exportDir
        let baseName = record.folderName
        let area = areaMode
        Task {
            do {
                var config = PhotogrammetrySession.Configuration()
                config.checkpointDirectory = checkpoint
                if area { config.isObjectMaskingEnabled = false }
                let ps = try PhotogrammetrySession(input: images, configuration: config)
                let usdz = export.appendingPathComponent(baseName + ".usdz")
                try ps.process(requests: [.modelFile(url: usdz)])

                outputs: for try await output in ps.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        progress = fraction
                    case .requestError(_, let error):
                        throw error
                    case .processingCancelled:
                        throw ScanError.message("Обработка отменена")
                    case .processingComplete:
                        break outputs
                    default:
                        break
                    }
                }

                let mesh = try await Task.detached { () throws -> TriMesh in
                    let m = try MeshExport.load(from: usdz)
                    try MeshExport.writeAll(m, folder: export, baseName: baseName)
                    return m
                }.value

                record.sizeMM = mesh.sizeMM
                record.triangles = mesh.triangleCount
                store.save(record)
                phase = .done
            } catch {
                fail("Не удалось собрать модель: \(error.localizedDescription)")
            }
        }
    }
}

struct ObjectCaptureFlowView: View {
    @StateObject private var model: ObjectCaptureModel
    let onClose: (Bool) -> Void

    init(record: ScanRecord, store: ScanStore, areaMode: Bool, onClose: @escaping (Bool) -> Void) {
        _model = StateObject(wrappedValue: ObjectCaptureModel(record: record, store: store, areaMode: areaMode))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = model.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            }

            switch model.phase {
            case .capturing:
                captureOverlay
            case .reconstructing:
                VStack(spacing: 16) {
                    ProgressView(value: model.progress)
                        .tint(.white)
                    Text("Сборка модели: \(Int(model.progress * 100))%")
                        .font(.headline)
                    Text("Не закрывайте приложение и не блокируйте экран.")
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .padding(32)
            case .done:
                ResultPanel(
                    sizeMM: model.record.sizeMM,
                    triangles: model.record.triangles,
                    note: "Сохранены файлы STL, OBJ, PLY (мм) и USDZ. Сверьте габариты с замером штангенциркулем."
                ) { onClose(true) }
            case .failed:
                ErrorPanel(text: model.errorText) {
                    model.cancel()
                    onClose(false)
                }
            }
        }
        .onAppear { model.start() }
    }

    private var captureOverlay: some View {
        VStack {
            HStack {
                Button("Отмена") {
                    model.cancel()
                    onClose(false)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(model.areaMode ? "Режим области" : "Режим предмета")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding()

            Spacer()

            Text(model.hint)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

            if case .capturing = model.state, model.passCompleted {
                HStack {
                    Button("Ещё круг") { model.newPass() }
                    Button("Перевернуть") { model.newPassAfterFlip() }
                }
                .buttonStyle(.bordered)
            }

            HStack {
                if case .detecting = model.state {
                    Button("Сбросить рамку") { model.resetBox() }
                        .buttonStyle(.bordered)
                }
                if let title = model.primaryTitle {
                    Button(title) { model.primaryAction() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 30)
        }
    }
}

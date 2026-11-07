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
    @Published var shots = 0
    @Published var maxShots = 0
    @Published var feedbackText: String?
    @Published var passNumber = 1

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
        session = s

        // Подписка до start(), чтобы не пропустить переход в .ready.
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
        s.start(imagesDirectory: imagesDir, configuration: config)

        // Страховка: опрос состояния сессии, если обновление всё же пропущено.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let current = self.session else { return }
                if String(describing: current.state) != String(describing: self.state) {
                    self.handle(current.state)
                }
                if current.userCompletedScanPass != self.passCompleted {
                    self.passCompleted = current.userCompletedScanPass
                }
                if current.numberOfShotsTaken != self.shots { self.shots = current.numberOfShotsTaken }
                if current.maximumNumberOfInputImages != self.maxShots { self.maxShots = current.maximumNumberOfInputImages }
                let fb = Self.describe(current.feedback.map { String(describing: $0) })
                if fb != self.feedbackText { self.feedbackText = fb }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        })
    }

    private func handle(_ newState: ObjectCaptureSession.CaptureState) {
        guard phase == .capturing else { return }
        if String(describing: newState) == String(describing: state), session != nil { return }
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

    /// Подсказки Object Capture → понятный текст.
    static func describe(_ items: [String]) -> String? {
        let map: [(String, String)] = [
            ("tooclose", "Слишком близко — отойдите немного"),
            ("toofar", "Слишком далеко — подойдите ближе"),
            ("fast", "Двигайтесь медленнее"),
            ("dark", "Мало света — добавьте освещение"),
            ("lowlight", "Мало света — добавьте освещение"),
            ("fieldofview", "Деталь вышла из кадра — верните её в центр"),
            ("notflippable", "Эту деталь лучше не переворачивать"),
            ("overcapturing", "Этот участок уже снят — двигайтесь дальше"),
            ("notdetected", "Деталь не видна — наведите точку на неё"),
        ]
        let texts = items.compactMap { item -> String? in
            let key = item.lowercased()
            return map.first { key.contains($0.0) }?.1
        }
        return texts.isEmpty ? nil : Array(Set(texts)).sorted().joined(separator: "\n")
    }

    var isDetecting: Bool { if case .detecting = state { return true } else { return false } }
    var isCapturing: Bool { if case .capturing = state { return true } else { return false } }

    func findObject() { _ = session?.startDetecting() }
    func startCapturing() { session?.startCapturing() }
    func buildModel() { session?.finish() }
    func resetBox() { session?.resetDetection() }

    func newPass() {
        session?.beginNewScanPass()
        passNumber += 1
        passCompleted = false
    }

    func newPassAfterFlip() {
        session?.beginNewScanPassAfterFlip()
        passNumber += 1
        passCompleted = false
    }

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

            stepCard
        }
    }

    private var totalSteps: Int { model.areaMode ? 2 : 3 }

    private var shotsText: String {
        model.maxShots > 0 ? "Снято: \(model.shots) из \(model.maxShots)" : "Снято: \(model.shots)"
    }

    @ViewBuilder
    private var stepCard: some View {
        switch model.state {
        case .initializing:
            StepCard(step: "Подготовка", title: "Запуск камеры", text: "Подождите пару секунд…") { EmptyView() }

        case .ready:
            if model.areaMode {
                StepCard(
                    step: "Шаг 1 из 2",
                    title: "Наведите на объект",
                    text: "Объект — в центре экрана. Когда будете готовы, нажмите кнопку и начинайте медленно двигаться вдоль него."
                ) {
                    WideButton(title: "Начать съёмку") { model.startCapturing() }
                }
            } else {
                StepCard(
                    step: "Шаг 1 из 3",
                    title: "Найдите деталь",
                    text: "Наведите точку в центре экрана на деталь с расстояния 30–60 см, чтобы деталь была в кадре целиком.",
                    warning: model.feedbackText
                ) {
                    WideButton(title: "Найти деталь") { model.findObject() }
                }
            }

        case .detecting:
            StepCard(
                step: "Шаг 2 из 3",
                title: "Проверьте рамку",
                text: "Рамка должна охватывать деталь целиком, без лишнего вокруг. Если не совпадает — потяните пальцем за её края.",
                warning: model.feedbackText
            ) {
                WideButton(title: "Рамка верна — начать съёмку") { model.startCapturing() }
                WideButton(title: "Найти заново", prominent: false) { model.resetBox() }
            }

        case .capturing:
            if model.passCompleted {
                StepCard(
                    step: "Шаг \(totalSteps) из \(totalSteps) · круг \(model.passNumber)",
                    title: "Круг \(model.passNumber) готов",
                    text: "Для полной модели лучше 3 круга: на уровне детали, выше (сверху вниз) и после переворота детали. \(shotsText)."
                ) {
                    WideButton(title: "Ещё круг — выше или ниже", prominent: false) { model.newPass() }
                    if !model.areaMode {
                        WideButton(title: "Перевернуть деталь и снять низ", prominent: false) { model.newPassAfterFlip() }
                    }
                    WideButton(title: "Хватит — собрать модель") { model.buildModel() }
                }
            } else {
                StepCard(
                    step: "Шаг \(totalSteps) из \(totalSteps) · круг \(model.passNumber)",
                    title: model.areaMode ? "Двигайтесь вдоль объекта" : "Обходите деталь по кругу",
                    text: model.areaMode
                        ? "Медленно ведите камерой, снимая объект с разных сторон. Снимки делаются сами. \(shotsText)."
                        : "Медленно идите вокруг детали, держа её в центре. Снимки делаются сами, белые штрихи показывают снятые стороны. \(shotsText).",
                    warning: model.feedbackText
                ) {
                    WideButton(title: "Собрать модель сейчас", prominent: false) { model.buildModel() }
                }
            }

        case .finishing:
            StepCard(step: "Почти готово", title: "Сохранение снимков…", text: "Не закрывайте приложение.") { EmptyView() }

        default:
            EmptyView()
        }
    }
}

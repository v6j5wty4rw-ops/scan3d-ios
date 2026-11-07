import SwiftUI
import AVFoundation

/// Метод 4: серия фото в полном разрешении для сборки модели на ПК.
final class PhotoCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var count = 0
    @Published var errorText: String?
    @Published var highRes = false
    @Published var resolutionText = ""

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "scan3d.camera")
    private var dimensions: [CMVideoDimensions] = []
    private var configured = false
    private let folder: URL
    private let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    init(folder: URL) {
        self.folder = folder
        super.init()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        count = existing.filter { $0.lowercased().hasSuffix(".jpg") }.count
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.errorText = "Нет доступа к камере. Разрешите в Настройках." }
                return
            }
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private static func area(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorText = "Не удалось открыть камеру." }
            return
        }
        session.addInput(input)
        session.addOutput(output)
        dimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dimensions.max(by: { Self.area($0) < Self.area($1) }) {
            output.maxPhotoDimensions = largest
        }
        output.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
        configured = true
        let text = describe(target(highRes: false))
        DispatchQueue.main.async { self.resolutionText = text }
    }

    private func target(highRes: Bool) -> CMVideoDimensions {
        let maxDims = output.maxPhotoDimensions
        if highRes { return maxDims }
        let normal = dimensions.filter { Self.area($0) <= 13_000_000 }
        return normal.max(by: { Self.area($0) < Self.area($1) }) ?? maxDims
    }

    private func describe(_ d: CMVideoDimensions) -> String {
        let mp = Double(Self.area(d)) / 1_000_000
        return String(format: "%d×%d (%.0f Мп)", d.width, d.height, mp)
    }

    func setHighRes(_ value: Bool) {
        highRes = value
        queue.async {
            let text = self.describe(self.target(highRes: value))
            DispatchQueue.main.async { self.resolutionText = text }
        }
    }

    func shoot() {
        let wantHigh = highRes
        queue.async {
            guard self.configured else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.target(highRes: wantHigh)
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.errorText = error.localizedDescription }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let url = folder.appendingPathComponent("IMG_\(nameFormatter.string(from: Date())).jpg")
        do {
            try data.write(to: url, options: .atomic)
            DispatchQueue.main.async { self.count += 1 }
        } catch {
            DispatchQueue.main.async { self.errorText = error.localizedDescription }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct PhotoCaptureView: View {
    @StateObject private var camera: PhotoCamera
    @State private var autoMode = false
    @State private var flash = false
    @State private var finishing = false
    @State private var done = false
    let record: ScanRecord
    let store: ScanStore
    let onClose: (Bool) -> Void

    private let autoTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(record: ScanRecord, store: ScanStore, onClose: @escaping (Bool) -> Void) {
        _camera = StateObject(wrappedValue: PhotoCamera(folder: store.imagesFolder(for: record)))
        self.record = record
        self.store = store
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
            Color.white.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)

            if done {
                ResultPanel(
                    sizeMM: nil,
                    triangles: nil,
                    note: "Снято фото: \(camera.count). ZIP для ПК — в карточке скана. Масштаб задаётся на ПК по линейке в кадре."
                ) { onClose(true) }
            } else {
                overlay
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onReceive(autoTimer) { _ in
            if autoMode && !done { take() }
        }
    }

    private func take() {
        camera.shoot()
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { flash = false }
    }

    private func finish() {
        guard camera.count > 0 else {
            onClose(false)
            return
        }
        finishing = true
        autoMode = false
        camera.stop()
        var updated = record
        updated.photoCount = camera.count
        store.save(updated)
        done = true
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button("Отмена") {
                    camera.stop()
                    onClose(false)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Фото: \(camera.count)")
                    .font(.headline)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding()

            Spacer()

            VStack(spacing: 6) {
                Text("Снимайте с перекрытием 60–80 %, обходя объект. Положите в кадр линейку или рулетку.")
                    .multilineTextAlignment(.center)
                Text("Разрешение: \(camera.resolutionText)").font(.caption)
                if let e = camera.errorText {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            HStack(spacing: 16) {
                Toggle("48 Мп", isOn: Binding(get: { camera.highRes }, set: { camera.setHighRes($0) }))
                    .toggleStyle(.button)
                Toggle("Авто 2 с", isOn: $autoMode)
                    .toggleStyle(.button)
            }
            .padding(.top, 8)

            HStack(spacing: 30) {
                Button {
                    take()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white.opacity(0.3)))
                        .frame(width: 76, height: 76)
                }
                Button("Готово") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(finishing)
            }
            .padding(.vertical, 24)
        }
    }
}

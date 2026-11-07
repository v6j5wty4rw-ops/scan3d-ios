import Foundation

enum ScanError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Метод сканирования (выбирается пользователем при новом скане).
enum ScanMethod: String, Codable, CaseIterable, Identifiable {
    case object, area, lidar, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: return "Предмет — фотограмметрия"
        case .area: return "Область — фотограмметрия"
        case .lidar: return "LiDAR-сетка"
        case .photos: return "Фото для ПК"
        }
    }

    var hint: String {
        switch self {
        case .object:
            return "Мелкие и средние детали. Обход детали по кругу, модель собирается на телефоне."
        case .area:
            return "Крупные детали и узлы на месте, когда обойти со всех сторон нельзя. Экспериментальный режим."
        case .lidar:
            return "Крупное оборудование и помещения. Быстро, но грубо (около 1 см)."
        case .photos:
            return "Крупные объекты с высокой точностью. Серия фото, модель собирается на ПК (Meshroom / COLMAP). Положите в кадр линейку для масштаба."
        }
    }

    var accuracy: String {
        switch self {
        case .object: return "Точность: высокая"
        case .area: return "Точность: средняя"
        case .lidar: return "Точность: низкая"
        case .photos: return "Точность: высокая (на ПК)"
        }
    }

    var icon: String {
        switch self {
        case .object: return "cube.transparent"
        case .area: return "viewfinder"
        case .lidar: return "square.grid.3x3"
        case .photos: return "camera"
        }
    }
}

struct ScanRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var folderName: String
    var date: Date
    var method: ScanMethod
    /// Габариты модели в мм (X, Y, Z).
    var sizeMM: [Float]?
    var triangles: Int?
    var photoCount: Int?
}

/// Хранилище сканов: Documents/Scans/<folderName>/ (видно в приложении «Файлы»).
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for record: ScanRecord) -> URL {
        root.appendingPathComponent(record.folderName, isDirectory: true)
    }

    func subfolder(_ name: String, for record: ScanRecord) -> URL {
        let url = folder(for: record).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func imagesFolder(for record: ScanRecord) -> URL { subfolder("Images", for: record) }
    func checkpointFolder(for record: ScanRecord) -> URL { subfolder("Checkpoint", for: record) }
    func exportFolder(for record: ScanRecord) -> URL { subfolder("Export", for: record) }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scans = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")) else { return nil }
            return try? decoder.decode(ScanRecord.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    func create(method: ScanMethod) -> ScanRecord {
        let now = Date()
        let file = DateFormatter()
        file.dateFormat = "yyyyMMdd_HHmmss"
        let display = DateFormatter()
        display.dateFormat = "dd.MM.yyyy HH:mm"
        let record = ScanRecord(
            name: "Скан \(display.string(from: now))",
            folderName: "scan_\(file.string(from: now))",
            date: now,
            method: method
        )
        try? FileManager.default.createDirectory(at: folder(for: record), withIntermediateDirectories: true)
        save(record)
        return record
    }

    func save(_ record: ScanRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(record) {
            try? data.write(to: folder(for: record).appendingPathComponent("record.json"), options: .atomic)
        }
        reload()
    }

    func delete(_ record: ScanRecord) {
        try? FileManager.default.removeItem(at: folder(for: record))
        reload()
    }

    /// Готовые файлы для передачи (STL, OBJ, PLY, USDZ, ZIP).
    func exportFiles(for record: ScanRecord) -> [URL] {
        let dir = folder(for: record).appendingPathComponent("Export", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Упаковка папки в ZIP средствами системы.
    nonisolated static func zip(folder: URL, to destination: URL) throws {
        var coordError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                innerError = error
            }
        }
        if let error = coordError ?? innerError { throw error }
    }
}

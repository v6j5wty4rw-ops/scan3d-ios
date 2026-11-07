import SwiftUI
import QuickLook

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    let record: ScanRecord

    @State private var files: [URL] = []
    @State private var preview: URL?
    @State private var zipping = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section("Скан") {
                LabeledContent("Метод", value: record.method.title)
                LabeledContent("Дата", value: record.date.formatted(date: .numeric, time: .shortened))
                if let s = record.sizeMM, s.count == 3 {
                    LabeledContent("Габариты", value: formatSize(s))
                }
                if let t = record.triangles {
                    LabeledContent("Треугольников", value: "\(t)")
                }
                if let p = record.photoCount {
                    LabeledContent("Фото", value: "\(p)")
                }
            }

            if record.method == .photos {
                Section {
                    Button {
                        makeZip()
                    } label: {
                        if zipping {
                            ProgressView()
                        } else {
                            Label("Собрать ZIP с фото для ПК", systemImage: "doc.zipper")
                        }
                    }
                    .disabled(zipping)
                } footer: {
                    Text("На ПК модель собирается в Meshroom или COLMAP. Масштаб задаётся по линейке в кадре.")
                }
            }

            Section {
                if files.isEmpty {
                    Text("Файлов пока нет").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                            Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if url.pathExtension.lowercased() == "usdz" {
                            Button {
                                preview = url
                            } label: {
                                Image(systemName: "cube")
                            }
                            .buttonStyle(.borderless)
                        }
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Файлы (единицы — мм)")
            } footer: {
                Text("Файлы также доступны в приложении «Файлы»: На iPhone → 3D Сканер → Scans → \(record.folderName) → Export.")
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        files = store.exportFiles(for: record)
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func makeZip() {
        zipping = true
        errorText = nil
        let images = store.imagesFolder(for: record)
        let dest = store.exportFolder(for: record).appendingPathComponent(record.folderName + "_photos.zip")
        Task {
            do {
                try await Task.detached {
                    try ScanStore.zip(folder: images, to: dest)
                }.value
            } catch {
                errorText = error.localizedDescription
            }
            zipping = false
            refresh()
        }
    }
}

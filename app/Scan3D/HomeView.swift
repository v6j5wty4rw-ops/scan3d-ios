import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var showPicker = false
    @State private var pendingMethod: ScanMethod?
    @State private var active: ScanRecord?

    var body: some View {
        NavigationStack {
            Group {
                if store.scans.isEmpty {
                    ContentUnavailableView(
                        "Сканов пока нет",
                        systemImage: "cube.transparent",
                        description: Text("Нажмите «Новый скан» и выберите метод.")
                    )
                } else {
                    List {
                        ForEach(store.scans) { record in
                            NavigationLink(value: record) {
                                ScanRow(record: record)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { store.delete(store.scans[i]) }
                        }
                    }
                }
            }
            .navigationTitle("3D-сканер")
            .navigationDestination(for: ScanRecord.self) { record in
                ScanDetailView(record: record)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showPicker = true
                } label: {
                    Label("Новый скан", systemImage: "plus.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .sheet(isPresented: $showPicker, onDismiss: {
                if let method = pendingMethod {
                    pendingMethod = nil
                    active = store.create(method: method)
                }
            }) {
                MethodPickerView { method in
                    pendingMethod = method
                    showPicker = false
                }
            }
            .fullScreenCover(item: $active) { record in
                CaptureContainer(record: record, store: store) { completed in
                    if !completed { store.delete(record) }
                    active = nil
                    store.reload()
                }
            }
        }
    }
}

private struct ScanRow: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.method.icon)
                .font(.title2)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.headline)
                Text(record.method.title).font(.subheadline).foregroundStyle(.secondary)
                if let s = record.sizeMM, s.count == 3 {
                    Text(formatSize(s)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

func formatSize(_ s: [Float]) -> String {
    String(format: "%.1f × %.1f × %.1f мм", s[0], s[1], s[2])
}

struct MethodPickerView: View {
    let onSelect: (ScanMethod) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ScanMethod.allCases) { method in
                Button {
                    onSelect(method)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: method.icon)
                            .font(.title2)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(method.title).font(.headline)
                            Text(method.hint).font(.subheadline).foregroundStyle(.secondary)
                            Text(method.accuracy).font(.caption).foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tint(.primary)
            }
            .navigationTitle("Метод сканирования")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}

/// Открывает экран съёмки под выбранный метод.
/// onClose(true) — скан сохранён, onClose(false) — отменён (папка удаляется).
struct CaptureContainer: View {
    let record: ScanRecord
    let store: ScanStore
    let onClose: (Bool) -> Void
    @State private var guideShown = false

    var body: some View {
        if !guideShown {
            MethodGuideView(method: record.method, onStart: { guideShown = true }, onCancel: { onClose(false) })
        } else {
            captureView
        }
    }

    @ViewBuilder
    private var captureView: some View {
        switch record.method {
        case .object:
            ObjectCaptureFlowView(record: record, store: store, areaMode: false, onClose: onClose)
        case .area:
            ObjectCaptureFlowView(record: record, store: store, areaMode: true, onClose: onClose)
        case .lidar:
            LidarScanView(record: record, store: store, onClose: onClose)
        case .photos:
            PhotoCaptureView(record: record, store: store, onClose: onClose)
        }
    }
}

/// Итог сканирования: габариты и кнопка «Готово».
struct ResultPanel: View {
    let sizeMM: [Float]?
    let triangles: Int?
    let note: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Готово").font(.title2.bold())
            if let s = sizeMM, s.count == 3 {
                Text("Габариты: \(formatSize(s))").font(.headline)
            }
            if let t = triangles {
                Text("Треугольников: \(t)").foregroundStyle(.secondary)
            }
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Готово", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}

struct ErrorPanel: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Ошибка").font(.title2.bold())
            Text(text).multilineTextAlignment(.center)
            Button("Закрыть", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}

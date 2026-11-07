import SwiftUI

/// Экран-инструкция перед съёмкой: подготовка и порядок действий для выбранного метода.
struct MethodGuideView: View {
    let method: ScanMethod
    let onStart: () -> Void
    let onCancel: () -> Void

    private struct Item: Hashable {
        let icon: String
        let text: String
    }

    private var prepare: [Item] {
        switch method {
        case .object:
            return [
                Item(icon: "sun.max", text: "Ровный рассеянный свет, без резких теней и бликов."),
                Item(icon: "square.fill", text: "Матовый фон, контрастный к детали. Глянцевую подставку не использовать."),
                Item(icon: "sparkles", text: "Блестящую деталь покройте матовым спреем — иначе модель получится с дырами."),
                Item(icon: "arrow.up.and.down.and.arrow.left.and.right", text: "Вокруг детали нужно свободно обойти. Сама деталь не двигается."),
            ]
        case .area:
            return [
                Item(icon: "sun.max", text: "Ровный свет, без резких теней."),
                Item(icon: "sparkles", text: "Блестящие места — матовым спреем."),
                Item(icon: "viewfinder", text: "Рамки нет: снимается всё, что в кадре. Держите объект в центре."),
            ]
        case .lidar:
            return [
                Item(icon: "ruler", text: "Расстояние до объекта 0,5–3 м."),
                Item(icon: "exclamationmark.triangle", text: "Точность около 1 см: для габаритов и привязки, не для точных размеров."),
            ]
        case .photos:
            return [
                Item(icon: "ruler", text: "Положите в кадр линейку или рулетку — по ней на ПК задаётся масштаб."),
                Item(icon: "sun.max", text: "Ровный свет, без вспышки. Блестящее — матовым спреем."),
                Item(icon: "photo.stack", text: "Нужно 50–200 фото с перекрытием 60–80 % между соседними."),
            ]
        }
    }

    private var steps: [String] {
        switch method {
        case .object:
            return [
                "Наведите камеру на деталь, нажмите «Найти деталь».",
                "Появится рамка. Если она не совпадает с деталью — потяните за её края, затем «Начать съёмку».",
                "Медленно обходите деталь по кругу, держа её в центре. Снимки делаются сами. Белые штрихи вокруг детали показывают, какие стороны уже сняты.",
                "Когда круг замкнётся, приложение предложит второй круг (выше, сверху вниз) или перевернуть деталь, чтобы снять низ. Лучше всего 3 круга.",
                "Нажмите «Собрать модель». Сборка идёт на телефоне 3–10 минут, экран не блокировать.",
            ]
        case .area:
            return [
                "Наведите камеру на объект, нажмите «Начать съёмку».",
                "Медленно ведите камерой вдоль объекта, снимая его с разных сторон и высот. Снимки делаются сами.",
                "Нажмите «Собрать модель». Сборка идёт на телефоне, экран не блокировать.",
            ]
        case .lidar:
            return [
                "Медленно ведите телефоном по объекту. Отсканированное покрывается сеткой.",
                "Пройдите все стороны, пока объект не покроется сеткой целиком.",
                "Нажмите «Сохранить». «Заново» — начать сначала.",
            ]
        case .photos:
            return [
                "Обходите объект по кругу, делая снимок каждые 10–15° (24–36 снимков на круг).",
                "Сделайте 2–3 круга на разной высоте. Можно включить «Авто» — снимок каждые 2 с.",
                "Нажмите «Готово». В карточке скана соберите ZIP и перенесите на ПК.",
            ]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: method.icon).font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(method.title).font(.title3.bold())
                            Text(method.accuracy).font(.subheadline).foregroundStyle(.blue)
                        }
                    }

                    Text("Подготовка").font(.headline)
                    ForEach(prepare, id: \.self) { item in
                        Label {
                            Text(item.text)
                        } icon: {
                            Image(systemName: item.icon).foregroundStyle(.orange)
                        }
                    }

                    Text("Как снимать").font(.headline)
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.headline)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(.blue.opacity(0.2)))
                            Text(text)
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onStart) {
                    Text("Понятно, начать")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Перед съёмкой")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: onCancel)
                }
            }
        }
    }
}

/// Нижняя карточка на экране съёмки: шаг, пояснение, кнопки.
struct StepCard<Buttons: View>: View {
    let step: String
    let title: String
    let text: String
    var warning: String? = nil
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step).font(.caption.bold()).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(text).font(.subheadline)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 8) {
                buttons()
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 12)
    }
}

/// Большая кнопка на всю ширину.
struct WideButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(action: action) {
                Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
    }
}

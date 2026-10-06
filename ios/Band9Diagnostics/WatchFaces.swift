import SwiftUI

private let faceCardColor = Color(red: 0.11, green: 0.11, blue: 0.12)

struct WatchFacePreview: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                RoundedRectangle(cornerRadius: width * 0.36, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.07), Color(white: 0.22)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: width * 0.335, style: .continuous)
                    .fill(.black)
                    .padding(width * 0.035)
                faceContent
                    .frame(width: 150, height: 270)
                    .scaleEffect(min((width - 16) / 150, (height - 20) / 270))
                RoundedRectangle(cornerRadius: width * 0.35, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
            }
            .clipShape(RoundedRectangle(cornerRadius: width * 0.36, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 7)
        }
        .aspectRatio(0.57, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(face.title)，\(face.palette.title)，本机预览")
    }

    @ViewBuilder private var faceContent: some View {
        switch face.kind {
        case .digital: DigitalFace(face: face, date: date, steps: steps, battery: battery)
        case .split: SplitFace(face: face, date: date, steps: steps, battery: battery)
        case .analog: AnalogFace(face: face, date: date, steps: steps, battery: battery)
        case .solar: SolarFace(face: face, date: date, steps: steps, battery: battery)
        case .modular: ModularFace(face: face, date: date, steps: steps, battery: battery)
        case .activity: ActivityFace(face: face, date: date, steps: steps, battery: battery)
        }
    }
}

private struct FaceClock {
    let date: Date
    var hour: Int { Calendar.current.component(.hour, from: date) }
    var minute: Int { Calendar.current.component(.minute, from: date) }
    var second: Int { Calendar.current.component(.second, from: date) }
    var hourText: String { String(format: "%02d", hour) }
    var minuteText: String { String(format: "%02d", minute) }
    var timeText: String { "\(hourText):\(minuteText)" }
    var dateText: String { date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) }
    var weekday: String { date.formatted(.dateTime.weekday(.wide)) }
}

private struct FaceComplication: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?

    private var icon: String {
        switch face.complication {
        case .date: return "calendar"
        case .steps: return "figure.walk"
        case .battery: return "battery.100percent"
        }
    }
    private var text: String {
        switch face.complication {
        case .date: return FaceClock(date: date).dateText
        case .steps: return steps.map { $0.formatted() } ?? "—"
        case .battery: return battery.map { "\($0)%" } ?? "—"
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold, design: face.style.fontDesign))
        .foregroundStyle(face.palette.color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct DigitalFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    var body: some View {
        let clock = FaceClock(date: date)
        VStack(spacing: -12) {
            Text(clock.weekday).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 20)
            Text(clock.hourText).foregroundStyle(face.palette.color)
            Text(clock.minuteText).foregroundStyle(.white)
            FaceComplication(face: face, date: date, steps: steps, battery: battery)
                .padding(.top, 27)
        }
        .font(.system(size: 77, weight: face.style == .rounded ? .bold : .black, design: face.style.fontDesign))
        .monospacedDigit()
    }
}

private struct SplitFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    var body: some View {
        let clock = FaceClock(date: date)
        ZStack {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 30).fill(face.palette.color)
                RoundedRectangle(cornerRadius: 30).fill(face.palette.color.opacity(0.20))
            }
            VStack(spacing: 0) {
                Text(clock.hourText).foregroundStyle(.black)
                    .frame(maxHeight: .infinity)
                Text(clock.minuteText).foregroundStyle(face.palette.color)
                    .frame(maxHeight: .infinity)
            }
            .font(.system(size: 76, weight: .black, design: face.style.fontDesign))
            .monospacedDigit()
            FaceComplication(face: face, date: date, steps: steps, battery: battery)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(.black, in: Capsule())
        }
        .padding(.vertical, 4)
    }
}

private struct AnalogFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    var body: some View {
        let clock = FaceClock(date: date)
        VStack(spacing: 24) {
            Text(clock.weekday).font(.system(size: 11, weight: .medium)).foregroundStyle(face.palette.color)
            ZStack {
                ForEach(0..<60, id: \.self) { tick in
                    Capsule().fill(tick.isMultiple(of: 5) ? .white.opacity(0.85) : .white.opacity(0.3))
                        .frame(width: tick.isMultiple(of: 5) ? 2 : 1, height: tick.isMultiple(of: 5) ? 9 : 4)
                        .offset(y: -65).rotationEffect(.degrees(Double(tick) * 6))
                }
                Text("12").offset(y: -44)
                Text("6").offset(y: 44)
                Text("3").offset(x: 46)
                Text("9").offset(x: -46)
                hand(length: 35, width: face.style == .rounded ? 5 : 3, color: .white,
                     degrees: Double(clock.hour % 12) * 30 + Double(clock.minute) * 0.5)
                hand(length: 51, width: 3, color: .white,
                     degrees: Double(clock.minute) * 6 + Double(clock.second) * 0.1)
                hand(length: 53, width: 1, color: face.palette.color, degrees: Double(clock.second) * 6)
                Circle().fill(face.palette.color).frame(width: 7, height: 7)
            }
            .font(.system(size: 13, weight: .semibold, design: face.style.fontDesign))
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            FaceComplication(face: face, date: date, steps: steps, battery: battery)
        }
    }
    private func hand(length: CGFloat, width: CGFloat, color: Color, degrees: Double) -> some View {
        Capsule().fill(color).frame(width: width, height: length)
            .offset(y: -length / 2 + 4).rotationEffect(.degrees(degrees))
    }
}

private struct SolarFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    var body: some View {
        let clock = FaceClock(date: date)
        ZStack {
            LinearGradient(colors: [face.palette.color.opacity(0.08), face.palette.color.opacity(0.7), .black],
                           startPoint: .top, endPoint: .bottom)
            ForEach(0..<5, id: \.self) { index in
                Ellipse().stroke(face.palette.color.opacity(0.55 - Double(index) * 0.07), lineWidth: 1)
                    .frame(width: CGFloat(90 + index * 28), height: CGFloat(150 + index * 32))
                    .offset(y: 60)
            }
            Circle().fill(face.palette.color).frame(width: 21, height: 21).offset(x: -40, y: 41)
                .shadow(color: face.palette.color.opacity(0.5), radius: 20)
            VStack(spacing: 8) {
                Text(clock.dateText).font(.system(size: 13, weight: .semibold))
                Text(clock.timeText).font(.system(size: 42, weight: .medium, design: face.style.fontDesign))
                    .monospacedDigit().minimumScaleFactor(0.8)
                Spacer()
                FaceComplication(face: face, date: date, steps: steps, battery: battery)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 38)
        }
        .clipShape(RoundedRectangle(cornerRadius: 35))
    }
}

private struct ModularFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    var body: some View {
        let clock = FaceClock(date: date)
        VStack(alignment: .leading, spacing: 13) {
            FaceComplication(face: face, date: date, steps: steps, battery: battery)
            Text(clock.timeText)
                .font(.system(size: 38, weight: .bold, design: face.style.fontDesign))
                .monospacedDigit().foregroundStyle(.white).minimumScaleFactor(0.8)
            Rectangle().fill(face.palette.color.opacity(0.7)).frame(height: 1)
            module(icon: "figure.walk", caption: "步数", value: steps.map { $0.formatted() } ?? "—")
            module(icon: "battery.100percent", caption: "电量", value: battery.map { "\($0)%" } ?? "—")
        }
        .padding(.horizontal, 13)
    }
    private func module(icon: String, caption: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(face.palette.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption).font(.system(size: 9)).foregroundStyle(.gray)
                Text(value).font(.system(size: 18, weight: .semibold, design: face.style.fontDesign))
                    .monospacedDigit().foregroundStyle(.white)
            }
        }
    }
}

private struct ActivityFace: View {
    let face: WatchFaceDesign
    let date: Date
    let steps: Int?
    let battery: Int?
    @AppStorage("watch.stepGoal") private var stepGoal = 8000
    private var progress: CGFloat { min(1, max(0, CGFloat(steps ?? 0) / CGFloat(max(stepGoal, 1)))) }
    var body: some View {
        VStack(spacing: 18) {
            Text(FaceClock(date: date).timeText)
                .font(.system(size: 31, weight: .bold, design: face.style.fontDesign))
                .monospacedDigit().foregroundStyle(.white)
            ZStack {
                Circle().stroke(face.palette.color.opacity(0.15), lineWidth: 12)
                Circle().trim(from: 0, to: progress)
                    .stroke(face.palette.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Image(systemName: "figure.walk").font(.system(size: 21)).foregroundStyle(face.palette.color)
                    Text(steps.map { $0.formatted() } ?? "—")
                        .font(.system(size: 22, weight: .bold, design: face.style.fontDesign))
                        .foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
                }
            }.frame(width: 112, height: 112)
            FaceComplication(face: face, date: date, steps: steps, battery: battery)
        }
    }
}

struct FaceGalleryView: View {
    @ObservedObject var library: FaceLibrary
    @ObservedObject var model: BluetoothModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    intro
                    gallerySection("色彩与数字", subtitle: "用鲜明的色彩，换一种看时间的方式。", kinds: [.digital, .split])
                    gallerySection("从容时刻", subtitle: "指针与光影之间，找到自己的节奏。", kinds: [.analog, .solar])
                    gallerySection("让信息一目了然", subtitle: "把同步的真实数据放到眼前。", kinds: [.modular, .activity])
                }
                .padding(.vertical, 16)
            }
            .background(.black)
            .navigationTitle("表盘图库")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(.orange)
        .preferredColorScheme(.dark)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一眼，就是你的风格。")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("六款原创设计，自由搭配颜色和信息。")
                .font(.subheadline).foregroundStyle(.secondary)
            Label("本机预览 · 尚不支持发送到手环", systemImage: "iphone")
                .font(.caption).foregroundStyle(.orange)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
    }

    private func gallerySection(_ title: String, subtitle: String, kinds: [WatchFaceKind]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 13) {
                    ForEach(WatchFaceDesign.catalog.filter { kinds.contains($0.kind) }) { face in
                        NavigationLink {
                            WatchFaceDetailView(face: face, library: library, model: model)
                        } label: {
                            FaceGalleryCard(face: face, model: model)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
}

private struct FaceGalleryCard: View {
    let face: WatchFaceDesign
    @ObservedObject var model: BluetoothModel
    @ObservedObject private var archive: HealthArchive

    init(face: WatchFaceDesign, model: BluetoothModel) {
        self.face = face
        self.model = model
        self.archive = model.archive
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            WatchFacePreview(face: face, date: Date(),
                             steps: archive.steps(on: Date(), device: model.currentDeviceID).map { Int($0) },
                             battery: model.batteryLevel)
                .frame(width: 110, height: 193)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(faceCardColor, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 3) {
                Text(face.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(face.palette.title).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: 174)
    }
}

struct SavedFacesRow: View {
    @ObservedObject var library: FaceLibrary
    @ObservedObject var model: BluetoothModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("我的表盘").font(.title2.bold())
                Spacer()
                Text("本机预览").font(.caption).foregroundStyle(.secondary)
            }
            if library.faces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("收藏你喜欢的设计", systemImage: "rectangle.stack")
                        .font(.headline)
                    Text("前往“表盘图库”搭配颜色，收藏后会显示在这里。预览暂不能发送到手环。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(faceCardColor, in: RoundedRectangle(cornerRadius: 18))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(library.faces) { face in
                            NavigationLink {
                                WatchFaceDetailView(face: face, library: library, model: model)
                            } label: {
                                FaceGalleryCard(face: face, model: model)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct WatchFaceDetailView: View {
    @ObservedObject var library: FaceLibrary
    @ObservedObject var model: BluetoothModel
    @ObservedObject private var archive: HealthArchive
    @State private var draft: WatchFaceDesign
    @State private var savedMessage = false
    @State private var showingRemoval = false
    @AppStorage("watch.stepGoal") private var stepGoal = 8000
    @Environment(\.dismiss) private var dismiss

    init(face: WatchFaceDesign, library: FaceLibrary, model: BluetoothModel) {
        self.library = library
        self.model = model
        self.archive = model.archive
        self._draft = State(initialValue: face)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                preview
                description
                colorPicker
                stylePicker
                complicationPicker
                saveButton
                if library.contains(draft.id) {
                    Button("移除收藏", role: .destructive) { showingRemoval = true }
                        .frame(maxWidth: .infinity).padding(.bottom, 10)
                }
            }.padding(20)
        }
        .background(.black)
        .navigationTitle(draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(.orange)
        .preferredColorScheme(.dark)
        .confirmationDialog("移除这个本机预览？", isPresented: $showingRemoval, titleVisibility: .visible) {
            Button("移除收藏", role: .destructive) {
                library.remove(draft.id)
                dismiss()
            }
        }
        .alert("已收藏本机预览", isPresented: $savedMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text("可在“我的手表”的表盘收藏中找到它。手环上的表盘未更改。")
        }
    }

    private var preview: some View {
        let sampleDay = Date()
        let steps = archive.steps(on: sampleDay, device: model.currentDeviceID).map { Int($0) }
        let battery = model.batteryLevel
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            WatchFacePreview(face: draft, date: context.date,
                             steps: Calendar.current.isDate(context.date, inSameDayAs: sampleDay) ? steps : nil,
                             battery: battery)
                .frame(width: 166, height: 292)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        }
        .background(RadialGradient(colors: [draft.palette.color.opacity(0.15), .black],
                                   center: .center, startRadius: 10, endRadius: 210),
                    in: RoundedRectangle(cornerRadius: 25))
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(draft.kind.summary).font(.body)
            Text("仅在 iPhone 上预览和收藏，暂不能安装到手环。步数来自最近同步，电量来自最近读取。")
                .font(.footnote).foregroundStyle(.secondary)
            if draft.kind == .activity {
                Text("圆环预览使用本机 \(stepGoal.formatted()) 步目标，不会修改手环的活动目标。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if draft.kind == .solar {
                Text("弧线为装饰设计，不代表当前日出、日落或太阳位置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("颜色").font(.headline)
                Spacer()
                Text(draft.palette.title).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(WatchFacePalette.allCases) { palette in
                    Button {
                        draft.palette = palette
                    } label: {
                        Circle().fill(palette.color).frame(width: 33, height: 33)
                            .padding(5)
                            .overlay(Circle().stroke(draft.palette == palette ? .white : .clear, lineWidth: 2))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(palette.title)
                    .accessibilityAddTraits(draft.palette == palette ? [.isSelected] : [])
                }
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("样式").font(.headline)
            Picker("样式", selection: $draft.style) {
                ForEach(WatchFaceStyle.allCases) { style in Text(style.title).tag(style) }
            }.pickerStyle(.segmented)
        }
    }

    private var complicationPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("信息组件").font(.headline)
            Picker("信息组件", selection: $draft.complication) {
                ForEach(WatchFaceComplication.allCases) { item in Text(item.title).tag(item) }
            }.pickerStyle(.segmented)
        }
    }

    private var saveButton: some View {
        Button {
            draft = library.save(draft)
            savedMessage = true
        } label: {
            Text("收藏预览").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .foregroundStyle(.black)
    }
}

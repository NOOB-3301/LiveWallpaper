import SwiftUI
import Core

// Per-scene settings ("Scene settings" section of the library detail) and the global "Scenes" power settings.
// Everything writes through SettingsModel (sceneOptions / power), which commits to the service.

/// One user property read from a scene's project.json (general.properties).
struct SceneProperty: Identifiable {
    enum Kind { case group, bool, slider(min: Double, max: Double, step: Double), color, text, combo([(label: String, value: ScenePropertyValue)]) }
    let key: String
    let label: SceneMarkup
    let rawLabel: String            // original markup, the stable tie-breaker when two properties share an order
    let kind: Kind
    let order: Int
    let defaultValue: ScenePropertyValue?
    var id: String { key }

    /// Supported: group, bool, slider, color, text/textinput, combo. Anything else is skipped.
    static func load(from projectJSON: URL) -> [SceneProperty] {
        guard let data = try? Data(contentsOf: projectJSON),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let props = (root["general"] as? [String: Any])?["properties"] as? [String: Any] else { return [] }
        return props.compactMap { key, raw -> SceneProperty? in
            guard let p = raw as? [String: Any], let type = (p["type"] as? String)?.lowercased() else { return nil }
            let rawLabel = (p["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            let order = (p["order"] as? NSNumber)?.intValue ?? 0
            func make(_ kind: Kind) -> SceneProperty {
                SceneProperty(key: key, label: SceneMarkup(rawLabel), rawLabel: rawLabel, kind: kind,
                              order: order, defaultValue: Self.defaultValue(p["value"], kind: kind))
            }
            switch type {
            case "group": return make(.group)
            case "bool": return make(.bool)
            case "color": return make(.color)
            case "text", "textinput": return make(.text)
            case "slider":
                let lo = (p["min"] as? NSNumber)?.doubleValue ?? 0, hi = (p["max"] as? NSNumber)?.doubleValue ?? 1
                guard hi > lo else { return nil }
                return make(.slider(min: lo, max: hi, step: (p["step"] as? NSNumber)?.doubleValue ?? 0))
            case "combo":
                let options = (p["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, ScenePropertyValue)? in
                    guard let label = o["label"] as? String else { return nil }
                    if let n = o["value"] as? NSNumber { return (label, .number(n.doubleValue)) }
                    return (label, .string(o["value"] as? String ?? label))
                }
                return options.isEmpty ? nil : make(.combo(options))
            default: return nil
            }
        }
        .sorted { ($0.order, $0.rawLabel) < ($1.order, $1.rawLabel) }
    }

    /// The property's project.json "value", as the value type the renderer takes.
    private static func defaultValue(_ raw: Any?, kind: Kind) -> ScenePropertyValue? {
        switch kind {
        case .group:
            return nil
        case .bool:
            if let b = raw as? Bool { return .bool(b) }
            return (raw as? NSNumber).map { .bool($0.boolValue) }
        case .slider:
            return (raw as? NSNumber).map { .number($0.doubleValue) }
        case .color:
            guard let s = raw as? String else { return nil }
            let c = s.split(separator: " ").compactMap { Double($0) }
            return c.count >= 3 ? .color(red: c[0], green: c[1], blue: c[2]) : nil
        case .text:
            return (raw as? String).map { .string($0) }
        case .combo:
            if let n = raw as? NSNumber { return .number(n.doubleValue) }
            return (raw as? String).map { .string($0) }
        }
    }
}

@MainActor
fileprivate final class ScenePropertyCache {
    static var cache: [UUID: [SceneProperty]] = [:]
}

@MainActor
struct SceneSettingsCard: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem
    @State private var properties: [SceneProperty] = []

    private var options: SceneOptions { model.sceneOptions(for: item.id) }
    private func binding<T>(_ path: WritableKeyPath<SceneOptions, T>) -> Binding<T> {
        Binding(get: { model.sceneOptions(for: item.id)[keyPath: path] },
                set: { v in model.updateSceneOptions(item.id) { $0[keyPath: path] = v } })
    }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    var body: some View {
        InspectorSection(title: "Scene", subtitle: "Tuning for this wallpaper only.") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Frame rate"); Spacer()
                    Picker("Frame rate", selection: binding(\.fps)) {
                        Text("Use global").tag(Int?.none)
                        ForEach([20, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                    }.labelsHidden().fixedSize()
                }
                .help("Frame rate for this scene. “Use global” follows Scene frame rate below.")
                sliderRow("Resolution", binding(\.renderScale), 0.25...1)
                    .help("Share of the display’s pixels the scene is drawn at. Lower is lighter on the GPU.")
                sliderRow("Zoom", binding(\.zoom), 0.5...2)
                HStack {
                    Text("Fit"); Spacer()
                    Picker("Fit", selection: binding(\.fitMode)) {
                        ForEach(SceneFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                sliderRow("Volume", binding(\.volume), 0...1)
                Toggle("Scene responds to music", isOn: binding(\.audioResponse))
                Toggle("Antialiasing (coming soon)", isOn: .constant(false)).disabled(true)
                HStack {
                    Spacer()
                    Button("Reset", action: reset)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isDefault)
                        .help("Put every setting of this scene back to its default.")
                }
                if !properties.isEmpty {
                    Divider()
                    Text("Properties").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(properties) { propertyRow($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.id) { await loadProperties() }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(percent(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    /// Next to scene.pkg; an unpacked import keeps project.json one level above scene/scene.json.
    private var projectJSONURL: URL {
        let folder = item.url.deletingLastPathComponent()
        let direct = folder.appendingPathComponent("project.json")
        return FileManager.default.fileExists(atPath: direct.path)
            ? direct
            : folder.deletingLastPathComponent().appendingPathComponent("project.json")
    }

    private func loadProperties() async {
        if let cached = ScenePropertyCache.cache[item.id] { properties = cached; return }
        let url = projectJSONURL
        let loaded = await Task.detached { SceneProperty.load(from: url) }.value
        ScenePropertyCache.cache[item.id] = loaded
        properties = loaded
    }

    // MARK: Reset

    /// True when nothing differs from the defaults (properties count as default when they equal the scene's own).
    private var isDefault: Bool {
        var base = options
        base.properties = [:]
        guard base == .standard else { return false }
        return properties.allSatisfy { p in options.properties[p.key].map { $0 == p.defaultValue } ?? true }
    }

    /// Every setting back to its default. Overridden properties get their default written explicitly: dropping the
    /// key would leave the old value in the renderer until the scene restarts.
    private func reset() {
        let overridden = options.properties
        model.updateSceneOptions(item.id) { o in
            o = .standard
            for p in properties where overridden[p.key] != nil {
                if let d = p.defaultValue { o.properties[p.key] = d }
            }
        }
    }

    // MARK: Property rows

    private func current(_ p: SceneProperty) -> ScenePropertyValue? { options.properties[p.key] }
    private func set(_ p: SceneProperty, _ v: ScenePropertyValue) {
        model.updateSceneOptions(item.id) { $0.properties[p.key] = v }
    }

    @ViewBuilder private func propertyRow(_ p: SceneProperty) -> some View {
        // Labels that are only images/rules are the authors' section separators; their control is meaningless.
        if p.kind.isGroup {
            SceneMarkupView(markup: p.label)
                .padding(.top, 8)
        } else if p.label.isDecorationOnly {
            SceneMarkupView(markup: p.label)
        } else {
            switch p.kind {
            case .group:
                EmptyView()
            case .bool:
                Toggle(isOn: Binding(
                    get: {
                        if case .bool(let b)? = current(p) { return b }
                        if case .bool(let b)? = p.defaultValue { return b }
                        return false
                    },
                    set: { set(p, .bool($0)) })) { SceneMarkupView(markup: p.label) }
            case .slider(let lo, let hi, _):
                HStack(alignment: .center, spacing: 10) {
                    SceneMarkupView(markup: p.label)
                    Slider(value: Binding(
                        get: {
                            if case .number(let n)? = current(p) { return n }
                            if case .number(let n)? = p.defaultValue { return n }
                            return lo
                        },
                        set: { set(p, .number($0)) }), in: lo...hi)
                    .frame(width: 120)
                }
            case .color:
                ColorPicker(selection: Binding(
                    get: {
                        if case .color(let r, let g, let b)? = current(p) { return Color(red: r, green: g, blue: b) }
                        if case .color(let r, let g, let b)? = p.defaultValue { return Color(red: r, green: g, blue: b) }
                        return .white
                    },
                    set: { c in
                        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                        set(p, .color(red: n.redComponent, green: n.greenComponent, blue: n.blueComponent))
                    }), supportsOpacity: false) { SceneMarkupView(markup: p.label) }
            case .text:
                VStack(alignment: .leading, spacing: 6) {
                    SceneMarkupView(markup: p.label)
                    TextField("", text: Binding(
                        get: {
                            if case .string(let s)? = current(p) { return s }
                            if case .string(let s)? = p.defaultValue { return s }
                            return ""
                        },
                        set: { set(p, .string($0)) })).textFieldStyle(.roundedBorder)
                }
            case .combo(let choices):
                HStack(alignment: .center, spacing: 10) {
                    SceneMarkupView(markup: p.label)
                    Spacer(minLength: 4)
                    Picker("", selection: Binding<Int>(
                        get: {
                            if let v = current(p), let i = choices.firstIndex(where: { $0.value == v }) { return i }
                            if let v = p.defaultValue, let i = choices.firstIndex(where: { $0.value == v }) { return i }
                            return 0
                        },
                        set: { set(p, choices[$0].value) })) {
                        ForEach(choices.indices, id: \.self) { Text(choices[$0].label).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
        }
    }
}

private extension SceneProperty.Kind {
    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// Global "Scenes" rows (frame-rate cap, battery rule, render optimisations); lives inside the settings card.
@MainActor
struct ScenePowerRows: View {
    @ObservedObject var model: SettingsModel

    private func binding<T>(_ path: WritableKeyPath<PowerOptions, T>) -> Binding<T> {
        Binding(get: { model.power[keyPath: path] }, set: { model.power[keyPath: path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frame rate cap"); Spacer()
                Picker("Frame rate cap", selection: binding(\.frameRateCap)) {
                    Text("None").tag(Int?.none)
                    ForEach([30, 45, 60, 120], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            .help("No scene is drawn faster than this, whatever its own setting.")
            HStack {
                Text("On battery"); Spacer()
                Picker("On battery", selection: binding(\.batteryMode)) {
                    ForEach(BatteryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            if model.power.batteryMode == .reducedQuality {
                HStack {
                    Text("Battery resolution")
                    Slider(value: binding(\.batteryRenderScale), in: 0.25...1)
                    Text("\(Int((model.power.batteryRenderScale * 100).rounded()))%").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Battery frame rate"); Spacer()
                    Picker("Battery frame rate", selection: binding(\.batteryFPS)) {
                        ForEach([15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            Toggle("Skip repeated frames", isOn: binding(\.skipRepeatedFrames))
            Toggle("Update only when the scene changes", isOn: binding(\.renderOnlyOnChange))
                .help("Stops idle scenes completely until something in them moves.")
        }
    }
}

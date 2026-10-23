import SwiftUI
import KeibordCore

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

extension RGBAColor {
    init(_ color: Color) { self.init(uiColor: UIColor(color)) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Languages") {
                NavigationLink {
                    LanguagesView()
                } label: {
                    LabeledContent("Languages", value: model.settings.activeLanguages.map(\.shortLabel).joined(separator: ", "))
                }
            }
            Section("Typing") {
                Toggle("Auto-Correction", isOn: $model.settings.autocorrect)
                Toggle("Restore Accents (eshte → është)", isOn: $model.settings.accentRestoration)
                Toggle("Predictive Text", isOn: $model.settings.predictiveText)
                Toggle("Auto-Capitalisation", isOn: $model.settings.autoCapitalization)
                Toggle("Smart Quotes", isOn: $model.settings.smartQuotes)
                Toggle("“.” Shortcut (double space)", isOn: $model.settings.doubleSpacePeriod)
                Toggle("Smart Punctuation Spacing", isOn: $model.settings.smartPunctuationSpacing)
                Toggle("Caps Lock", isOn: $model.settings.capsLock)
                Toggle("Space Bar Cursor Control", isOn: $model.settings.spacebarCursor)
            }
            Section {
                Toggle("Learn New Words", isOn: $model.settings.learnWords)
                Toggle("Incognito (pause learning)", isOn: $model.settings.incognito)
                Toggle("Adapt to My Typing (touch model)", isOn: $model.settings.adaptiveTouch)
                Toggle("Smart Touch Zones (predict the next letter)", isOn: $model.settings.predictiveTouch)
                NavigationLink("Dictionary") { DictionaryView() }
                NavigationLink("Text Replacements") { ShortcutsView() }
            } header: {
                Text("Learning")
            } footer: {
                Text("Smart touch zones: like the iPhone keyboard, the letters you are likely to type next get a larger invisible tap area; a tap on the middle of a key always types it. Everything Keibord learns stays on this iPhone. Export it under Data to move to a new device.")
            }
            Section {
                Toggle("Suggest My Details", isOn: $model.settings.autofillSuggestions)
                Toggle("Suggest Saved Cards", isOn: $model.settings.cardSuggestions)
                Toggle("Code Fields: Offer iOS Keyboard", isOn: $model.settings.oneTimeCodeHint)
                NavigationLink("My Details") { PersonalInfoView() }
                NavigationLink("Cards") { CardsView() }
            } header: {
                Text("AutoFill")
            }
            Section("Feedback") {
                Picker("Haptics", selection: $model.settings.haptics) {
                    Text("Off").tag(HapticStrength.off)
                    Text("Light").tag(HapticStrength.light)
                    Text("Medium").tag(HapticStrength.medium)
                    Text("Strong").tag(HapticStrength.strong)
                }
                Toggle("Key Sounds", isOn: $model.settings.keySound)
                Toggle("Character Preview", isOn: $model.settings.keyPopups)
            }
            Section("Appearance") {
                NavigationLink("Theme & Keys") { AppearanceView() }
                NavigationLink("Tinted Keys") { TintedKeysView() }
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Languages

struct LanguagesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.settings.enabledLanguages, id: \.self) { language in
                    NavigationLink {
                        LanguageDetailView(language: language)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(language.displayName)
                            Text("\(language.englishName) · \(model.settings.baseLayout(for: language).displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // At least one language must stay enabled: do not offer to delete the last one.
                    .deleteDisabled(model.settings.enabledLanguages.count <= 1)
                }
                .onMove { from, to in model.settings.enabledLanguages.move(fromOffsets: from, toOffset: to) }
                .onDelete { offsets in
                    guard model.settings.enabledLanguages.count - offsets.count >= 1 else { return }
                    model.settings.enabledLanguages.remove(atOffsets: offsets)
                }
            } header: {
                Text("Enabled")
            } footer: {
                Text("The language key on the keyboard cycles through these in order. Hold it to pick one.")
            }
            let available = KeyboardLanguage.allCases.filter { !model.settings.enabledLanguages.contains($0) }
            if !available.isEmpty {
                Section("Add Language") {
                    ForEach(available, id: \.self) { language in
                        Button {
                            model.settings.enabledLanguages.append(language)
                        } label: {
                            Label(language.displayName, systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            Section {
                Toggle("Multilingual Typing", isOn: $model.settings.multilingualTyping)
            } footer: {
                Text("Suggest and correct in all enabled languages at once, without switching.")
            }
        }
        .navigationTitle("Languages")
        .toolbar { EditButton() }
    }
}

struct LanguageDetailView: View {
    @EnvironmentObject var model: AppModel
    let language: KeyboardLanguage

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Layout", selection: Binding(
                    get: { model.settings.baseLayout(for: language) },
                    set: { model.settings.layoutOverrides[language.rawValue] = $0 }
                )) {
                    ForEach(BaseLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                KeyboardPreview(settings: model.settings, language: language, dark: false)
            }
            Section("Quotes") {
                Picker("Quote Style", selection: Binding(
                    get: { model.settings.quoteStyle(for: language) },
                    set: { model.settings.quoteStyleOverrides[language.rawValue] = $0 }
                )) {
                    ForEach(QuoteStyle.allPresets.indices, id: \.self) { i in
                        Text(QuoteStyle.allPresets[i].name).tag(QuoteStyle.allPresets[i].style)
                    }
                }
            }
        }
        .navigationTitle(language.displayName)
    }
}

// MARK: - Appearance

struct AppearanceView: View {
    @EnvironmentObject var model: AppModel
    @State private var previewDark = false

    private func colorBinding(dark: Bool, _ keyPath: WritableKeyPath<KeyColorScheme, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(model.settings.appearance.colors(dark: dark)[keyPath: keyPath]) },
            set: { newValue in
                var scheme = model.settings.appearance.colors(dark: dark)
                scheme[keyPath: keyPath] = RGBAColor(newValue)
                if dark { model.settings.appearance.darkColors = scheme } else { model.settings.appearance.lightColors = scheme }
            }
        )
    }

    private func backgroundBinding(dark: Bool) -> Binding<Bool> {
        Binding(
            get: { model.settings.appearance.colors(dark: dark).background != nil },
            set: { on in
                var scheme = model.settings.appearance.colors(dark: dark)
                scheme.background = on ? (dark ? RGBAColor(hex: "#2B2B2B")! : RGBAColor(hex: "#D1D4D9")!) : nil
                if dark { model.settings.appearance.darkColors = scheme } else { model.settings.appearance.lightColors = scheme }
            }
        )
    }

    private func backgroundColorBinding(dark: Bool) -> Binding<Color> {
        Binding(
            get: { Color(model.settings.appearance.colors(dark: dark).background ?? .clear) },
            set: { newValue in
                var scheme = model.settings.appearance.colors(dark: dark)
                scheme.background = RGBAColor(newValue)
                if dark { model.settings.appearance.darkColors = scheme } else { model.settings.appearance.lightColors = scheme }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Preview", selection: $previewDark) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                KeyboardPreview(settings: model.settings, language: model.settings.activeLanguages[0], dark: previewDark)
            }
            Section("Theme") {
                Picker("Appearance", selection: $model.settings.appearance.themeMode) {
                    Text("Automatic").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
            }
            Section("Keys") {
                Picker("Key Height", selection: $model.settings.appearance.keyHeight) {
                    Text("Compact").tag(KeyHeightOption.compact)
                    Text("Standard").tag(KeyHeightOption.standard)
                    Text("Tall").tag(KeyHeightOption.tall)
                }
                VStack(alignment: .leading) {
                    Text("Corner Radius: \(Int(model.settings.appearance.keyCornerRadius))")
                    Slider(value: $model.settings.appearance.keyCornerRadius, in: 0...16, step: 0.5)
                }
                VStack(alignment: .leading) {
                    Text("Label Size: \(Int(model.settings.appearance.labelScale * 100))%")
                    Slider(value: $model.settings.appearance.labelScale, in: 0.8...1.3, step: 0.05)
                }
                Toggle("Key Shadows", isOn: $model.settings.appearance.keyShadows)
                Toggle("Always Show Upper-Case Letters", isOn: $model.settings.appearance.uppercaseLabels)
                Toggle("Number Row", isOn: $model.settings.appearance.showNumberRow)
                Toggle("Language Name on Space Bar", isOn: $model.settings.appearance.showSpaceLanguageLabel)
            }
            ForEach([false, true], id: \.self) { dark in
                Section(dark ? "Dark Colours" : "Light Colours") {
                    ColorPicker("Letter Keys", selection: colorBinding(dark: dark, \.characterKey))
                    ColorPicker("Function Keys", selection: colorBinding(dark: dark, \.functionKey))
                    ColorPicker("Labels", selection: colorBinding(dark: dark, \.label))
                    ColorPicker("Accent (Go / Send)", selection: colorBinding(dark: dark, \.accent))
                    Toggle("Custom Background", isOn: backgroundBinding(dark: dark))
                    if model.settings.appearance.colors(dark: dark).background != nil {
                        ColorPicker("Background", selection: backgroundColorBinding(dark: dark))
                    }
                    Button("Reset to iOS Colours", role: .destructive) {
                        if dark { model.settings.appearance.darkColors = nil } else { model.settings.appearance.lightColors = nil }
                    }
                }
            }
        }
        .navigationTitle("Theme & Keys")
    }
}

// MARK: - Tinted keys

struct TintedKeysView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Set<String> = []
    @State private var color: Color = .blue
    @State private var page: LayoutPage = .letters
    @State private var previewDark = false

    var body: some View {
        Form {
            Section {
                Picker("Page", selection: $page) {
                    Text("ABC").tag(LayoutPage.letters)
                    Text("123").tag(LayoutPage.numbers)
                    Text("#+=").tag(LayoutPage.symbols)
                }
                .pickerStyle(.segmented)
                KeyboardPreview(settings: model.settings, language: model.settings.activeLanguages[0], dark: previewDark,
                                page: page, selected: selection) { id in
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                }
                Toggle("Dark Preview", isOn: $previewDark)
            } header: {
                Text("Tap keys to select them")
            }
            Section {
                ColorPicker("Tint Colour", selection: $color, supportsOpacity: false)
                Button("Tint \(selection.count) Selected Key\(selection.count == 1 ? "" : "s")") {
                    let rgba = RGBAColor(color)
                    var tints = model.settings.appearance.tintedKeys.filter { !selection.contains($0.keyID) }
                    tints += selection.sorted().map { TintedKey(keyID: $0, color: rgba) }
                    model.settings.appearance.tintedKeys = tints
                    selection = []
                }
                .disabled(selection.isEmpty)
                Button("Remove Tint from Selected", role: .destructive) {
                    model.settings.appearance.tintedKeys.removeAll { selection.contains($0.keyID) }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            if !model.settings.appearance.tintedKeys.isEmpty {
                Section("Tinted Keys") {
                    ForEach(model.settings.appearance.tintedKeys) { tint in
                        HStack {
                            RoundedRectangle(cornerRadius: 5).fill(Color(tint.color)).frame(width: 28, height: 22)
                            Text(displayName(tint.keyID))
                        }
                    }
                    .onDelete { model.settings.appearance.tintedKeys.remove(atOffsets: $0) }
                }
            }
        }
        .navigationTitle("Tinted Keys")
    }

    private func displayName(_ id: String) -> String {
        switch id {
        case "space": return "Space"
        case "return": return "Return"
        case "shift": return "Shift"
        case "backspace": return "Delete"
        case "numbers": return "123"
        case "letters": return "ABC"
        case "symbols": return "#+="
        case "emoji": return "Emoji"
        case "language": return "Language"
        case "globe": return "Globe"
        case "dotcom": return ".com"
        default:
            // "ß".uppercased() is "SS": only show the upper-case form when it is still one character.
            let upper = id.uppercased()
            return upper.count == id.count ? upper : id
        }
    }
}

// MARK: - Preview

/// A static rendering of the keyboard using exactly the same layout code as the extension.
struct KeyboardPreview: View {
    let settings: KeibordSettings
    let language: KeyboardLanguage
    let dark: Bool
    var page: LayoutPage = .letters
    var selected: Set<String> = []
    var onTap: ((String) -> Void)? = nil

    private var layout: KeyboardLayout {
        LayoutFactory.layout(for: LayoutRequest(language: language, base: settings.baseLayout(for: language), page: page,
                                                showNumberRow: settings.appearance.showNumberRow && page == .letters,
                                                showLanguageKey: settings.activeLanguages.count > 1))
    }

    private var metrics: KeyboardMetrics { KeyboardMetrics.standard(height: settings.appearance.keyHeight, landscape: false) }

    var body: some View {
        let layout = self.layout
        let metrics = self.metrics
        let colors = settings.appearance.colors(dark: dark)
        let background = colors.background.map { Color($0) } ?? (dark ? Color(white: 0.17) : Color(red: 0.82, green: 0.84, blue: 0.87))
        GeometryReader { geo in
            let frames = LayoutGeometry.frames(for: layout, width: geo.size.width, metrics: metrics).filter { $0.key.style != .spacer }
            ZStack(alignment: .topLeading) {
                background
                ForEach(frames, id: \.index) { frame in
                    keyView(frame.key, colors: colors)
                        .frame(width: frame.rect.width, height: frame.rect.height)
                        .overlay(
                            RoundedRectangle(cornerRadius: CGFloat(settings.appearance.keyCornerRadius))
                                .stroke(Color.accentColor, lineWidth: selected.contains(frame.key.id) ? 3 : 0)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onTap?(frame.key.id) }
                        .offset(x: frame.rect.minX, y: frame.rect.minY)
                }
            }
        }
        .frame(height: metrics.keyboardHeight(rows: layout.rows.count))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    @ViewBuilder
    private func keyView(_ key: KeySpec, colors: KeyColorScheme) -> some View {
        let tint = settings.appearance.tint(for: key.id)
        let fill = tint?.color ?? baseFill(key, colors: colors)
        let labelColor = tint?.effectiveLabelColor ?? colors.label
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat(settings.appearance.keyCornerRadius))
                .fill(Color(fill))
                .shadow(color: settings.appearance.keyShadows ? Color(colors.keyShadow) : .clear, radius: 0, x: 0, y: 1)
            if let symbol = iconName(key) {
                Image(systemName: symbol).foregroundStyle(Color(labelColor))
            } else {
                Text(label(key))
                    .font(.system(size: key.isLetter ? 20 * settings.appearance.labelScale : 14 * settings.appearance.labelScale))
                    .foregroundStyle(Color(labelColor))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }

    private func baseFill(_ key: KeySpec, colors: KeyColorScheme) -> RGBAColor {
        key.style == .character || key.style == .space ? colors.characterKey : colors.functionKey
    }

    private func iconName(_ key: KeySpec) -> String? {
        switch key.id {
        case "shift": return "shift"
        case "backspace": return "delete.left"
        case "emoji": return "face.smiling"
        case "globe": return "globe"
        case "return": return key.label.isEmpty ? "return" : nil
        default: return nil
        }
    }

    private func label(_ key: KeySpec) -> String {
        if key.id == "space" { return settings.appearance.showSpaceLanguageLabel && settings.activeLanguages.count > 1 ? language.displayName : language.spaceKeyLabel }
        return key.isLetter && settings.appearance.uppercaseLabels ? key.label.uppercased() : key.label
    }
}

import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a place is: found by an address or a name (Apple's maps, both kinds of results to choose from), then the
/// pin dragged wherever the author wants it. Kept in the sheet's header: `lat`, `lon`, `span` (degrees seen),
/// `address`, `view` (satellite, or the street when Apple has it).
struct PlaceMapSection: View {
    /// Where the position is kept: a sheet's header, or a board card's own keys.
    @Binding var meta: [String: String]
    let title: String
    var height: CGFloat = 260
    let save: () -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    /// The search asked back, once the place is found.
    @State private var changing = false
    @State private var completer = PlaceCompleter()
    @FocusState private var typing: Bool
    @State private var camera: MapCameraPosition = .automatic
    /// Where the pin is while it is dragged.
    @State private var dragged: CLLocationCoordinate2D?
    /// The street as Apple photographed it, when it did.
    @State private var street: MKLookAroundScene?
    /// The middle of the map as one has moved it, when it is no longer where the pin is.
    @State private var centre: CLLocationCoordinate2D?

    private var pin: CLLocationCoordinate2D? { Self.coordinate(meta) }
    private var view: String { meta["view"] ?? "map" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pin == nil || changing { finder }
            if let pin {
                Group {
                    if view == "street", let street {
                        StreetView(scene: street)
                    } else {
                        map(pin)
                    }
                }
                // The field gone, the map takes its room.
                .frame(height: height + (changing ? 0 : 36))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .onAppear { camera = .region(Self.region(meta) ?? MKCoordinateRegion(center: pin, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))) }
                .task(id: meta["lat"].map { $0 + (meta["lon"] ?? "") }) {
                    street = try? await MKLookAroundSceneRequest(coordinate: pin).scene
                }
                HStack(spacing: 10) {
                    Picker("", selection: Binding(get: { view == "street" && street == nil ? "map" : view },
                                                  set: { v in write { $0["view"] = v == "map" ? nil : v } })) {
                        Image(systemName: "map").tag("map").help(L("Map"))
                        Image(systemName: "globe.europe.africa").tag("satellite").help(L("Satellite"))
                        if street != nil { Image(systemName: "binoculars").tag("street").help(L("Street view")) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(meta["address"] ?? "").foregroundStyle(.secondary).lineLimit(1)
                        .help(L("Drag the pin to adjust it."))
                    Spacer(minLength: 0)
                    Button(changing ? L("Cancel") : L("Change")) {
                        changing.toggle()
                        results = []
                        completer.clear()
                        if changing { query = meta["address"] ?? title; typing = true }
                    }
                    .buttonStyle(.link)
                    Button(L("Remove from the map")) {
                        changing = false
                        write { for k in ["lat", "lon", "span", "address", "view"] { $0[k] = nil } }
                    }
                    .buttonStyle(.link)
                }
                .font(.ui(12))
            }
        }
        .onAppear { if query.isEmpty { query = meta["address"] ?? title } }
    }

    private var finder: some View {
        Group {
            HStack(spacing: 8) {
                TextField(L("An address, a place, a landmark…"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit(search)
                    // Suggestions as one types; not for the text the field opens with.
                    .onChange(of: query) { _, text in
                        if typing { results = []; completer.suggest(text, near: Self.region(meta)) }
                    }
                Button(L("Search"), action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            if !results.isEmpty {
                list(results.map { item in (item.name ?? "", Self.line(item.placemark), { choose(item) }) })
            } else if !completer.found.isEmpty {
                list(completer.found.map { hit in (hit.title, hit.subtitle, { search(hit) }) })
            }
        }
    }

    private func map(_ pin: CLLocationCoordinate2D) -> some View {
        MapReader { proxy in
            Map(position: $camera) {
                Annotation(title, coordinate: dragged ?? pin, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 30))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Ink.accent)
                        .shadow(radius: 2, y: 1)
                        .contentShape(Rectangle().inset(by: -6))
                        .help(L("Drag the pin to adjust it."))
                        // The author knows where it is better than the map.
                        .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                            .onChanged { dragged = proxy.convert($0.location, from: .named(Self.space)) }
                            .onEnded { drag in
                                if let at = proxy.convert(drag.location, from: .named(Self.space)) { move(to: at) }
                                dragged = nil
                            })
                }
            }
            .mapStyle(view == "satellite" ? .hybrid : .standard)
            // The map moved away from the pin: a mark at its middle, and the pin put there on a click.
            .overlay {
                if centre != nil {
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.accent)
                        .shadow(color: .black.opacity(0.4), radius: 1).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if let centre {
                    Button {
                        move(to: centre)
                        self.centre = nil
                    } label: {
                        Label(L("Put the pin here"), systemImage: "mappin").font(.ui(12, .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Ink.side, in: Capsule()).overlay(Capsule().strokeBorder(Ink.hairline))
                    }
                    .buttonStyle(.plain).padding(8)
                }
            }
            .coordinateSpace(.named(Self.space))
            // The scale one leaves it at is the scale it opens at.
            .onMapCameraChange(frequency: .onEnd) { seen in
                let span = seen.region.span.latitudeDelta
                let c = seen.region.center
                let away = max(abs(c.latitude - pin.latitude), abs(c.longitude - pin.longitude) * cos(pin.latitude * .pi / 180))
                centre = away > span * 0.04 ? c : nil
                let kept = meta["span"].flatMap(Double.init) ?? 0.05
                if abs(span - kept) / kept > 0.05 { write { $0["span"] = String(format: "%.4f", span) } }
            }
        }
    }

    private static let space = "place-map"

    private func list(_ rows: [(String, String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button(action: row.2) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.ui(13))
                        if !row.1.isEmpty { Text(row.1).font(.ui(11)).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Ink.side))
    }

    /// Every key in one write: a board card's binding reads the card as it was drawn, so key-by-key writes would
    /// each start from the old card and keep only the last.
    private func write(_ change: (inout [String: String]) -> Void) {
        var m = meta
        change(&m)
        meta = m
        save()
    }

    /// Addresses first, then places: a street's name is an address before it is the café named after it.
    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        completer.clear()
        let near = Self.region(meta)
        Task { @MainActor in
            async let addresses = Self.find(text, .address, near: near)
            async let places = Self.find(text, .pointOfInterest, near: near)
            results = Self.mixed(await addresses, await places)
            searching = false
            if results.count == 1, let only = results.first { choose(only) }
        }
    }

    /// A suggestion chosen: its place looked up, and the pin put there.
    private func search(_ hit: MKLocalSearchCompletion) {
        searching = true
        completer.clear()
        Task { @MainActor in
            let found = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: hit)).start().mapItems
            searching = false
            if let first = found?.first { choose(first) }
        }
    }

    private static func find(_ text: String, _ kind: MKLocalSearch.ResultType, near: MKCoordinateRegion?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = kind
        if let near { request.region = near }
        return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    /// Three of each at most, addresses first.
    static func mixed<T>(_ addresses: [T], _ places: [T]) -> [T] {
        Array(addresses.prefix(max(3, 6 - places.count))) + Array(places.prefix(max(3, 6 - addresses.count)))
    }

    /// A result chosen: the pin there, seen at the scale of what it is (a country is not a street).
    private func choose(_ item: MKMapItem) {
        let at = item.placemark.coordinate
        let radius = (item.placemark.region as? CLCircularRegion)?.radius ?? 2000
        let span = max(0.005, min(60, radius * 2.4 / 111_000))
        results = []
        completer.clear()
        typing = false
        changing = false
        camera = .region(MKCoordinateRegion(center: at, span: .init(latitudeDelta: span, longitudeDelta: span)))
        write {
            $0["lat"] = String(format: "%.5f", at.latitude)
            $0["lon"] = String(format: "%.5f", at.longitude)
            $0["span"] = String(format: "%.4f", span)
            $0["address"] = Self.line(item.placemark).isEmpty ? item.name : Self.line(item.placemark)
        }
    }

    /// The pin moved by hand: the address it was found by is no longer where it is, but stays as its name.
    private func move(to at: CLLocationCoordinate2D) {
        write {
            $0["lat"] = String(format: "%.5f", at.latitude)
            $0["lon"] = String(format: "%.5f", at.longitude)
        }
    }

    static func coordinate(_ meta: [String: String]) -> CLLocationCoordinate2D? {
        guard let lat = meta["lat"].flatMap(Double.init), let lon = meta["lon"].flatMap(Double.init) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func region(_ meta: [String: String]) -> MKCoordinateRegion? {
        guard let at = coordinate(meta) else { return nil }
        let span = meta["span"].flatMap(Double.init) ?? 0.05
        return MKCoordinateRegion(center: at, span: .init(latitudeDelta: span, longitudeDelta: span))
    }

    static func coordinate(of e: BibleEntry) -> CLLocationCoordinate2D? { coordinate(e.meta) }
    static func region(of e: BibleEntry) -> MKCoordinateRegion? { region(e.meta) }

    static func line(_ p: MKPlacemark) -> String {
        [p.thoroughfare, p.locality, p.administrativeArea, p.country].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
    }
}

/// The street as Apple photographed it, looked around and walked along in place. (SwiftUI's own preview is a still
/// picture that opens a separate viewer; this is the viewer itself.)
private struct StreetView: NSViewControllerRepresentable {
    let scene: MKLookAroundScene

    func makeNSViewController(context: Context) -> MKLookAroundViewController {
        let c = MKLookAroundViewController(scene: scene)
        c.isNavigationEnabled = true
        c.showsRoadLabels = true
        c.badgePosition = .bottomTrailing
        return c
    }

    func updateNSViewController(_ c: MKLookAroundViewController, context: Context) {
        if c.scene !== scene { c.scene = scene }
    }
}

/// Places suggested as the author types (Apple's maps): addresses and named places, asked apart so that neither
/// crowds the other out.
@MainActor
@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private var addresses: [MKLocalSearchCompletion] = []
    private var places: [MKLocalSearchCompletion] = []
    var found: [MKLocalSearchCompletion] { PlaceMapSection.mixed(addresses, places) }
    @ObservationIgnored private lazy var forAddresses = make(.address)
    @ObservationIgnored private lazy var forPlaces = make(.pointOfInterest)

    private func make(_ kind: MKLocalSearchCompleter.ResultType) -> MKLocalSearchCompleter {
        let c = MKLocalSearchCompleter()
        c.resultTypes = kind
        c.delegate = self
        return c
    }

    func suggest(_ text: String, near region: MKCoordinateRegion?) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { clear(); return }
        for c in [forAddresses, forPlaces] {
            if let region { c.region = region }
            c.queryFragment = text
        }
    }

    func clear() {
        forAddresses.cancel()
        forPlaces.cancel()
        addresses = []
        places = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            if completer === forAddresses { addresses = completer.results } else { places = completer.results }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if completer === forAddresses { addresses = [] } else { places = [] }
        }
    }
}

/// What the author keeps with a sheet: photos, links, PDFs, dropped on it. Files go to the documents; the sheet keeps
/// the list (`attachments`, separated by « | »).
struct AttachmentsSection: View {
    @Binding var draft: BibleEntry
    let bible: BibleModel
    let open: (String) -> Void
    let save: () -> Void
    @State private var target = false

    private var items: [String] { (draft.meta["attachments"] ?? "").components(separatedBy: "|").filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Pinned")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in tile(item) }
                Text(L("Drop a photo, a link or a PDF here"))
                    .font(.ui(11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(target ? Ink.accent : Ink.hairline))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { add(url) }
            return true
        } isTargeted: { target = $0 }
    }

    private func tile(_ item: String) -> some View {
        let isLink = item.hasPrefix("http")
        let url = isLink ? URL(string: item) : bible.store.url(item)
        let isImage = !isLink && UTType(filenameExtension: (item as NSString).pathExtension)?.conforms(to: .image) == true
        return ZStack(alignment: .topTrailing) {
            Button {
                if isLink, let url { NSWorkspace.shared.open(url) } else if bible.entry(path: item) != nil { open(item) } else if let url { NSWorkspace.shared.open(url) }
            } label: {
                Group {
                    // A thumbnail, kept while the file is the same: the photo is not decoded whole at each letter typed
                    // in the sheet. (What ImageIO can't read, an SVG, is still read as before.)
                    if isImage, let url, let image = BoardThumbs.image(url) ?? NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: isLink ? "globe" : "doc").font(.ui(18)).foregroundStyle(.secondary)
                            Text(isLink ? (url?.host ?? item) : (item as NSString).lastPathComponent).font(.ui(11)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(6)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 90)
                .clipped()
                .background(Ink.side)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)
            Button { remove(item) } label: { Image(systemName: "xmark.circle.fill").font(.ui(12)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).padding(4).accessibilityLabel(L("Remove"))
        }
    }

    private func add(_ url: URL) {
        let item: String
        if url.isFileURL {
            guard let path = try? bible.bring(url) else { return }
            item = path
        } else {
            item = url.absoluteString
        }
        draft.meta["attachments"] = (items + [item]).joined(separator: "|")
        save()
    }

    private func remove(_ item: String) {
        let rest = items.filter { $0 != item }
        draft.meta["attachments"] = rest.isEmpty ? nil : rest.joined(separator: "|")
        save()
    }
}

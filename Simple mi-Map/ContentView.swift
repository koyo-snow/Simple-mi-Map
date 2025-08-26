//
//  ContentView.swift
//  mindmap
//
//  Rewritten for a polished SwiftUI mind map editor
//  Created by Yumi Ishiguro on 2025/08/23
//


import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import AppKit
#endif

// MARK: - App constants
fileprivate enum Const {
    static let gridSnap: CGFloat = 10
    static let zoomMin: CGFloat = 0.3
    static let zoomMax: CGFloat = 3.0
}

// MARK: - Codable helpers
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double
    func toColor() -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    static func from(_ color: Color) -> RGBA {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, &g, &b, &a)
        return RGBA(r: r.double, g: g.double, b: b.double, a: a.double)
        #else
        let ns = NSColor(color)
        guard let c = ns.usingColorSpace(.sRGB) else { return RGBA(r: 0.9, g: 0.9, b: 0.9, a: 1) }
        return RGBA(r: c.redComponent.double, g: c.greenComponent.double, b: c.blueComponent.double, a: c.alphaComponent.double)
        #endif
    }
}

struct CGPointCodable: Codable, Hashable {
    var x: Double, y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    static func from(_ p: CGPoint) -> CGPointCodable { .init(x: p.x.double, y: p.y.double) }
}

fileprivate extension CGFloat { var double: Double { Double(self) } }

// Anchor points around a node
enum Anchor: String, Codable, CaseIterable, Hashable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Boards metadata (multiple mind maps)
struct BoardMeta: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var fileName: String // e.g. "board_XXXX.json"
}

// MARK: - Models
struct MindNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = "新しいノード"
    var position: CGPointCodable = .init(x: 0, y: 0)
    var color: RGBA = RGBA.from(.yellow.opacity(0.9))
    var width: Double = 180
    var height: Double = 64
}

// MARK: - MindNode geometry helpers
fileprivate extension MindNode {
    var center: CGPoint { position.cgPoint }
    var halfWidth: CGFloat { CGFloat(width) / 2 }
    var halfHeight: CGFloat { CGFloat(height) / 2 }

    func anchorPoint(_ a: Anchor) -> CGPoint {
        let c = center
        switch a {
        case .top:         return CGPoint(x: c.x, y: c.y - halfHeight)
        case .bottom:      return CGPoint(x: c.x, y: c.y + halfHeight)
        case .left:        return CGPoint(x: c.x - halfWidth, y: c.y)
        case .right:       return CGPoint(x: c.x + halfWidth, y: c.y)
        case .topLeft:     return CGPoint(x: c.x - halfWidth, y: c.y - halfHeight)
        case .topRight:    return CGPoint(x: c.x + halfWidth, y: c.y - halfHeight)
        case .bottomLeft:  return CGPoint(x: c.x - halfWidth, y: c.y + halfHeight)
        case .bottomRight: return CGPoint(x: c.x + halfWidth, y: c.y + halfHeight)
        }
    }

    var allAnchors: [(Anchor, CGPoint)] {
        Anchor.allCases.map { ($0, anchorPoint($0)) }
    }
}

struct MindEdge: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var from: UUID
    var to: UUID
    // Optional anchors for precise connection points (backward compatible)
    var fromAnchor: Anchor? = nil
    var toAnchor: Anchor? = nil
}

struct MindMap: Codable, Equatable {
    var nodes: [MindNode] = []
    var edges: [MindEdge] = []
}

// MARK: - ViewModel
@MainActor
final class MindMapVM: ObservableObject {
    @Published var map = MindMap()

    // View state
    @Published var selected: UUID? = nil
    @Published var isConnectMode = false
    @Published var connectFrom: UUID? = nil
    @Published var connectFromAnchor: Anchor? = nil
    @Published var zoom: CGFloat = 1.0
    @Published var pan: CGSize = .zero
    @Published var showGrid = true
    @Published var snapToGrid = true
    
    // Boards (multiple maps)
    @Published var boards: [BoardMeta] = []
    @Published var currentBoardID: UUID? = nil
    
    @Published var isAddMode: Bool = false
    @Published var isEraseMode = false
    @Published var eraseFrom: UUID? = nil
    @Published var selectedEdgeID: UUID? = nil
    
    @Published var secondarySelected: UUID? = nil

    // Undo/Redo stacks
    private var undoStack: [MindMap] = []
    private var redoStack: [MindMap] = []
    private let undoLimit: Int = 100

    // Editing
    @Published var editorTarget: MindNode? = nil
    // Remember last used node color for new node additions
    @Published var lastNodeColor: RGBA = RGBA.from(.yellow.opacity(0.9))
    // Drag state (per-node drag origin)
    var dragStart: [UUID: CGPoint] = [:]

    // Persistence
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var boardsIndexURL: URL { documentsDir.appendingPathComponent("boards_index.json") }

    private var fileURL: URL {
        if let id = currentBoardID, let meta = boards.first(where: { $0.id == id }) {
            return documentsDir.appendingPathComponent(meta.fileName)
        }
        // fallback（初回や移行時）
        return documentsDir.appendingPathComponent("mindmap.json")
    }

    init() {
        loadBoards()
        if boards.isEmpty {
            // 旧: mindmap.json を見つけたら最初のボードとして取り込み
            let legacy = documentsDir.appendingPathComponent("mindmap.json")
            let newMeta = BoardMeta(name: "ボード1", fileName: "board_\(UUID().uuidString).json")
            boards = [newMeta]
            currentBoardID = newMeta.id
            if FileManager.default.fileExists(atPath: legacy.path) {
                do {
                    let data = try Data(contentsOf: legacy)
                    map = try JSONDecoder().decode(MindMap.self, from: data)
                    if let c = map.nodes.last?.color { lastNodeColor = c }
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    map = MindMap()
                }
            } else {
                map = MindMap(nodes: [MindNode(title: "メインアイデア", position: .from(.zero), color: RGBA.from(.orange.opacity(0.9)))], edges: [])
                lastNodeColor = map.nodes.first?.color ?? lastNodeColor
                save()
            }
            saveBoards()
        } else if currentBoardID == nil {
            currentBoardID = boards.first?.id
            load()
        } else {
            load()
        }
        clearHistory()
    }

    // Begin a node drag: remember original position once
    func beginDrag(_ node: MindNode) {
        if dragStart[node.id] == nil {
            // ドラッグで位置が初めて変わる「前」に履歴を積む
            recordUndo()
            dragStart[node.id] = node.position.cgPoint
        }
    }

    // Update a node drag using translation relative to the remembered origin
    func drag(_ node: MindNode, translation: CGSize) {
        guard let start = dragStart[node.id],
              let idx = map.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let p = CGPoint(
            x: start.x + translation.width / max(zoom, 0.01),
            y: start.y + translation.height / max(zoom, 0.01)
        )
        map.nodes[idx].position = .from(p)
    }

    // End a node drag: optional snap then save
    func endDrag(_ node: MindNode) {
        // Undo は beginDrag で積済み。ここでは確定処理のみ。
        if snapToGrid, let idx = map.nodes.firstIndex(where: { $0.id == node.id }) {
            let snapped = map.nodes[idx].position.cgPoint.snapped(to: Const.gridSnap)
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                map.nodes[idx].position = .from(snapped)
            }
        }
        dragStart.removeValue(forKey: node.id)
        save()
    }

    func addNode(at worldPoint: CGPoint = .zero) {
        recordUndo()
        let n = MindNode(title: "ノード", position: .from(worldPoint), color: lastNodeColor)
        map.nodes.append(n)
        selected = n.id
        save()
    }

    func deleteSelection() {
        guard let id = selected else { return }
        recordUndo()
        map.edges.removeAll { $0.from == id || $0.to == id }
        map.nodes.removeAll { $0.id == id }
        selected = nil
        secondarySelected = nil
        save()
    }

    // 2ノード間にエッジがあるか（向きはどちらでもOK）
    func hasEdge(between a: UUID, and b: UUID) -> Bool {
        map.edges.contains { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    // 現在選択されている2ノード間のエッジを削除
    func deleteEdgeBetweenSelectedNodes() {
        guard let a = selected, let b = secondarySelected, a != b else { return }
        let before = map.edges.count
        if before > 0 {
            recordUndo()
            map.edges.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
            if map.edges.count != before { save() }
        }
    }

    // Remove all edges connected to a given node id
    func removeEdges(of id: UUID) {
        recordUndo()
        let before = map.edges.count
        map.edges.removeAll { $0.from == id || $0.to == id }
        if map.edges.count != before { save() }
    }

    func move(node: MindNode, by delta: CGSize) {
        if dragStart[node.id] == nil {
            recordUndo()
            dragStart[node.id] = node.position.cgPoint
        }
        guard let idx = map.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        var p = node.position.cgPoint
        p.x += delta.width / max(zoom, 0.01)
        p.y += delta.height / max(zoom, 0.01)
        map.nodes[idx].position = .from(p)
    }

    func endMove() {
        if snapToGrid, let sel = selected, let idx = map.nodes.firstIndex(where: { $0.id == sel }) {
            let snapped = map.nodes[idx].position.cgPoint.snapped(to: Const.gridSnap)
            map.nodes[idx].position = .from(snapped)
        }
        // clear any armed move origin
        if let sel = selected { dragStart.removeValue(forKey: sel) }
        save()
    }
    
    func startConnection(from node: MindNode, anchor: Anchor) {
        isConnectMode = true
        connectFrom = node.id
        connectFromAnchor = anchor
    }

    func finishConnection(to node: MindNode, anchor: Anchor? = nil) {
        guard let from = connectFrom else { return }

        if from != node.id {
            let exists = map.edges.contains {
                ($0.from == from && $0.to == node.id) || ($0.from == node.id && $0.to == from)
            }
            if !exists {
                recordUndo()
                map.edges.append(
                    MindEdge(from: from, to: node.id, fromAnchor: connectFromAnchor, toAnchor: anchor)
                )
                save()
            }
            // Enable continuous connect: keep mode ON and make the last target the new start
            connectFrom = node.id
            connectFromAnchor = anchor
            isConnectMode = true
        } else {
            // If the user clicked the same node, just keep waiting for a different end point
            connectFrom = node.id
            connectFromAnchor = anchor
            isConnectMode = true
        }
    }

    func toggleConnection(to node: MindNode) {
        // kept for toolbar compatibility; real connect uses anchor handles
        selected = node.id
    }
    
    func beginSimpleConnect(from node: MindNode) {
        isConnectMode = true
        connectFrom = node.id
        connectFromAnchor = nil
    }
    
    // MARK: - Erase (edge delete) mode
    func beginErase(from node: MindNode) {
        // モードON＋起点アーム
        isEraseMode = true
        eraseFrom = node.id
        // 接続モードとは排他
        isConnectMode = false
        connectFrom = nil
        connectFromAnchor = nil
    }

    func finishErase(to node: MindNode) {
        guard let from = eraseFrom else { return }

        // 同一ノードを2回クリック → 何もしないで待機継続
        if from == node.id {
            eraseFrom = node.id
            isEraseMode = true
            return
        }

        // 双方向どちらでも一致するエッジを削除
        let before = map.edges.count
        map.edges.removeAll { ($0.from == from && $0.to == node.id) || ($0.from == node.id && $0.to == from) }
        if map.edges.count != before {
            recordUndo()
            save()
        } else {
            save()
        }

        // 連続消去: 直前の終点を次の起点にする
        eraseFrom = node.id
        isEraseMode = true
    }

    // MARK: - Undo/Redo
    func recordUndo() {
        undoStack.append(map)
        if undoStack.count > undoLimit { _ = undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let current = map
        redoStack.append(current)
        map = previous
        save()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = map
        undoStack.append(current)
        map = next
        save()
    }

    private func clearHistory() {
        undoStack.removeAll(); redoStack.removeAll()
    }


    func save() {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Save error: \(error)")
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            map = try JSONDecoder().decode(MindMap.self, from: data)
            if let c = map.nodes.last?.color { lastNodeColor = c }
        } catch {
            // ボードファイルが無い／壊れている場合は初期マップを生成して保存
            map = MindMap(
                nodes: [MindNode(title: "メインアイデア",
                                 position: .from(.zero),
                                 color: lastNodeColor)],
                edges: []
            )
            save()
        }
        clearHistory()
    }
    
    // MARK: - Boards persistence
    private func saveBoards() {
        do {
            let data = try JSONEncoder().encode(boards)
            try data.write(to: boardsIndexURL, options: .atomic)
        } catch { print("Save boards error: \(error)") }
    }

    func loadBoards() {
        do {
            let data = try Data(contentsOf: boardsIndexURL)
            boards = try JSONDecoder().decode([BoardMeta].self, from: data)
            if let raw = UserDefaults.standard.string(forKey: "currentBoardID"),
               let id = UUID(uuidString: raw) {
                currentBoardID = id
            }
        } catch {
            boards = []
            currentBoardID = nil
        }
    }
    
    // Generate a unique board name like "名前", "名前 (2)", "名前 (3)" ...
    private func makeUniqueName(_ base: String, excluding excludeID: UUID? = nil) -> String {
        let baseName = base.isEmpty ? "新規ボード" : base
        var used = Set<Int>() // 1 means "base", 2 means "base (2)", etc.
        for b in boards where b.id != excludeID {
            if b.name == baseName {
                used.insert(1)
            } else if b.name.hasPrefix(baseName + " (") && b.name.hasSuffix(")") {
                let start = baseName.count + 2 // skip "base ("
                let end = b.name.count - 1     // drop ")"
                if start < end {
                    let numStr = String(b.name[b.name.index(b.name.startIndex, offsetBy: start)..<b.name.index(b.name.startIndex, offsetBy: end)])
                    if let n = Int(numStr) { used.insert(n) }
                }
            }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return n == 1 ? baseName : "\(baseName) (\(n))"
    }

    // MARK: - Board operations
    @discardableResult
    func createBoard(name: String) -> UUID {
        // まず現在のボードを保存（作業の取りこぼし防止）
        save()
        let finalName = makeUniqueName(name)
        let meta = BoardMeta(name: finalName,
                             fileName: "board_\(UUID().uuidString).json")
        boards.append(meta)
        currentBoardID = meta.id
        map = MindMap(nodes: [MindNode(title: "メインアイデア",
                                       position: .from(.zero),
                                       color: RGBA.from(.yellow.opacity(0.9)))],
                      edges: [])
        save()
        saveBoards()
        persistCurrentBoardID()
        return meta.id
    }

    @discardableResult
    func duplicateCurrentBoard() -> UUID? {
        guard let cur = currentBoardID, let metaCur = boards.first(where: { $0.id == cur }) else { return nil }
        let dupBase = "複製 - \(metaCur.name)"
        let newMeta = BoardMeta(name: makeUniqueName(dupBase),
                                fileName: "board_\(UUID().uuidString).json")
        boards.append(newMeta)
        currentBoardID = newMeta.id
        // copy current map content
        save() // ensure current saved
        do {
            let data = try JSONEncoder().encode(map)
            let url = documentsDir.appendingPathComponent(newMeta.fileName)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Duplicate board error: \(error)")
        }
        saveBoards()
        persistCurrentBoardID()
        return newMeta.id
    }

    func switchBoard(to id: UUID) {
        guard boards.contains(where: { $0.id == id }) else { return }
        // 現在のボードを保存
        save()
        // 切り替え
        currentBoardID = id
        // 新ボードを読み込み
        load()
        // 見た目と選択状態をリセット（切替が分かりやすい）
        selected = nil
        selectedEdgeID = nil
        isConnectMode = false
        isEraseMode = false
        connectFrom = nil
        connectFromAnchor = nil
        eraseFrom = nil
        zoom = 1.0
        pan = .zero
        // 永続化と履歴クリア
        persistCurrentBoardID()
        clearHistory()
        // 念のため更新通知
        objectWillChange.send()
    }

    func renameBoard(id: UUID, to newName: String) {
        guard let idx = boards.firstIndex(where: { $0.id == id }) else { return }
        let base = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        let unique = makeUniqueName(base, excluding: id)
        if boards[idx].name != unique {
            boards[idx].name = unique
            saveBoards()
        }
    }

    func deleteBoard(id: UUID) {
        guard let idx = boards.firstIndex(where: { $0.id == id }) else { return }
        if boards.count <= 1 { return } // 最後の1枚は残す
        let meta = boards[idx]
        boards.remove(at: idx)
        let url = documentsDir.appendingPathComponent(meta.fileName)
        try? FileManager.default.removeItem(at: url)
        if currentBoardID == meta.id { currentBoardID = boards.first?.id; load() }
        saveBoards()
        persistCurrentBoardID()
    }

    private func persistCurrentBoardID() {
        if let id = currentBoardID { UserDefaults.standard.set(id.uuidString, forKey: "currentBoardID") }
    }
    
    func anchorPoints(for node: MindNode) -> [(Anchor, CGPoint)] { node.allAnchors }

    /// Resolve world-space endpoints for an edge, honoring optional anchors; falls back to closest anchors
    func resolvedEndpoints(for edge: MindEdge) -> (CGPoint, CGPoint)? {
        resolveEndpoints(edge: edge, in: map.nodes)
    }
}

fileprivate extension CGPoint {
    func snapped(to step: CGFloat) -> CGPoint {
        CGPoint(x: (x/step).rounded() * step, y: (y/step).rounded() * step)
    }
}

// MARK: - Shared edge resolver
fileprivate func resolveEndpoints(edge: MindEdge, in nodes: [MindNode]) -> (CGPoint, CGPoint)? {
    guard let nA = nodes.first(where: { $0.id == edge.from }),
          let nB = nodes.first(where: { $0.id == edge.to }) else { return nil }

    // Both anchors specified -> direct
    if let aFrom = edge.fromAnchor, let aTo = edge.toAnchor {
        return (nA.anchorPoint(aFrom), nB.anchorPoint(aTo))
    }

    // Otherwise: choose closest pair (respect fixed side if present)
    let aList = nA.allAnchors.map { $0.1 }
    let bList = nB.allAnchors.map { $0.1 }

    var bestA = nA.center
    var bestB = nB.center
    var bestD = CGFloat.greatestFiniteMagnitude

    for pa in aList {
        for pb in bList {
            if let fixedA = edge.fromAnchor.map({ nA.anchorPoint($0) }), pa != fixedA { continue }
            if let fixedB = edge.toAnchor.map({ nB.anchorPoint($0) }),  pb != fixedB { continue }
            let d = hypot(pa.x - pb.x, pa.y - pb.y)
            if d < bestD { bestD = d; bestA = pa; bestB = pb }
        }
    }
    return (bestA, bestB)
}

// MARK: - Views
#if os(macOS)
/// Captures scroll wheel events using a local event monitor so it works even when hit testing is disabled.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ shift: Bool, _ precise: Bool) -> Void

    final class Coordinator {
        var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ shift: Bool, _ precise: Bool) -> Void = {_,_,_,_ in}
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.onScroll = onScroll
        // Install monitor to catch scroll wheel anywhere in the window
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            context.coordinator.onScroll(
                CGFloat(event.scrollingDeltaX),
                CGFloat(event.scrollingDeltaY),
                event.modifierFlags.contains(.shift),
                event.hasPreciseScrollingDeltas
            )
            // consume the event so default views don't also scroll the canvas
            return nil
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }
}
#endif

// macOS key event catcher for undo/redo
#if os(macOS)
struct KeyEventCatcher: NSViewRepresentable {
    var onUndo: () -> Void
    var onRedo: () -> Void

    final class Coordinator {
        var onUndo: () -> Void = {}
        var onRedo: () -> Void = {}
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore if any text field is first responder
            if let fr = NSApp.keyWindow?.firstResponder, fr.isKind(of: NSTextView.self) { return event }
            let isCmd = event.modifierFlags.contains(.command)
            let isShift = event.modifierFlags.contains(.shift)
            if isCmd, let ch = event.charactersIgnoringModifiers?.lowercased(), ch == "z" {
                if isShift { context.coordinator.onRedo() } else { context.coordinator.onUndo() }
                return nil // consume
            }
            return event
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }
}
#endif

struct ContentView: View {
    @StateObject private var vm = MindMapVM()
    @State private var canvasSize: CGSize = .zero
    @State private var exportAlert: (Bool, URL?) = (false, nil)
    @State private var gestureZoom: CGFloat = 1.0   // ピンチ中だけの拡大率
    @State private var gesturePan: CGSize = .zero   // ドラッグ中だけの平行移動
    @State private var showDeleteBoardConfirm = false
    @State private var showRenameBoardAlert = false
    @State private var renameBoardText: String = ""
    @AppStorage("toolbarLabelStyle") private var toolbarLabelStyle: String = "titleAndIcon" // or "iconOnly"
    @SceneStorage("sceneBoardID") private var sceneBoardID: String?
    @State private var didRestoreFromScene = false

    var body: some View {
        Group {
            NavigationStack {
                GeometryReader { geo in
                    ZStack {
                        if vm.showGrid { GridBackground(zoom: vm.zoom, pan: vm.pan) }

                        // World content (edges + nodes) with transforms
                        WorldContent(
                            vm: vm,
                            zoom: vm.zoom * gestureZoom,
                            pan: vm.pan + gesturePan
                        )
                    }
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: gesturePan)
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: gestureZoom)
                    .onAppear {
                        canvasSize = geo.size
                        // 初回だけ SceneStorage 復元（手動切替の直後に巻き戻らないように）
                        if !didRestoreFromScene {
                            if let raw = sceneBoardID, let id = UUID(uuidString: raw), id != vm.currentBoardID {
                                vm.switchBoard(to: id)
                            }
                            didRestoreFromScene = true
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(canvasGestures())
                    .onTapGesture { location in
                        if vm.isAddMode {
                            let totalZoom = max(0.01, vm.zoom * gestureZoom)
                            let totalPan = vm.pan + gesturePan
                            let worldX = (location.x - totalPan.width) / totalZoom
                            let worldY = (location.y - totalPan.height) / totalZoom
                            vm.addNode(at: CGPoint(x: worldX, y: worldY))
                        } else {
                            // 背景クリックで選択解除
                            vm.selected = nil
                            vm.secondarySelected = nil
                            vm.selectedEdgeID = nil
                        }
                    }
#if os(macOS)
                    .overlay(
                        ScrollWheelCatcher { dx, dy, shift, precise in
                            // Adjusted: invert direction per user feedback (natural: wheel up -> view goes up)
                            let factor: CGFloat = precise ? 2.0 : 20.0
                            var p = vm.pan

                            if shift {
                                // Shift: horizontal only. Pick the dominant axis and move accordingly (no sign inversion).
                                let h = abs(dx) >= abs(dy) ? dx : dy
                                p.width += h * factor
                            } else {
                                // Free pan: apply raw deltas (no minus) so wheel up -> view moves up
                                if abs(dx) > 0.01 { p.width += dx * factor }
                                p.height += dy * factor
                            }

                            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) {
                                vm.pan = p
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    )
                    .overlay(
                        KeyEventCatcher(
                            onUndo: { if vm.editorTarget == nil { vm.undo() } },
                            onRedo: { if vm.editorTarget == nil { vm.redo() } }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    )
                    .overlay(
                        VStack(spacing: 0) {
                            // Invisible buttons to bind Command-Z / Shift-Command-Z
                            Button(action: { if vm.editorTarget == nil { vm.undo() } }) {
                                EmptyView()
                            }
                            .keyboardShortcut("z", modifiers: .command)
                            .disabled(false)

                            Button(action: { if vm.editorTarget == nil { vm.redo() } }) {
                                EmptyView()
                            }
                            .keyboardShortcut("Z", modifiers: [.command, .shift])
                            .disabled(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.001)
                        .allowsHitTesting(false)
                    )
#endif
                    .toolbar { toolbar(geo: geo) }
                    .navigationTitle(vm.boards.first(where: { $0.id == vm.currentBoardID })?.name ?? "Simple mi-Map")
#if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .onReceive(vm.$map.dropFirst()) { _ in vm.save() }
                    .sheet(item: $vm.editorTarget) { n in
                        NodeEditor(node: n) { updated in
                            if let idx = vm.map.nodes.firstIndex(where: { $0.id == updated.id }) {
                                vm.recordUndo()
                                vm.map.nodes[idx] = updated
                                vm.lastNodeColor = updated.color
                                vm.save()
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                    .alert("PNGを書き出しました", isPresented: $exportAlert.0) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        if let url = exportAlert.1 { Text(url.path) }
                    }
                    .alert("ボード名を変更", isPresented: $showRenameBoardAlert) {
                        TextField("名前", text: $renameBoardText)
                        Button("保存") {
                            if let id = vm.currentBoardID { vm.renameBoard(id: id, to: renameBoardText) }
                        }
                        Button("キャンセル", role: .cancel) {}
                    }
                    .alert("現在のボードを削除しますか？", isPresented: $showDeleteBoardConfirm) {
                        Button("削除", role: .destructive) {
                            if let id = vm.currentBoardID { vm.deleteBoard(id: id) }
                        }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("最後の1枚は削除できません。")
                    }
                    .onChange(of: vm.currentBoardID) { _, newValue in
                        sceneBoardID = newValue?.uuidString
                    }
                }
            }
        }
        // ボードIDが変わったらビュー階層全体を再構築
        .id(vm.currentBoardID ?? UUID())
    }

    // MARK: Gestures
    private func canvasGestures() -> some Gesture {
        SimultaneousGesture(
            // パン（ドラッグ）: ドラッグ中は一時オフセット、終了時に慣性を足して確定
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    gesturePan = value.translation
                }
                .onEnded { value in
                    // 基本移動
                    var target = vm.pan + value.translation
                    // 予測終点から惰性分を抽出して少しだけ足す
                    let vx = value.predictedEndTranslation.width - value.translation.width
                    let vy = value.predictedEndTranslation.height - value.translation.height
                    let inertia = CGSize(width: vx * 0.15, height: vy * 0.15)
                    target = target + inertia
                    withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 120, damping: 18, initialVelocity: 0)) {
                        vm.pan = target
                    }
                    gesturePan = .zero
                    vm.save()
                },
            // ピンチズーム: 感度を少し柔らかく（pow）して、終了時にスプリングで確定
            MagnificationGesture()
                .onChanged { value in
                    let softened = pow(value, 0.9) // 感度を少しマイルドに
                    gestureZoom = softened
                }
                .onEnded { value in
                    let softened = pow(value, 0.9)
                    let newZoom = clamp(vm.zoom * softened, Const.zoomMin, Const.zoomMax)
                    withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 150, damping: 20, initialVelocity: 0)) {
                        vm.zoom = newZoom
                    }
                    gestureZoom = 1.0
                }
        )
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private func toolbar(geo: GeometryProxy) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.isAddMode.toggle()
            } label: {
                Label(vm.isAddMode ? "追加モード: クリックで配置" : "ノード追加",
                      systemImage: vm.isAddMode ? "plus.viewfinder" : "plus.circle")
            }

            Button {
                if vm.isConnectMode {
                    vm.isConnectMode = false
                    vm.connectFrom = nil
                    vm.connectFromAnchor = nil
                } else {
                    vm.isConnectMode = true
                    vm.connectFrom = nil
                    vm.connectFromAnchor = nil
                }
            } label: {
                Label(vm.isConnectMode ? (vm.connectFrom == nil ? "接続: 起点を選択" : "接続: 終点を選択") : "接続",
                      systemImage: vm.isConnectMode ? "link.circle.fill" : "link")
            }


            Button { vm.zoom = 1.0; vm.pan = .zero } label: { Label("リセット", systemImage: "arrow.counterclockwise") }

            Button { vm.showGrid.toggle() } label: { Label("グリッド", systemImage: vm.showGrid ? "square.grid.3x3.topleft.filled" : "square.grid.3x3") }

            Button { vm.snapToGrid.toggle() } label: { Label("スナップ", systemImage: vm.snapToGrid ? "hand.tap.fill" : "hand.tap") }

            Button {
                exportPNG(size: geo.size)
            } label: {
                Label("PNG書き出し", systemImage: "square.and.arrow.down")
            }
            
            Button {
                vm.deleteEdgeBetweenSelectedNodes()
            } label: {
                Label("エッジ削除", systemImage: "scissors")
            }
            .disabled(!(vm.selected != nil && vm.secondarySelected != nil && { let a = vm.selected!, b = vm.secondarySelected!; return vm.hasEdge(between: a, and: b) }()))

            Button(role: .destructive) { vm.deleteSelection() } label: { Label("ノード削除", systemImage: "trash") }
                .disabled(vm.selected == nil)
            
            Menu {
                // Quick select list
                ForEach(vm.boards) { b in
                    Button {
                        vm.switchBoard(to: b.id)
                    } label: {
                        HStack {
                            Text(b.name)
                            if vm.currentBoardID == b.id { Spacer(); Image(systemName: "checkmark") }
                        }
                    }
                }
                Divider()
                Button {
                    _ = vm.createBoard(name: "")
                } label: {
                    Label("新規作成", systemImage: "plus")
                }
                Button {
                    _ = vm.duplicateCurrentBoard()
                } label: {
                    Label("複製", systemImage: "doc.on.doc")
                }
                Button {
                    if let id = vm.currentBoardID, let meta = vm.boards.first(where: { $0.id == id }) {
                        renameBoardText = meta.name
                        showRenameBoardAlert = true
                    }
                } label: {
                    Label("現在のボードの名前変更", systemImage: "pencil")
                }
                Button {
                    showDeleteBoardConfirm = true
                } label: {
                    Label("現在のボードを削除", systemImage: "trash")
                }
                .disabled(vm.boards.count <= 1)
            } label: {
                Label("ボード", systemImage: "rectangle.stack")
            }
        }
    }

    #if os(macOS)
    /// Let user choose a save location for the exported PNG
    private func chooseSaveURL(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif

    private func exportPNG(size: CGSize) {
        let renderer = ImageRenderer(content:
            ExportView(map: vm.map, zoom: vm.zoom, pan: vm.pan, showGrid: vm.showGrid)
                .frame(width: size.width, height: size.height)
        )
        #if os(iOS)
        if let uiImage = renderer.uiImage, let data = uiImage.pngData() {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("simple_mi_map_\(Int(Date().timeIntervalSince1970)).png")
            try? data.write(to: url)
            exportAlert = (true, url)
        }
        #else
        if let nsImage = renderer.nsImage,
           let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            let name = "simple_mi_map_\(Int(Date().timeIntervalSince1970)).png"
            if let url = chooseSaveURL(defaultName: name) {
                do {
                    try data.write(to: url)
                    exportAlert = (true, url)
                } catch {
                    exportAlert = (false, nil)
                    print("Save PNG error: \(error)")
                }
            } else {
                // user cancelled; do not show success alert
                exportAlert = (false, nil)
            }
        }
        #endif
    }
}


// MARK: - ToolbarIconLabel
struct ToolbarIconLabel: View {
    let iconOnly: Bool
    let title: String
    let systemName: String
    var body: some View {
        if iconOnly {
            Image(systemName: systemName)
        } else {
            VStack(spacing: 2) {
                Image(systemName: systemName)
                Text(title).font(.caption2)   // 下に小さく
            }
        }
    }
}

// MARK: - NodeView
struct NodeView: View {
    var node: MindNode
    var selected: Bool
    var secondary: Bool
    var connectFrom: Bool

    var body: some View {
        Text(node.title)
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(width: node.width, height: node.height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(node.color.toColor())
                    .shadow(radius: selected ? 8 : 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        connectFrom ? .blue :
                        (selected ? Color.accentColor :
                         (secondary ? Color.orange : .secondary.opacity(0.5))),
                        lineWidth: connectFrom ? 3 : (selected ? 2.5 : (secondary ? 2 : 1))
                    )
            )
            .animation(.spring(duration: 0.25), value: selected)
            .animation(.spring(duration: 0.25), value: connectFrom)
            .accessibilityLabel(Text("ノード: \(node.title)"))
    }
}

// MARK: - Straight line edge
struct EdgeView: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

// MARK: - Grid background
struct GridBackground: View {
    var zoom: CGFloat
    var pan: CGSize
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = max(20 * zoom, 12)
            let cols = Int(ceil(size.width / step))
            let rows = Int(ceil(size.height / step))

            let ox = pan.width.truncatingRemainder(dividingBy: step)
            let oy = pan.height.truncatingRemainder(dividingBy: step)

            var path = Path()
            for i in 0...cols {
                let x = CGFloat(i) * step + ox
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for j in 0...rows {
                let y = CGFloat(j) * step + oy
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
        .ignoresSafeArea()
    }
}

// MARK: - World content (edges + nodes) extracted to reduce type-checking load
struct WorldContent: View {
    @ObservedObject var vm: MindMapVM
    var zoom: CGFloat
    var pan: CGSize

    var body: some View {
        ZStack {
            // Edges first
            ForEach(vm.map.edges) { e in
                if let (fromPoint, toPoint) = vm.resolvedEndpoints(for: e) {
                    let isSel = vm.selectedEdgeID == e.id
                    EdgeView(from: fromPoint, to: toPoint)
                        .stroke(isSel ? Color.accentColor : .secondary, lineWidth: isSel ? 2.5 : 1.5)
                        .overlay(
                            // 透明の太線でヒット領域を広げ、クリックで選択
                            EdgeView(from: fromPoint, to: toPoint)
                                .stroke(Color.clear, lineWidth: 14)
                                .contentShape(EdgeView(from: fromPoint, to: toPoint))
                                .onTapGesture {
                                    vm.selectedEdgeID = e.id
                                    vm.selected = nil
                                }
                        )
                }
            }
            // Nodes
            ForEach(vm.map.nodes, id: \.id) { node in
                NodeView(
                    node: node,
                    selected: vm.selected == node.id,
                    secondary: vm.secondarySelected == node.id,
                    connectFrom: (vm.connectFrom == node.id) || (vm.eraseFrom == node.id)
                )
                .position(node.position.cgPoint)
                .onTapGesture(count: 2) { vm.editorTarget = node }
                .onTapGesture {
                    if vm.isEraseMode {
                        if vm.eraseFrom == nil {
                            vm.beginErase(from: node)
                        } else {
                            vm.finishErase(to: node)
                        }
                    } else if vm.isConnectMode {
                        if vm.connectFrom == nil {
                            vm.beginSimpleConnect(from: node)
                        } else {
                            vm.finishConnection(to: node)
                        }
                    } else {
                        // 二重選択の更新
                        vm.selectedEdgeID = nil
                        if vm.selected == nil {
                            vm.selected = node.id
                            vm.secondarySelected = nil
                        } else if vm.selected == node.id {
                            // 1つ目を再タップ → 単独選択のまま
                            vm.secondarySelected = nil
                        } else if vm.secondarySelected == nil {
                            vm.secondarySelected = node.id
                        } else {
                            // 3つ目を選んだら「新規を第1」に、セカンダリはクリア
                            vm.selected = node.id
                            vm.secondarySelected = nil
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            vm.beginDrag(node)
                            vm.drag(node, translation: value.translation)
                        }
                        .onEnded { _ in
                            vm.endDrag(node)
                        }
                )
            }
        }
        .scaleEffect(zoom)
        .offset(pan)
    }
}

// MARK: - Export-only view (to avoid heavy inline type-checking)
struct ExportView: View {
    var map: MindMap
    var zoom: CGFloat
    var pan: CGSize
    var showGrid: Bool

    var body: some View {
        ZStack {
            if showGrid { GridBackground(zoom: zoom, pan: pan) }
            ZStack {
                ForEach(map.edges) { e in
                    if let (a, b) = resolveEndpoints(edge: e, in: map.nodes) {
                        EdgeView(from: a, to: b)
                            .stroke(.secondary, lineWidth: 1.5)
                    }
                }
                ForEach(map.nodes, id: \.id) { node in
                    NodeView(node: node, selected: false, secondary: false, connectFrom: false)
                        .position(node.position.cgPoint)
                }
            }
            .scaleEffect(zoom)
            .offset(pan)
        }
    }
}


// MARK: - Node Editor
struct NodeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var node: MindNode
    var onSave: (MindNode) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("ノード名", text: $node.title)
                }
                Section("見た目") {
                    ColorPicker("色", selection: Binding(get: { node.color.toColor() }, set: { node.color = RGBA.from($0) }))
                    HStack {
                        Text("幅")
                        Slider(value: $node.width, in: 120...300)
                        Text("\(Int(node.width))")
                    }
                    HStack {
                        Text("高さ")
                        Slider(value: $node.height, in: 40...140)
                        Text("\(Int(node.height))")
                    }
                }
            }
            .navigationTitle("ノードの編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        #if os(macOS)
                        DispatchQueue.main.async {
                            NSColorPanel.shared.orderOut(nil)
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            onSave(node)
                            dismiss()
                        }
                        #else
                        onSave(node)
                        dismiss()
                        #endif
                    }
                }
            }
        }
    }
}

fileprivate func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { min(max(v, a), b) }
fileprivate func +(lhs: CGSize, rhs: CGSize) -> CGSize { CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height) }

#Preview {
    ContentView()
}


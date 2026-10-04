import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoFacePresentation: ViewModifier {
    let session: MobileSynologyPhotosSession
    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { session.faces?.draft }, set: { if $0 == nil { session.faces?.cancel() } }), onDismiss: { session.faces?.cancel() }) { draft in
            if let faces = session.faces { MobilePhotoFaceView(editor: faces, draft: draft) }
        }
    }
}

struct MobilePhotoFaceView: View {
    @Bindable var editor: MobilePhotoFaceModel
    let draft: MobilePhotoFaceModel.Draft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isDrawing = false
    @State private var newBounds: SynologyPhotoFaceBounds?
    @State private var dragOrigin: SynologyPhotoFaceBounds?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if editor.isLoading {
                    ProgressView(L10n.string("mobile.photos.edit.loading")).accessibilityIdentifier("mobile.photos.faces.loading")
                } else if let error = editor.error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { editor.load() } }
                } else if let image = editor.image {
                    GeometryReader { geometry in
                        if sizeClass == .regular && !typeSize.isAccessibilitySize && geometry.size.width >= 700 {
                            HStack(spacing: 0) {
                                canvasArea(image).frame(maxWidth: .infinity, maxHeight: .infinity)
                                Divider()
                                inspector.frame(width: min(360, geometry.size.width * 0.42))
                            }
                        } else {
                            VStack(spacing: 0) {
                                canvasArea(image).frame(height: min(360, max(180, geometry.size.height * 0.43)))
                                Divider()
                                inspector
                            }
                        }
                    }.disabled(!editor.editable)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(L10n.string("photos.faces.edit")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("photos.delete.cancel")) { editor.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("photos.faces.save")) { if editor.save() { dismiss() } }
                            .disabled(!editor.canSave).keyboardShortcut(.defaultAction).accessibilityIdentifier("mobile.photos.faces.save")
                    }
                }
        }
    }

    private func canvasArea(_ image: CGImage) -> some View {
        VStack(spacing: 4) {
            if typeSize.isAccessibilitySize { drawingButtons.labelStyle(.iconOnly) }
            else { drawingButtons }
            if isDrawing { Text(L10n.string("photos.faces.drawHint")).font(.caption).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    ForEach(editor.faces.filter { !$0.removed }) { face in box(face, size: size) }
                    if let bounds = newBounds {
                        Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .frame(width: bounds.width * size.width, height: bounds.height * size.height)
                            .offset(x: bounds.x * size.width, y: bounds.y * size.height).allowsHitTesting(false)
                    }
                    if isDrawing {
                        Color.clear.frame(width: size.width, height: size.height).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                newBounds = PhotoFaceEditing.square(from: value.startLocation, to: value.location, in: size)
                            }.onEnded { value in
                                if let bounds = PhotoFaceEditing.square(from: value.startLocation, to: value.location, in: size) { editor.add(bounds); isDrawing = false }
                                newBounds = nil
                            })
                    }
                }.frame(width: size.width, height: size.height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }.clipped().accessibilityLabel(L10n.string("photos.faces.canvas")).accessibilityIdentifier("mobile.photos.faces.canvas")
        }.padding(.vertical, 4)
    }
    private var drawingButtons: some View {
        HStack {
            Button { nameIsFocused = false; isDrawing.toggle(); newBounds = nil } label: {
                Label(L10n.string("photos.faces.add"), systemImage: "plus.viewfinder")
                    .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.bordered).tint(isDrawing ? .accentColor : .secondary)
                .accessibilityAddTraits(isDrawing ? .isSelected : []).accessibilityIdentifier("mobile.photos.faces.draw")
                .help(L10n.string("photos.faces.add"))
            Button { nameIsFocused = false; editor.addCentered(); isDrawing = false } label: {
                Label(L10n.string("photos.faces.addCentered"), systemImage: "plus.app")
                    .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.bordered).accessibilityIdentifier("mobile.photos.faces.centered")
                .help(L10n.string("photos.faces.addCentered"))
        }.padding(.horizontal)
    }
    private func box(_ face: PhotoFaceDraft, size: CGSize) -> some View {
        let selected = editor.selectedID == face.id
        return Rectangle().fill(Color.black.opacity(0.08))
            .overlay(Rectangle().strokeBorder(selected ? Color.accentColor : Color.white, lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topLeading) {
                // 图内标注保持比例，完整姓名仍由下方可缩放列表及辅助标签呈现。
                Text(name(face)).font(.system(size: 12)).lineLimit(1).padding(3).foregroundStyle(.white).background(.black.opacity(0.7)).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Color.accentColor, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .highPriorityGesture(DragGesture(minimumDistance: 3).onChanged { value in
                            if dragOrigin == nil { dragOrigin = face.bounds }
                            guard let origin = dragOrigin, size.width > 0, size.height > 0 else { return }
                            let side = min(max(10, max(origin.width * size.width + value.translation.width, origin.height * size.height + value.translation.height)),
                                           (1 - origin.x) * size.width, (1 - origin.y) * size.height)
                            editor.setBounds(.init(x: origin.x, y: origin.y, width: side / size.width, height: side / size.height), for: face.id)
                        }.onEnded { _ in dragOrigin = nil })
                        .accessibilityLabel(L10n.string("photos.faces.resize"))
                }
            }
            .frame(width: face.bounds.width * size.width, height: face.bounds.height * size.height)
            .offset(x: face.bounds.x * size.width, y: face.bounds.y * size.height)
            .onTapGesture { editor.selectedID = face.id }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                if dragOrigin == nil { dragOrigin = face.bounds }
                guard let origin = dragOrigin, size.width > 0, size.height > 0 else { return }
                editor.setBounds(.init(x: min(1 - origin.width, max(0, origin.x + value.translation.width / size.width)),
                                       y: min(1 - origin.height, max(0, origin.y + value.translation.height / size.height)),
                                       width: origin.width, height: origin.height), for: face.id)
            }.onEnded { _ in dragOrigin = nil })
            .accessibilityLabel(name(face)).accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : []).accessibilityAction { editor.selectedID = face.id }
    }
    private var inspector: some View {
        Form {
            if editor.faces.isEmpty { Text(L10n.string("mobile.photos.faces.emptyHint")).foregroundStyle(.secondary) }
            if let face = editor.selected {
                Section {
                    if face.removed {
                        Button(L10n.string("photos.faces.undoRemove")) { editor.undoRemove() }.accessibilityIdentifier("mobile.photos.faces.undo")
                    } else {
                        Picker(L10n.string("photos.people.destination"), selection: Binding(get: { face.personID }, set: { editor.setPerson($0) })) {
                            Text(L10n.string("photos.people.newPerson")).tag(0)
                            ForEach(editor.people) { person in Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name).tag(person.id) }
                        }.accessibilityIdentifier("mobile.photos.faces.person")
                        if face.personID == 0 {
                            TextField(L10n.string("photos.people.name"), text: Binding(get: { face.name }, set: { editor.setName($0) }))
                                .focused($nameIsFocused).submitLabel(.done).onSubmit { nameIsFocused = false }
                                .accessibilityIdentifier("mobile.photos.faces.name")
                        }
                        sliders(face)
                        Button(L10n.string("photos.faces.remove"), role: .destructive) { editor.removeSelected() }
                            .accessibilityIdentifier("mobile.photos.faces.remove")
                    }
                } footer: { Text(L10n.string("photos.faces.keepPhotos")) }
            }
            if !editor.faces.isEmpty {
                Section {
                    ForEach(editor.faces) { face in
                        Button { nameIsFocused = false; editor.selectedID = face.id; isDrawing = false } label: {
                            HStack {
                                Image(systemName: face.removed ? "minus.circle" : "person.crop.square")
                                Text(name(face)); Spacer()
                                if editor.selectedID == face.id { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.accessibilityAddTraits(editor.selectedID == face.id ? .isSelected : [])
                            .accessibilityIdentifier("mobile.photos.faces.row.\(face.id)")
                    }
                }
            }
            if editor.pendingChangeCount > 100 { Text(L10n.string("mobile.photos.faces.tooMany")).foregroundStyle(.secondary) }
            if let error = editor.saveError { Text(error).foregroundStyle(.red) }
        }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("mobile.photos.faces.inspector")
    }
    @ViewBuilder private func sliders(_ face: PhotoFaceDraft) -> some View {
        VStack(alignment: .leading) {
            Text(L10n.string("photos.faces.horizontal"))
            Slider(value: Binding(get: { face.bounds.x }, set: { value in var bounds = face.bounds; bounds.x = value; editor.setBounds(bounds, for: face.id) }),
                   in: 0...max(0.000001, 1 - face.bounds.width)) { Text(L10n.string("photos.faces.horizontal")) }
                .accessibilityIdentifier("mobile.photos.faces.horizontal")
        }
        VStack(alignment: .leading) {
            Text(L10n.string("photos.faces.vertical"))
            Slider(value: Binding(get: { face.bounds.y }, set: { value in var bounds = face.bounds; bounds.y = value; editor.setBounds(bounds, for: face.id) }),
                   in: 0...max(0.000001, 1 - face.bounds.height)) { Text(L10n.string("photos.faces.vertical")) }
                .accessibilityIdentifier("mobile.photos.faces.vertical")
        }
        if let image = editor.image {
            let maximum = max(1, min((1 - face.bounds.x) * Double(image.width), (1 - face.bounds.y) * Double(image.height)))
            VStack(alignment: .leading) {
                Text(L10n.string("photos.faces.size"))
                Slider(value: Binding(get: { min(maximum, max(1, face.bounds.width * Double(image.width))) }, set: { side in
                    var bounds = face.bounds; bounds.width = side / Double(image.width); bounds.height = side / Double(image.height)
                    editor.setBounds(bounds, for: face.id)
                }), in: 1...maximum) { Text(L10n.string("photos.faces.size")) }.accessibilityIdentifier("mobile.photos.faces.size")
            }
        }
    }
    private func name(_ face: PhotoFaceDraft) -> String { face.name.isEmpty ? L10n.string("photos.people.unnamed") : face.name }
}

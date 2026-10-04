import CryptoKit
import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 人物与主题恢复不保存名字或人脸图像；占位命令仅用于原操作的只读查询。
    public struct Recognition: Codable, Equatable, Sendable {
        public struct Collection: Codable, Equatable, Sendable {
            public let id: Int
            public let nameDigest: String
            public let itemCount: Int?
            public let space: SynologyPhotoSpace
            init(_ value: SynologyPhotoCollection) {
                id = value.id; nameDigest = Recognition.digest(value.name); itemCount = value.itemCount; space = value.space
            }
            var query: SynologyPhotoCollection { .init(id: id, name: nameDigest, itemCount: itemCount, space: space) }
            var isValid: Bool { id > 0 && Recognition.validDigest(nameDigest) && (itemCount.map { $0 >= 0 } ?? true) }
        }
        public struct Concept: Codable, Equatable, Sendable {
            public let collection: Collection
            public let visible: Bool
            public let threshold: Int?
            init(_ value: SynologyPhotoConceptVisibility) {
                collection = .init(value.concept); visible = value.isVisible; threshold = value.displayThreshold
            }
            var query: SynologyPhotoConceptVisibility { .init(concept: collection.query, isVisible: visible, displayThreshold: threshold) }
        }
        public struct Person: Codable, Equatable, Sendable {
            public let collection: Collection
            public let visible: Bool
            init(_ value: SynologyPhotoPersonVisibility) { collection = .init(value.person); visible = value.isVisible }
            var query: SynologyPhotoPersonVisibility { .init(person: collection.query, isVisible: visible) }
        }
        public struct Face: Codable, Equatable, Sendable {
            public let id: Int
            public let photoUnitID: Int
            init(_ value: SynologyPhotoFace) { id = value.id; photoUnitID = value.photo.id.unitID }
        }
        public struct Region: Codable, Equatable, Sendable {
            public let id, personID: Int
            public let nameDigest: String
            public let bounds: SynologyPhotoFaceBounds
            init(_ value: SynologyPhotoFaceRegion) {
                id = value.id; personID = value.personID; nameDigest = Recognition.digest(value.name); bounds = value.bounds
            }
            var query: SynologyPhotoFaceRegion { .init(id: id, personID: personID, name: nameDigest, bounds: bounds) }
            var isValid: Bool { id > 0 && personID >= 0 && Recognition.validDigest(nameDigest) && bounds.isValid }
        }
        public enum Change: Codable, Equatable, Sendable {
            case add(temporaryID: String, bounds: SynologyPhotoFaceBounds, person: Collection?, nameDigest: String, imageDigest: String)
            case remove(Region)
            case reassign(Region, person: Collection?, nameDigest: String)
            public var id: String {
                switch self {
                case .add(let temporaryID, _, _, _, _): "new-" + temporaryID
                case .remove(let region), .reassign(let region, _, _): "face-" + String(region.id)
                }
            }
            var query: SynologyPhotoFaceChange {
                switch self {
                case .add(let temporaryID, let bounds, let person, let name, _): .add(.init(temporaryID: temporaryID, bounds: bounds, person: person?.query, name: name, jpeg: Data()))
                case .remove(let region): .remove(region.query)
                case .reassign(let region, let person, let name): .reassign(region.query, person: person?.query, name: name)
                }
            }
            var isValid: Bool {
                switch self {
                case .add(let temporaryID, let bounds, let person, let name, let image):
                    !temporaryID.isEmpty && bounds.isValid && (person?.isValid ?? true) && Recognition.validDigest(name) && Recognition.validDigest(image)
                case .remove(let region): region.isValid
                case .reassign(let region, let person, let name): region.isValid && (person?.isValid ?? true) && Recognition.validDigest(name)
                }
            }
        }
        public enum Intent: Codable, Equatable, Sendable {
            case rename(Collection, nameDigest: String)
            case merge(Collection, sources: [Collection], nameDigest: String)
            case personCover(Collection)
            case removeFaces(Collection, faces: [Face])
            case reassignFaces(Collection, faces: [Face], target: Collection?, nameDigest: String)
            case peopleVisibility([Person], visible: Bool)
            case conceptCover(Concept)
            case removeConceptItems(Concept)
            case conceptVisibility([Concept], visible: Bool)
            case manual([Change])
        }
        public let space: SynologyPhotoSpace
        public let targets: [PhotoEdit.Target]
        public let intent: Intent
        public var personPhotoIDs: Set<Int>?
        public var personReceiptID: Int?
        public var personReceiptNameDigest: String?
        public var personCoverID: Int?
        public var visibilityAcknowledged = false
        public var conceptRemovalAcknowledged = false
        public var manualAddAttempted = false
        public var manualAddAcknowledged = false
        public var manualAttempted: Set<String> = []
        public var manualThumbnailAttempted: Set<Int> = []
        public var manualNewIDs: [String: Int] = [:]
        public var manualPersonIDs: [String: Int] = [:]
        public var manualUploaded: Set<Int> = []
        public var manualAcknowledged: Set<String> = []
        public var manualKnownFailures: Set<String> = []

        public init(mutation: SynologyPhotosMutation) throws {
            space = mutation.space; targets = try mutation.photos.map { try .init($0, valueDigest: nil) }
            switch mutation {
            case .renamePerson(let person, let name): intent = .rename(.init(person), nameDigest: Self.digest(name))
            case .mergePeople(let target, let sources, let name): intent = .merge(.init(target), sources: sources.map(Collection.init), nameDigest: Self.digest(name))
            case .setPersonCover(let person, _): intent = .personCover(.init(person))
            case .removePersonFaces(let person, let faces): intent = .removeFaces(.init(person), faces: faces.map(Face.init))
            case .reassignPersonFaces(let person, let faces, let target, let name): intent = .reassignFaces(.init(person), faces: faces.map(Face.init), target: target.map(Collection.init), nameDigest: Self.digest(name))
            case .setPeopleVisibility(let people, let visible): intent = .peopleVisibility(people.map(Person.init), visible: visible)
            case .setConceptCover(let concept, _): intent = .conceptCover(.init(concept))
            case .removeConceptItems(let concept, _): intent = .removeConceptItems(.init(concept))
            case .setConceptVisibility(let concepts, let visible): intent = .conceptVisibility(concepts.map(Concept.init), visible: visible)
            case .editPhotoFaces(_, let changes):
                intent = .manual(changes.map { change in
                    switch change {
                    case .add(let value): .add(temporaryID: value.temporaryID, bounds: value.bounds, person: value.person.map(Collection.init), nameDigest: Self.digest(value.name), imageDigest: Self.digest(value.jpeg))
                    case .remove(let value): .remove(.init(value))
                    case .reassign(let value, let person, let name): .reassign(.init(value), person: person.map(Collection.init), nameDigest: Self.digest(name))
                    }
                })
            default: throw CocoaError(.coderInvalidValue)
            }
        }
        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard let other = try? Self(mutation: mutation) else { return false }
            return space == other.space && targets == other.targets && intent == other.intent
        }
        public static func digest(_ name: String) -> String { digest(Data(name.utf8)) }
        public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        private static func validDigest(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func reviewMutation(profileID: UUID) throws -> SynologyPhotosMutation {
            guard targets.count <= 100, Set(targets.map(\.id)).count == targets.count,
                  targets.allSatisfy({ target in target.profileID == profileID && target.space == space && target.unitID > 0 && target.folderID > 0 && Self.validDigest(target.identityDigest) && target.valueDigest == nil &&
                      (target.albumID.map { $0 > 0 && (target.ownerID.map { $0 >= 0 } ?? false) } ?? (target.ownerID == nil && target.providerID == nil)) && (target.providerID.map { $0 > 0 } ?? true) }),
                  personReceiptID.map({ $0 > 0 }) ?? true,
                  personReceiptNameDigest.map(Self.validDigest) ?? true,
                  (personReceiptID == nil) == (personReceiptNameDigest == nil),
                  personCoverID.map({ $0 > 0 }) ?? true,
                  personPhotoIDs?.allSatisfy({ $0 > 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
            let photos = targets.map(\.queryPhoto)
            let command: SynologyPhotosMutation
            let collections: [Collection]
            var changes: [Change] = []
            switch intent {
            case .rename(let person, let name):
                guard photos.isEmpty, Self.validDigest(name) else { throw CocoaError(.coderReadCorrupt) }
                collections = [person]; command = .renamePerson(person.query, name: name)
            case .merge(let person, let sources, let name):
                guard photos.isEmpty, !sources.isEmpty, Self.validDigest(name), Set(([person] + sources).map(\.id)).count == sources.count + 1 else { throw CocoaError(.coderReadCorrupt) }
                collections = [person] + sources; command = .mergePeople(target: person.query, sources: sources.map(\.query), name: name)
            case .personCover(let person):
                guard let photo = photos.first, photos.count == 1 else { throw CocoaError(.coderReadCorrupt) }
                collections = [person]; command = .setPersonCover(person: person.query, photo: photo)
            case .removeFaces(let person, let faces), .reassignFaces(let person, let faces, _, _):
                guard !faces.isEmpty, Set(faces.map(\.id)).count == faces.count,
                      faces.allSatisfy({ $0.id > 0 }),
                      Set(faces.map(\.photoUnitID)) == Set(targets.map(\.unitID)) else { throw CocoaError(.coderReadCorrupt) }
                let resolved = try faces.map { face -> SynologyPhotoFace in
                    guard let photo = photos.first(where: { $0.id.unitID == face.photoUnitID }) else { throw CocoaError(.coderReadCorrupt) }
                    return .init(id: face.id, personID: person.id, photo: photo)
                }
                if case .reassignFaces(_, _, let target, let name) = intent {
                    guard Self.validDigest(name), target?.id != person.id else { throw CocoaError(.coderReadCorrupt) }
                    collections = [person] + (target.map { [$0] } ?? [])
                    command = .reassignPersonFaces(person: person.query, faces: resolved, target: target?.query, name: name)
                } else { collections = [person]; command = .removePersonFaces(person: person.query, faces: resolved) }
            case .peopleVisibility(let people, let visible):
                guard photos.isEmpty, !people.isEmpty, people.count <= 100, Set(people.map { $0.collection.id }).count == people.count else { throw CocoaError(.coderReadCorrupt) }
                collections = people.map(\.collection); command = .setPeopleVisibility(people.map(\.query), visible: visible)
            case .conceptCover(let concept), .removeConceptItems(let concept):
                guard !photos.isEmpty, concept.threshold.map({ $0 >= 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
                collections = [concept.collection]
                if case .conceptCover = intent {
                    guard photos.count == 1 else { throw CocoaError(.coderReadCorrupt) }
                    command = .setConceptCover(concept: concept.query, photo: photos[0])
                } else { command = .removeConceptItems(concept: concept.query, photos: photos) }
            case .conceptVisibility(let concepts, let visible):
                guard photos.isEmpty, !concepts.isEmpty, Set(concepts.map { $0.collection.id }).count == concepts.count,
                      concepts.allSatisfy({ $0.threshold.map { $0 >= 0 } ?? true }) else { throw CocoaError(.coderReadCorrupt) }
                collections = concepts.map(\.collection); command = .setConceptVisibility(concepts.map(\.query), visible: visible)
            case .manual(let values):
                guard let photo = photos.first, photos.count == 1, !values.isEmpty, values.count <= 100, values.allSatisfy(\.isValid),
                      Set(values.map(\.id)).count == values.count else { throw CocoaError(.coderReadCorrupt) }
                changes = values
                collections = values.compactMap { change in
                    switch change { case .add(_, _, let person, _, _), .reassign(_, let person, _): person; default: nil }
                }
                command = .editPhotoFaces(photo: photo, changes: values.map(\.query))
            }
            guard collections.allSatisfy({ $0.isValid && $0.space == space }) else { throw CocoaError(.coderReadCorrupt) }
            let addKeys = Set(changes.compactMap { change -> String? in if case .add(let id, _, _, _, _) = change { return id }; return nil })
            let nonAddIDs = Set(changes.filter { if case .add = $0 { return false }; return true }.map(\.id))
            let reassignIDs = Set(changes.filter { if case .reassign = $0 { return true }; return false }.map(\.id))
            let changeIDs = Set(changes.map(\.id)), returnedIDs = Set(manualNewIDs.values)
            guard (!manualAddAttempted || !addKeys.isEmpty), (!manualAddAcknowledged || manualAddAttempted),
                  Set(manualNewIDs.keys).isSubset(of: addKeys), returnedIDs.count == manualNewIDs.count, returnedIDs.allSatisfy({ $0 > 0 }),
                  manualNewIDs.isEmpty || manualAddAcknowledged,
                  manualAttempted.isSubset(of: nonAddIDs), manualThumbnailAttempted.isSubset(of: returnedIDs),
                  manualUploaded.isSubset(of: manualThumbnailAttempted), manualAcknowledged.isSubset(of: changeIDs), manualKnownFailures.isSubset(of: changeIDs),
                  manualAcknowledged.isDisjoint(with: manualKnownFailures), Set(manualPersonIDs.keys).isSubset(of: reassignIDs.intersection(manualAttempted)), manualPersonIDs.values.allSatisfy({ $0 > 0 }),
                  manualAcknowledged.intersection(nonAddIDs).isSubset(of: manualAttempted),
                  manualAcknowledged.subtracting(nonAddIDs).allSatisfy({ id in manualNewIDs[String(id.dropFirst(4))].map(manualUploaded.contains) == true }) else { throw CocoaError(.coderReadCorrupt) }
            // 必须先完成全部新增及缩略图，才允许改变旧框。
            if !manualAttempted.isEmpty, !addKeys.isEmpty {
                guard manualAddAcknowledged, Set(manualNewIDs.keys) == addKeys, returnedIDs.isSubset(of: manualUploaded) else { throw CocoaError(.coderReadCorrupt) }
            }
            return command
        }
    }
}

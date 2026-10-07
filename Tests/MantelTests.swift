import Security
import XCTest
@testable import Mantel

final class MantelTests: XCTestCase {
    func testFramePermissionBits() {
        let readCreate = Frame(id: "1", displayName: "Grandma", remotePath: "/Grandma", permissions: 5)
        XCTAssertTrue(readCreate.canUpload)
        XCTAssertFalse(readCreate.canDelete)

        let admin = Frame(id: "2", displayName: "Den", remotePath: "/Den", permissions: 1 + 4 + 8)
        XCTAssertTrue(admin.canUpload)
        XCTAssertTrue(admin.canDelete)

        let readOnly = Frame(id: "3", displayName: "RO", remotePath: "/RO", permissions: 1)
        XCTAssertFalse(readOnly.canUpload)
    }

    func testUploadCollectionURLEncodesSegments() {
        let frame = Frame(id: "1", displayName: "Beach Trip",
                          remotePath: "/Beach Trip/2026", permissions: 5)
        let url = frame.uploadCollectionURL(baseURL: Config.baseURL, userId: "bob")
        XCTAssertEqual(
            url.absoluteString,
            Config.baseURL.absoluteString + "/remote.php/dav/files/bob/Beach%20Trip/2026"
        )
        XCTAssertTrue(url.absoluteString.hasSuffix("/bob/Beach%20Trip/2026"))
    }

    func testChunkNameIsZeroPaddedAndSortable() {
        XCTAssertEqual(UploadCoordinator.chunkName(0), "000000000000000")
        XCTAssertEqual(UploadCoordinator.chunkName(42), "000000000000042")
        XCTAssertTrue(UploadCoordinator.chunkName(9) < UploadCoordinator.chunkName(10))
    }

    func testWebDAVStatusClassification() {
        XCTAssertEqual(NextcloudClient.classify(201), .success)
        XCTAssertEqual(NextcloudClient.classify(204), .success)
        XCTAssertEqual(NextcloudClient.classify(401), .unauthorized)
        XCTAssertEqual(NextcloudClient.classify(403), .forbidden)
        XCTAssertEqual(NextcloudClient.classify(404), .destinationMissing)
        XCTAssertEqual(NextcloudClient.classify(409), .destinationMissing)
        XCTAssertEqual(NextcloudClient.classify(412), .conflict)
        XCTAssertEqual(NextcloudClient.classify(507), .quotaExceeded)
        XCTAssertEqual(NextcloudClient.classify(429), .serverError(429))
        XCTAssertEqual(NextcloudClient.classify(400), .rejected(400))
        XCTAssertEqual(NextcloudClient.classify(500), .serverError(500))
    }

    func testPropfindParserSkipsCollectionAndFolders() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/bob/Grandma/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/bob/Grandma/IMG_1.jpg</d:href>
            <d:propstat><d:prop>
              <d:resourcetype/>
              <d:getcontenttype>image/jpeg</d:getcontenttype>
              <d:getcontentlength>2048</d:getcontentlength>
              <d:getlastmodified>Sat, 06 Sep 2026 12:34:56 GMT</d:getlastmodified>
              <oc:fileid>12345</oc:fileid>
              <nc:has-preview>true</nc:has-preview>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/bob/Grandma/Subfolder/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
        </d:multistatus>
        """
        let items = try XCTUnwrap(try? PropfindParser(
            selfSegments: hrefSegments("/remote.php/dav/files/bob/Grandma/")
        ).parse(Data(xml.utf8)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "IMG_1.jpg")
        XCTAssertEqual(items.first?.fileID, "12345")
        XCTAssertTrue(items.first?.hasPreview ?? false)
        XCTAssertEqual(items.first?.sizeBytes, 2048)
    }

    func testUploadErrorCopyMapping() {
        XCTAssertTrue(Messages.uploadError(.quota).contains("storage"))
        XCTAssertTrue(Messages.uploadError(.auth).contains("sign in"))
        XCTAssertEqual(Messages.uploadError(nil), "This one didn't finish.")
    }

    func testRemoteNamesSanitiseAndNumber() {
        XCTAssertEqual(RemoteNames.safe("a/b/IMG.jpg"), "IMG.jpg")
        XCTAssertEqual(RemoteNames.safe("..", fallbackStamp: 7).isEmpty, false)
        XCTAssertEqual(RemoteNames.numbered("IMG.jpg", 0), "IMG.jpg")
        XCTAssertEqual(RemoteNames.numbered("IMG.jpg", 2), "IMG (2).jpg")
    }

    func testConfigAllowsOnlyBareHttpsOrigins() {
        let host = Config.host
        XCTAssertTrue(Config.isAllowed("https://\(host)"))
        XCTAssertFalse(Config.isAllowed("http://\(host)"))
        XCTAssertFalse(Config.isAllowed("https://\(host)/sub"))
        XCTAssertFalse(Config.isAllowed("https://user@\(host)"))
        XCTAssertFalse(Config.isAllowed("https://evil.example.org"))
    }

    func testConfigRejectsNonDefaultPorts() {
        let host = Config.host
        XCTAssertFalse(Config.isAllowed("https://\(host):8443"))
        XCTAssertTrue(Config.isAllowed("https://\(host):443"))
    }

    func testRemoteNamesLocalFileNameDeduplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = RemoteNames.localFileName("IMG 1.jpg", in: dir)
        XCTAssertEqual(first, "IMG_1.jpg")
        FileManager.default.createFile(atPath: dir.appendingPathComponent(first).path, contents: Data())
        let second = RemoteNames.localFileName("IMG 1.jpg", in: dir)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix(".jpg"))
    }

    func testGalleryFilterAndSort() {
        func item(_ name: String, _ mime: String, size: Int64, mod: TimeInterval) -> RemoteItem {
            RemoteItem(
                href: "/x/\(name)", name: name, isDirectory: false, contentType: mime,
                sizeBytes: size, lastModified: Date(timeIntervalSince1970: mod),
                fileID: name, hasPreview: true, uploadedAt: nil
            )
        }
        let items = [
            item("b.jpg", "image/jpeg", size: 5, mod: 10),
            item("a.mp4", "video/mp4", size: 50, mod: 20),
        ]
        XCTAssertEqual(items.filteredAndSorted(.videos, .name).map(\.name), ["a.mp4"])
        XCTAssertEqual(items.filteredAndSorted(.all, .largest).first?.name, "a.mp4")
        XCTAssertEqual(items.filteredAndSorted(.all, .oldest).first?.name, "b.jpg")
    }

    func testCredentialsDescriptionIsRedacted() {
        let creds = Credentials(username: "bob", appPassword: "s3cret")
        XCTAssertFalse("\(creds)".contains("s3cret"))
    }

    // MARK: - UploadStore

    private func record(_ id: String) -> UploadRecord {
        var record = UploadRecord(
            id: id, batchID: "b", displayName: "\(id).jpg", destinationLabel: "Frame",
            mimeType: "image/jpeg", baseURL: "https://x.example.com",
            collectionURL: "https://x.example.com/remote.php/dav/files/bob/Frame",
            stagedPath: "/tmp/\(id)", sizeBytes: 1, mtimeEpochSeconds: nil, mode: .simple
        )
        record.attempt = 0
        return record
    }

    @MainActor
    func testUploadStoreKeepsRecordsWrittenByAnotherProcess() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("records-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let app = UploadStore(fileURL: url)
        let extensionProcess = UploadStore(fileURL: url)
        // `reload()` drains a store's queued writes, so each lands before the next process writes.
        app.upsert(record("a"))
        app.reload()
        extensionProcess.upsert(record("b")) // the app's in-memory list doesn't know "b"
        extensionProcess.reload()

        // The app mutates "a" from its stale snapshot — "b" must survive the write.
        app.mutate(id: "a") { $0.attempt = 3 }
        app.reload()
        XCTAssertEqual(Set(app.records.map(\.id)), ["a", "b"])
        XCTAssertEqual(app.record(id: "a")?.attempt, 3)
    }

    @MainActor
    func testUploadStoreSkipsOneBadRecordInsteadOfDroppingAll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("records-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let good = try JSONEncoder().encode([record("good")])
        var array = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [[String: Any]])
        array.append(["id": "broken"])
        try JSONSerialization.data(withJSONObject: array).write(to: url)

        let store = UploadStore(fileURL: url)
        XCTAssertEqual(store.records.map(\.id), ["good"])
    }

    @MainActor
    func testUploadStoreDecodesRecordsFromOlderBuilds() throws {
        let encoded = try JSONEncoder().encode(record("old"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["attempt", "nameIndex", "totalChunks", "completedChunks", "uploadID", "errorKind"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(
            UploadRecord.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.attempt, 0)
        XCTAssertTrue(decoded.completedChunks.isEmpty)
    }

    func testCredentialStoreRoundTrip() throws {
        // Unsigned builds (CI: CODE_SIGNING_ALLOWED=NO) have no keychain entitlement.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.eeinspired.mantel.tests.probe",
            kSecValueData as String: Data("x".utf8),
        ]
        let probeStatus = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        try XCTSkipIf(probeStatus == errSecMissingEntitlement, "keychain unavailable in unsigned test host")

        let store = KeychainCredentialStore(accessGroup: nil)
        let creds = Credentials(username: "test-\(UUID().uuidString)", appPassword: "pw", userId: "uid")
        defer { store.clear() }
        store.clear()
        XCTAssertTrue(store.save(creds))
        XCTAssertEqual(store.load(), creds)
        XCTAssertTrue(store.save(Credentials(username: creds.username, appPassword: "pw2", userId: "uid")))
        XCTAssertEqual(store.load()?.appPassword, "pw2")
    }

    func testStagingFailureMessages() {
        XCTAssertTrue(Messages.stagingFailure(.tooLarge).contains("too large"))
        XCTAssertTrue(Messages.stagingFailure(.noSpace).contains("space"))
        XCTAssertEqual(Messages.stagingFailure(nil), Messages.nothingStaged)
    }
}

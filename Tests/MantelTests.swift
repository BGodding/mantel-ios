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
        let url = frame.uploadCollectionURL(username: "bob")
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
        XCTAssertEqual(NextcloudClient.classify(507), .quotaExceeded)
        XCTAssertEqual(NextcloudClient.classify(500), .serverError(500))
    }

    func testPropfindParserSkipsCollectionAndFolders() {
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
        let items = PropfindParser(selfPath: "/remote.php/dav/files/bob/Grandma/")
            .parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "IMG_1.jpg")
        XCTAssertEqual(items.first?.fileID, "12345")
        XCTAssertTrue(items.first?.hasPreview ?? false)
        XCTAssertEqual(items.first?.sizeBytes, 2048)
    }

    func testUploadErrorCopyMapping() {
        XCTAssertTrue(Messages.uploadError("quota").contains("storage"))
        XCTAssertTrue(Messages.uploadError("auth").contains("sign in"))
        XCTAssertEqual(Messages.uploadError("totally-unknown"), "This one didn't finish.")
    }
}

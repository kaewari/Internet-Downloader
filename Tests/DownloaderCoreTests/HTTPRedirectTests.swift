import XCTest
@testable import DownloaderCore

final class HTTPRedirectIntegrationTests: XCTestCase {
    func testActualURLSessionRedirectLoopMissingLocationCrossOriginAndHTML() async throws {
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = ["Tests/Fixtures/http_redirect.py"]; server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate() }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
        let port = try XCTUnwrap(Int(String(decoding:line,as:UTF8.self)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        func download(_ route:String, name:String) async throws -> URL {
            let task = DownloadTask(url:URL(string:"http://127.0.0.1:\(port)\(route)")!,filename:name,destinationFolder:root,segmentsCount:1,cookies:"private=session")
            let segments = HTTPRangeDownloader.calculateSegments(taskId:task.id,totalBytes:-1,segmentCount:1,acceptRanges:false)
            try await HTTPRangeDownloader().download(task:task,segments:segments,onProgress:{_,_ in},onSegmentUpdate:{_ in})
            return task.finalFilePath
        }
        let file = try await download("/redirect",name:"valid.bin")
        XCTAssertEqual(try Data(contentsOf:file),Data("file-bytes-verified".utf8))
        let cross = try await download("/cross",name:"inspect.bin")
        let headers = try JSONSerialization.jsonObject(with:Data(contentsOf:cross)) as! [String:Any]
        XCTAssertTrue(headers["cookie"] is NSNull); XCTAssertTrue(headers["authorization"] is NSNull)
        for route in ["/loop","/missing","/html","/html-hidden"] {
            do { _ = try await download(route,name:"bad-\(route.dropFirst()).mp4"); XCTFail("Accepted \(route)") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
}

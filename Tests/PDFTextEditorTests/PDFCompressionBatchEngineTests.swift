import Foundation
import PDFKit
import Testing
@testable import PDFTextEditor

struct PDFCompressionBatchEngineTests {
    @Test("Batch compression continues after a failed file and skips larger output")
    func continuesAndDoesNotSaveLargerOutput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let success = try fixture.makePDF("first.pdf")
        let failure = try fixture.makePDF("fail.pdf")
        let larger = try fixture.makePDF("larger.pdf")
        let last = try fixture.makePDF("last.pdf")
        let inputs = [success, failure, larger, last]
        let originals = try inputs.map { try Data(contentsOf: $0) }
        let helper = try fixture.makeHelper("""
            #!/bin/sh
            case "$1" in
              */fail.pdf) echo "intentional helper failure" >&2; exit 9 ;;
              */larger.pdf) cp "$1" "$2" || exit 1; printf '%1024s' '' >> "$2" ;;
              *) cp "$1" "$2" ;;
            esac
            """)

        let results = PDFCompressionBatchEngine.run(
            sourceURLs: inputs,
            outputDirectory: fixture.outputDirectory,
            filenameSuffix: "-compressed",
            quality: 95,
            helperURL: helper
        )

        #expect(results.map(\.sourceURL) == inputs)
        #expect(results.map(\.status) == [.succeeded, .failed, .largerThanOriginal, .succeeded])
        #expect(results[0].sourceBytes == Int64(originals[0].count))
        #expect(results[0].outputBytes == Int64(originals[0].count))
        #expect(results[0].outputURL?.lastPathComponent == "first-compressed.pdf")
        #expect(results[1].sourceBytes == Int64(originals[1].count))
        #expect(results[1].outputBytes == nil)
        #expect(results[2].sourceBytes == Int64(originals[2].count))
        #expect((results[2].outputBytes ?? 0) > Int64(originals[2].count))
        #expect(results[2].outputURL == nil)
        #expect(results[3].outputURL?.lastPathComponent == "last-compressed.pdf")
        #expect(try inputs.map { try Data(contentsOf: $0) } == originals)
        #expect(FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent("first-compressed.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent("larger-compressed.pdf").path))
        #expect(FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent("last-compressed.pdf").path))
    }

    @Test("Batch naming avoids existing files and duplicate source basenames")
    func namingAvoidsOverwritesAndCollisions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstDirectory = fixture.root.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = fixture.root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = try fixture.makePDF("duplicate.pdf", in: firstDirectory)
        let second = try fixture.makePDF("duplicate.pdf", in: secondDirectory)
        let existing = fixture.outputDirectory.appendingPathComponent("duplicate-packed.pdf")
        let existingBytes = Data("keep this file".utf8)
        try existingBytes.write(to: existing)
        let helper = try fixture.makeHelper("#!/bin/sh\ncp \"$1\" \"$2\"\n")

        let results = PDFCompressionBatchEngine.run(
            sourceURLs: [first, second],
            outputDirectory: fixture.outputDirectory,
            filenameSuffix: "-packed",
            quality: 98,
            helperURL: helper
        )

        #expect(results.map(\.status) == [.succeeded, .succeeded])
        #expect(results[0].outputURL?.lastPathComponent == "duplicate-packed-2.pdf")
        #expect(results[1].outputURL?.lastPathComponent == "duplicate-packed-3.pdf")
        #expect(try Data(contentsOf: existing) == existingBytes)
    }

    @Test("Cancelling the active helper marks the rest of the queue cancelled")
    func cancellationStopsQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.makePDF("slow.pdf")
        let second = try fixture.makePDF("after.pdf")
        let helper = try fixture.makeHelper("#!/bin/sh\nexec /bin/sleep 30\n")
        let worker = Task.detached {
            PDFCompressionBatchEngine.run(
                sourceURLs: [first, second],
                outputDirectory: fixture.outputDirectory,
                filenameSuffix: "-compressed",
                quality: 95,
                helperURL: helper,
                cancellationRequested: { Task.isCancelled }
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        worker.cancel()
        let results = await worker.value

        #expect(results.map(\.status) == [.cancelled, .cancelled])
        #expect(!FileManager.default.fileExists(atPath: fixture.outputDirectory.appendingPathComponent("slow-compressed.pdf").path))
    }

    private struct Fixture: Sendable {
        let root: URL
        let outputDirectory: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdf-compression-batch-test-\(UUID().uuidString)", isDirectory: true)
            outputDirectory = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        func makePDF(_ name: String, in directory: URL? = nil) throws -> URL {
            let destinationDirectory = directory ?? root
            let destination = destinationDirectory.appendingPathComponent(name)
            let generated = RawPDFBuilder.singlePagePDF(
                pageBounds: CGRect(x: 0, y: 0, width: 200, height: 300),
                contentStream: ""
            )
            defer { try? FileManager.default.removeItem(at: generated) }
            try FileManager.default.copyItem(at: generated, to: destination)
            return destination
        }

        func makeHelper(_ script: String) throws -> URL {
            let helper = root.appendingPathComponent("pdf-compress-helper-\(UUID().uuidString)")
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            return helper
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

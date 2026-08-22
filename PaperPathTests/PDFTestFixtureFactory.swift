import Foundation
import UIKit

enum PDFTestFixtureFactory {
    struct EmbeddedAttachment {
        let fileName: String
        let data: Data
        let declaredSize: Int?

        init(
            fileName: String,
            data: Data,
            declaredSize: Int? = nil
        ) {
            self.fileName = fileName
            self.data = data
            self.declaredSize = declaredSize
        }
    }

    private struct PDFObject {
        let number: Int
        let dictionary: String
        let stream: Data?

        init(
            _ number: Int,
            _ dictionary: String,
            stream: Data? = nil
        ) {
            self.number = number
            self.dictionary = dictionary
            self.stream = stream
        }
    }

    static func makeSparsePDF(
        at url: URL,
        paddingBytes: Int64
    ) throws {
        precondition(paddingBytes >= 0)
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offsets: [Int: UInt64] = [:]

        func append(_ value: String) throws {
            try handle.write(contentsOf: Data(value.utf8))
        }

        func appendObject(
            _ number: Int,
            dictionary: String,
            stream: Data? = nil
        ) throws {
            offsets[number] = try handle.offset()
            try append("\(number) 0 obj\n\(dictionary)")
            if let stream {
                try append("\nstream\n")
                try handle.write(contentsOf: stream)
                try append("\nendstream")
            }
            try append("\nendobj\n")
        }

        try append("%PDF-1.7\n")
        try appendObject(
            1,
            dictionary: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        try appendObject(
            2,
            dictionary: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        try appendObject(
            3,
            dictionary: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>
            """
        )
        let pageCommands = Data(
            "0 0 0 rg\n72 620 220 36 re f\n".utf8
        )
        try appendObject(
            4,
            dictionary: "<< /Length \(pageCommands.count) >>",
            stream: pageCommands
        )

        offsets[5] = try handle.offset()
        try append(
            "5 0 obj\n<< /Length \(paddingBytes) >>\nstream\n"
        )
        let streamStart = try handle.offset()
        try handle.seek(
            toOffset: streamStart + UInt64(paddingBytes)
        )
        try append("\nendstream\nendobj\n")

        let xrefOffset = try handle.offset()
        try append("xref\n0 6\n")
        try append("0000000000 65535 f \n")
        for number in 1...5 {
            try append(
                String(
                    format: "%010llu 00000 n \n",
                    offsets[number] ?? 0
                )
            )
        }
        try append(
            """
            trailer
            << /Size 6 /Root 1 0 R >>
            startxref
            \(xrefOffset)
            %%EOF

            """
        )
    }

    static func makeTextPDF(
        at url: URL,
        pageCount: Int
    ) throws {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: 612,
            height: 792
        )
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for pageIndex in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                "Fixture page \(pageIndex + 1) amount \(pageIndex * 10)"
                    .draw(
                        in: CGRect(
                            x: 56,
                            y: 72,
                            width: 500,
                            height: 200
                        ),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 18),
                            .foregroundColor: UIColor.black
                        ]
                    )
            }
        }
    }

    static func makeMixedGeometryPDF(at url: URL) throws {
        let pageDefinitions: [
            (
                page: Int,
                content: Int,
                mediaBox: String,
                rotation: Int,
                text: String,
                textY: Int
            )
        ] = [
            (3, 4, "0 0 612 792", 0, "Portrait amount 100", 700),
            (5, 6, "0 0 792 612", 0, "Landscape amount 200", 520),
            (7, 8, "0 0 612 792", 90, "Rotated amount 300", 700),
            (9, 10, "0 0 240 1800", 0, "Tall amount 400", 1700)
        ]
        var objects: [PDFObject] = [
            PDFObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(
                2,
                "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R 9 0 R] /Count 4 >>"
            ),
            PDFObject(
                11,
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            )
        ]
        for definition in pageDefinitions {
            let rotation = definition.rotation == 0
                ? ""
                : " /Rotate \(definition.rotation)"
            objects.append(
                PDFObject(
                    definition.page,
                    """
                    << /Type /Page /Parent 2 0 R /MediaBox [\(definition.mediaBox)] /CropBox [\(definition.mediaBox)]\(rotation) /Resources << /Font << /F1 11 0 R >> >> /Contents \(definition.content) 0 R >>
                    """
                )
            )
            let commands = Data(
                """
                BT
                /F1 18 Tf
                24 \(definition.textY) Td
                (\(definition.text)) Tj
                ET

                """.utf8
            )
            objects.append(
                PDFObject(
                    definition.content,
                    "<< /Length \(commands.count) >>",
                    stream: commands
                )
            )
        }
        try writeClassicPDF(
            objects: objects,
            rootObjectNumber: 1,
            to: url
        )
    }

    static func makeStructurePDF(
        at url: URL,
        attachment: EmbeddedAttachment
    ) throws {
        let pageCommands = Data(
            "0 0 0 rg\n72 620 180 32 re f\n".utf8
        )
        let declaredSize = attachment.declaredSize
            ?? attachment.data.count
        let fileNameHex = hexString(attachment.fileName)
        let objects = [
            PDFObject(
                1,
                """
                << /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 7 0 R >> /PageLabels << /Nums [0 << /S /r >>] >> >>
                """
            ),
            PDFObject(
                2,
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
            ),
            PDFObject(
                3,
                """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << >> /Contents 4 0 R /Annots [6 0 R] >>
                """
            ),
            PDFObject(
                4,
                "<< /Length \(pageCommands.count) >>",
                stream: pageCommands
            ),
            PDFObject(
                5,
                """
                << /Type /Filespec /F <\(fileNameHex)> /UF <\(fileNameHex)> /Desc (Fixture attachment) /EF << /F 8 0 R /UF 8 0 R >> >>
                """
            ),
            PDFObject(
                6,
                """
                << /Type /Annot /Subtype /Polygon /Rect [90 540 240 660] /Contents (Read only polygon) /C [1 0 0] /BS << /W 2 >> >>
                """
            ),
            PDFObject(
                7,
                "<< /Names [<\(fileNameHex)> 5 0 R] >>"
            ),
            PDFObject(
                8,
                """
                << /Type /EmbeddedFile /Subtype /text#2Fplain /Params << /Size \(declaredSize) >> /Length \(attachment.data.count) >>
                """,
                stream: attachment.data
            )
        ]
        try writeClassicPDF(
            objects: objects,
            rootObjectNumber: 1,
            to: url
        )
    }

    static func makeAcroFormAutomationPDF(
        at url: URL,
        customCalculationScript: String? = nil
    ) throws {
        let calculation = customCalculationScript
            ?? """
            AFSimple_Calculate("SUM", new Array("Amount A", "Amount B"));
            """
        let format = #"AFNumber_Format(2, 0, 0, 0, "$", true);"#
        let validation = "AFRange_Validate(true, 0, true, 100);"
        let pageCommands = Data(
            "0 0 0 rg\n72 650 240 24 re f\n".utf8
        )
        let objects = [
            PDFObject(
                1,
                "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>"
            ),
            PDFObject(
                2,
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
            ),
            PDFObject(
                3,
                """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << /Font << /Helv 9 0 R >> >> /Contents 4 0 R /Annots [6 0 R 7 0 R 8 0 R] >>
                """
            ),
            PDFObject(
                4,
                "<< /Length \(pageCommands.count) >>",
                stream: pageCommands
            ),
            PDFObject(
                5,
                """
                << /Fields [6 0 R 7 0 R 8 0 R] /NeedAppearances true /DR << /Font << /Helv 9 0 R >> >> >>
                """
            ),
            PDFObject(
                6,
                """
                << /Type /Annot /Subtype /Widget /FT /Tx /T (Amount A) /V (10) /Rect [72 560 240 594] /P 3 0 R /DA (/Helv 12 Tf 0 g) >>
                """
            ),
            PDFObject(
                7,
                """
                << /Type /Annot /Subtype /Widget /FT /Tx /T (Amount B) /V (20) /Rect [72 500 240 534] /P 3 0 R /DA (/Helv 12 Tf 0 g) >>
                """
            ),
            PDFObject(
                8,
                """
                << /Type /Annot /Subtype /Widget /FT /Tx /T (Total) /V (0) /Rect [72 440 240 474] /P 3 0 R /DA (/Helv 12 Tf 0 g) /AA << /C 10 0 R /F 11 0 R /V 12 0 R >> >>
                """
            ),
            PDFObject(
                9,
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            ),
            PDFObject(
                10,
                "<< /S /JavaScript /JS <\(hexString(calculation))> >>"
            ),
            PDFObject(
                11,
                "<< /S /JavaScript /JS <\(hexString(format))> >>"
            ),
            PDFObject(
                12,
                "<< /S /JavaScript /JS <\(hexString(validation))> >>"
            )
        ]
        try writeClassicPDF(
            objects: objects,
            rootObjectNumber: 1,
            to: url
        )
    }

    static func makeZeroPagePDF(at url: URL) throws {
        try writeClassicPDF(
            objects: [
                PDFObject(
                    1,
                    "<< /Type /Catalog /Pages 2 0 R >>"
                ),
                PDFObject(
                    2,
                    "<< /Type /Pages /Kids [] /Count 0 >>"
                )
            ],
            rootObjectNumber: 1,
            to: url
        )
    }

    private static func writeClassicPDF(
        objects: [PDFObject],
        rootObjectNumber: Int,
        to url: URL
    ) throws {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        let sortedObjects = objects.sorted {
            $0.number < $1.number
        }
        for object in sortedObjects {
            offsets[object.number] = data.count
            data.append(
                Data(
                    "\(object.number) 0 obj\n\(object.dictionary)"
                        .utf8
                )
            )
            if let stream = object.stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        let maximumObjectNumber = max(
            rootObjectNumber,
            sortedObjects.map(\.number).max() ?? 0
        )
        let xrefOffset = data.count
        data.append(
            Data("xref\n0 \(maximumObjectNumber + 1)\n".utf8)
        )
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...maximumObjectNumber {
            if let offset = offsets[number] {
                data.append(
                    Data(
                        String(
                            format: "%010d 00000 n \n",
                            offset
                        ).utf8
                    )
                )
            } else {
                data.append(Data("0000000000 00000 f \n".utf8))
            }
        }
        data.append(
            Data(
                """
                trailer
                << /Size \(maximumObjectNumber + 1) /Root \(rootObjectNumber) 0 R >>
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private static func hexString(_ value: String) -> String {
        Data(value.utf8).map {
            String(format: "%02X", $0)
        }.joined()
    }
}

struct StoredZIPArchiveFixture {
    let entries: [String: Data]
    let localEntryCount: Int
    let centralEntryCount: Int

    init(data: Data) throws {
        var offset = 0
        var parsedEntries: [String: Data] = [:]
        var localCount = 0
        while offset + 4 <= data.count {
            let signature = try data.fixtureUInt32(at: offset)
            guard signature == 0x04034b50 else { break }
            let method = try data.fixtureUInt16(at: offset + 8)
            let checksum = try data.fixtureUInt32(at: offset + 14)
            let compressedSize = Int(
                try data.fixtureUInt32(at: offset + 18)
            )
            let uncompressedSize = Int(
                try data.fixtureUInt32(at: offset + 22)
            )
            let nameLength = Int(
                try data.fixtureUInt16(at: offset + 26)
            )
            let extraLength = Int(
                try data.fixtureUInt16(at: offset + 28)
            )
            guard method == 0,
                  compressedSize == uncompressedSize
            else {
                throw FixtureError.invalidArchive
            }
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            let payloadStart = nameEnd + extraLength
            let payloadEnd = payloadStart + compressedSize
            guard nameEnd <= data.count,
                  payloadEnd <= data.count,
                  let name = String(
                      data: data[nameStart..<nameEnd],
                      encoding: .utf8
                  )
            else {
                throw FixtureError.invalidArchive
            }
            let payload = Data(data[payloadStart..<payloadEnd])
            guard Self.crc32(payload) == checksum,
                  parsedEntries[name] == nil
            else {
                throw FixtureError.invalidArchive
            }
            parsedEntries[name] = payload
            localCount += 1
            offset = payloadEnd
        }

        let endOffset = try Self.endOfCentralDirectoryOffset(
            in: data
        )
        let centralCount = Int(
            try data.fixtureUInt16(at: endOffset + 10)
        )
        let centralSize = Int(
            try data.fixtureUInt32(at: endOffset + 12)
        )
        let centralOffset = Int(
            try data.fixtureUInt32(at: endOffset + 16)
        )
        guard centralCount == localCount,
              centralOffset + centralSize == endOffset
        else {
            throw FixtureError.invalidArchive
        }

        var centralCursor = centralOffset
        var centralNames: Set<String> = []
        for _ in 0..<centralCount {
            guard try data.fixtureUInt32(at: centralCursor)
                == 0x02014b50
            else {
                throw FixtureError.invalidArchive
            }
            let nameLength = Int(
                try data.fixtureUInt16(at: centralCursor + 28)
            )
            let extraLength = Int(
                try data.fixtureUInt16(at: centralCursor + 30)
            )
            let commentLength = Int(
                try data.fixtureUInt16(at: centralCursor + 32)
            )
            let nameStart = centralCursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  let name = String(
                      data: data[nameStart..<nameEnd],
                      encoding: .utf8
                  ),
                  parsedEntries[name] != nil
            else {
                throw FixtureError.invalidArchive
            }
            centralNames.insert(name)
            centralCursor = nameEnd + extraLength + commentLength
        }
        guard centralCursor == endOffset,
              centralNames.count == parsedEntries.count
        else {
            throw FixtureError.invalidArchive
        }

        entries = parsedEntries
        localEntryCount = localCount
        centralEntryCount = centralCount
    }

    func validateXMLAndRelationships() throws {
        for (path, payload) in entries
            where path.hasSuffix(".xml")
                || path.hasSuffix(".rels") {
            let parser = XMLParser(data: payload)
            guard parser.parse() else {
                throw FixtureError.invalidXML(path)
            }
        }
        for (path, payload) in entries
            where path.hasSuffix(".rels") {
            let collector = RelationshipCollector()
            let parser = XMLParser(data: payload)
            parser.delegate = collector
            guard parser.parse(),
                  collector.hasRelationshipsRoot,
                  !collector.hasMalformedRelationship
            else {
                throw FixtureError.invalidRelationship(path)
            }
            let ownerDirectory: String
            if path == "_rels/.rels" {
                ownerDirectory = ""
            } else if let range = path.range(
                of: "/_rels/",
                options: .backwards
            ) {
                ownerDirectory = String(path[..<range.lowerBound])
            } else {
                throw FixtureError.invalidRelationship(path)
            }
            for relationship in collector.relationships
                where !relationship.isExternal {
                let normalized = try normalizedRelationshipPath(
                    ownerDirectory: ownerDirectory,
                    target: relationship.target
                )
                guard entries[normalized] != nil else {
                    throw FixtureError.invalidRelationship(
                        "\(path):\(relationship.target)"
                    )
                }
            }
        }
        try validateContentTypes()
    }

    private func validateContentTypes() throws {
        guard let payload = entries["[Content_Types].xml"] else {
            throw FixtureError.invalidContentType(
                "[Content_Types].xml"
            )
        }
        let collector = ContentTypesCollector()
        let parser = XMLParser(data: payload)
        parser.delegate = collector
        guard parser.parse(),
              collector.hasTypesRoot,
              !collector.hasMalformedDeclaration
        else {
            throw FixtureError.invalidContentType(
                "[Content_Types].xml"
            )
        }

        for path in entries.keys
            where path != "[Content_Types].xml" {
            let fileExtension = path.hasSuffix(".rels")
                ? "rels"
                : (path as NSString)
                    .pathExtension
                    .lowercased()
            guard collector.overrides[path] != nil
                    || collector.defaults[fileExtension] != nil
            else {
                throw FixtureError.invalidContentType(path)
            }
        }
        for path in collector.overrides.keys
            where entries[path] == nil {
            throw FixtureError.invalidContentType(path)
        }
    }

    private func normalizedRelationshipPath(
        ownerDirectory: String,
        target: String
    ) throws -> String {
        let rawPath = target.hasPrefix("/")
            ? target
            : [ownerDirectory, target]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        var components: [Substring] = []
        for component in rawPath.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw FixtureError.invalidRelationship(target)
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            throw FixtureError.invalidRelationship(target)
        }
        return components.joined(separator: "/")
    }

    private static func endOfCentralDirectoryOffset(
        in data: Data
    ) throws -> Int {
        guard data.count >= 22 else {
            throw FixtureError.invalidArchive
        }
        let minimumOffset = max(0, data.count - 65_557)
        for offset in stride(
            from: data.count - 22,
            through: minimumOffset,
            by: -1
        ) {
            if try data.fixtureUInt32(at: offset) == 0x06054b50 {
                return offset
            }
        }
        throw FixtureError.invalidArchive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var result = UInt32.max
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(
                    bitPattern: -Int32(result & 1)
                )
                result = (result >> 1)
                    ^ (0xedb88320 & mask)
            }
        }
        return result ^ UInt32.max
    }

    enum FixtureError: Error {
        case invalidArchive
        case invalidXML(String)
        case invalidRelationship(String)
        case invalidContentType(String)
    }
}

private final class RelationshipCollector:
    NSObject,
    XMLParserDelegate {
    struct Relationship {
        let target: String
        let isExternal: Bool
    }

    private(set) var relationships: [Relationship] = []
    private(set) var hasRelationshipsRoot = false
    private(set) var hasMalformedRelationship = false
    private var identifiers: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Relationships" {
            hasRelationshipsRoot = true
            return
        }
        guard elementName == "Relationship" else { return }
        guard let identifier = attributeDict["Id"],
              !identifier.isEmpty,
              identifiers.insert(identifier).inserted,
              let type = attributeDict["Type"],
              !type.isEmpty,
              let target = attributeDict["Target"],
              !target.isEmpty
        else {
            hasMalformedRelationship = true
            return
        }
        relationships.append(
            Relationship(
                target: target,
                isExternal: attributeDict["TargetMode"]?
                    .caseInsensitiveCompare("External")
                    == .orderedSame
            )
        )
    }
}

private final class ContentTypesCollector:
    NSObject,
    XMLParserDelegate {
    private(set) var defaults: [String: String] = [:]
    private(set) var overrides: [String: String] = [:]
    private(set) var hasTypesRoot = false
    private(set) var hasMalformedDeclaration = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Types":
            hasTypesRoot = true
        case "Default":
            guard let fileExtension = attributeDict["Extension"]?
                .lowercased(),
                  !fileExtension.isEmpty,
                  let contentType = attributeDict["ContentType"],
                  !contentType.isEmpty,
                  defaults[fileExtension] == nil
            else {
                hasMalformedDeclaration = true
                return
            }
            defaults[fileExtension] = contentType
        case "Override":
            guard let partName = attributeDict["PartName"],
                  partName.hasPrefix("/"),
                  let contentType = attributeDict["ContentType"],
                  !contentType.isEmpty
            else {
                hasMalformedDeclaration = true
                return
            }
            let path = String(partName.dropFirst())
            guard !path.isEmpty,
                  overrides[path] == nil
            else {
                hasMalformedDeclaration = true
                return
            }
            overrides[path] = contentType
        default:
            return
        }
    }
}

private extension Data {
    func fixtureUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw StoredZIPArchiveFixture.FixtureError.invalidArchive
        }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func fixtureUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw StoredZIPArchiveFixture.FixtureError.invalidArchive
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

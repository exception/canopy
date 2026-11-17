import XCTest
@testable import Canopy

final class ParserTests: XCTestCase {
    func testShellSyntax() throws {
        let d = try ShellParser.parseDocument("""
        { status: 'refunded', // comment
          total: { $gt: 15000 }, "shipping.city": "Rosario",
          createdAt: { $gte: ISODate("2026-09-18T02:13:53Z") },
          _id: ObjectId("6afbb37299ac1f3ea08a9263"), n: NumberLong("9007199254740993"),
          price: Decimal128("12.50"), re: /^ros/i, ok: true, none: null, arr: [1, 2.5, -3,], }
        """)
        XCTAssertEqual(d["status"], .string("refunded"))
        XCTAssertEqual(d["total"]?.doc?["$gt"], .int32(15000))
        XCTAssertEqual(d["shipping.city"], .string("Rosario"))
        if case .date(let dt) = d["createdAt"]?.doc?["$gte"] { XCTAssertEqual(dt.timeIntervalSince1970, 1789697633, accuracy: 1) } else { XCTFail() }
        XCTAssertEqual(d["_id"], .objectId("6afbb37299ac1f3ea08a9263"))
        XCTAssertEqual(d["n"], .int64(9007199254740993))
        XCTAssertEqual(d["price"], .decimal("12.50"))
        XCTAssertEqual(d["re"], .regex("^ros", "i"))
        XCTAssertEqual(d["arr"], .array([.int32(1), .double(2.5), .int32(-3)]))
        XCTAssertEqual(d["none"], .null)
    }

    func testExtendedJSON() throws {
        let d = try ShellParser.parseDocument(#"{"_id": {"$oid": "6afbb37299ac1f3ea08a9263"}, "at": {"$date": "2026-01-01T00:00:00Z"}, "n": {"$numberLong": "5"}, "q": {"$regex": "x", "$options": "i"}}"#)
        XCTAssertEqual(d["_id"], .objectId("6afbb37299ac1f3ea08a9263"))
        XCTAssertEqual(d["n"], .int64(5))
        XCTAssertNotNil(d["q"]?.doc?["$regex"], "query operators are not wrappers")
        if case .date = d["at"] {} else { XCTFail("date") }
    }

    func testErrorsHaveLocation() {
        XCTAssertThrowsError(try ShellParser.parseDocument("{ a: 1,\n b: }")) { e in
            XCTAssertTrue(e.localizedDescription.contains("line 2"), e.localizedDescription)
        }
        XCTAssertThrowsError(try ShellParser.parseDocument("[1]"))
        XCTAssertEqual(try ShellParser.parseDocument("   "), BDoc())
    }

    func testRoundTripThroughFormatter() throws {
        let src = BDoc([("a", .int32(1)), ("b", .array([.string("x\n\"y\""), .double(1.5)])), ("c", .document(BDoc([("d", .date(Date(timeIntervalSince1970: 1_700_000_000.123)))]))),
                        ("e", .decimal("-0.001")), ("f", .binary(4, Data(hex: "0123456789abcdef0123456789abcdef")!)), ("g", .int64(1 << 40)), ("h", .timestamp(5, 6))])
        for style in [BFormat.Style.shell, .ejson] {
            let text = BFormat.text(src, style: style)
            let back = try ShellParser.parseDocument(text)
            XCTAssertEqual(back.keys, src.keys, style == .shell ? "shell" : "ejson")
            XCTAssertEqual(back["e"], .decimal("-0.001"))
            XCTAssertEqual(back["f"], src["f"])
            XCTAssertEqual(back["h"], src["h"])
        }
    }

    func testDecimal128Codec() {
        for s in ["0", "12.50", "-0.001", "1234567890.123456789", "1E+10", "5E-20"] {
            guard let (lo, hi) = Decimal128Codec.parts(s) else { return XCTFail(s) }
            let back = Decimal128Codec.string(low: lo, high: hi)
            XCTAssertEqual(Decimal(string: back), Decimal(string: s), "\(s) -> \(back)")
        }
        // Known encoding of 1 (0x3040000000000000 / 1).
        let (lo, hi) = Decimal128Codec.parts("1")!
        XCTAssertEqual(hi, 0x3040_0000_0000_0000)
        XCTAssertEqual(lo, 1)
    }

    func testBSONBridgeRoundTrip() {
        let src = BDoc([("d", .decimal("867.42")), ("u", .binary(4, Data(repeating: 7, count: 16))), ("o", .objectId("6afbb37299ac1f3ea08a9263")),
                        ("arr", .array([.int32(1), .document(BDoc([("x", .null)]))])), ("r", .regex("a.c", "im")), ("l", .int64(42))])
        let back = BSONBridge.doc(BSONBridge.document(src))
        XCTAssertEqual(back, src)
    }

    func testSchemaPresenceCountsDocumentsNotElements() {
        let docs = [BDoc([("items", .array([.document(BDoc([("sku", .string("a"))])), .document(BDoc([("sku", .string("b"))]))]))]),
                    BDoc([("items", .array([]))])]
        let r = SchemaAnalyzer.analyze(docs)
        let sku = r.fields.first { $0.path == "items.sku" }!
        XCTAssertEqual(r.presence(sku), 0.5)
    }

    func testConnectionStringPasswordSplit() {
        let (u, p) = ConnectionString.split("mongodb+srv://erik:p%40ss@cluster.example.net/app?retryWrites=true")
        XCTAssertEqual(u, "mongodb+srv://erik@cluster.example.net/app?retryWrites=true")
        XCTAssertEqual(p, "p@ss")
        XCTAssertEqual(ConnectionString.join(u, password: p), "mongodb+srv://erik:p%40ss@cluster.example.net/app?retryWrites=true")
    }

    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("ord", "orders shop"))
        XCTAssertNil(Fuzzy.score("xyz", "orders"))
        XCTAssertGreaterThan(Fuzzy.score("ord", "orders")!, Fuzzy.score("ord", "a_random_order_thing")!)
    }
}

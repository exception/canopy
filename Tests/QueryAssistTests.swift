import XCTest
@testable import Canopy

@MainActor
final class QueryAssistTests: XCTestCase {
    private func catalog() throws -> FieldCatalog {
        let docs = try ["refunded", "paid", "paid", "pending"].enumerated().map { i, st in
            try ShellParser.parseDocument("{ _id: \(i), status: '\(st)', total: \(i * 10), createdAt: ISODate('2026-11-0\(i + 1)T00:00:00Z'), shipping: { city: 'Rosario', zip: '2000' } }")
        }
        return FieldCatalog.build(docs)
    }

    private func complete(_ s: String, ops: Bool = true) throws -> CompletionResult? {
        QueryCompletion.complete(s, cursor: (s as NSString).length, catalog: try catalog(), operators: ops)
    }

    func testCatalog() throws {
        let c = try catalog()
        XCTAssertEqual(c.paths, ["_id", "status", "total", "createdAt", "shipping", "shipping.city", "shipping.zip"])
        XCTAssertEqual(c.dates, ["createdAt"])
        XCTAssertEqual(c.values["status"]?.first, .string("paid"))
        XCTAssertNil(c.values["_id"])
    }

    func testFieldKeys() throws {
        XCTAssertEqual(try complete("{ st")?.items.map(\.label), ["status"])
        XCTAssertEqual(try complete("{ st")?.items.first?.insert, "status: ")
        XCTAssertEqual(try complete("{ status: 'paid', ci")?.items.map(\.label), ["shipping.city"])
        XCTAssertEqual(try complete("{ sh")?.items.map(\.label), ["shipping", "shipping.city", "shipping.zip"])
        XCTAssertNil(try complete("{ status"))       // exact match: nothing to add
        XCTAssertNil(try complete("{ "))             // no word yet
    }

    func testOperators() throws {
        XCTAssertEqual(try complete("{ total: { $gt")?.items.map(\.label), ["$gte"])
        XCTAssertNil(try complete("{ $o", ops: false))
    }

    func testValues() throws {
        XCTAssertEqual(try complete("{ status: ")?.items.map(\.label), ["\"paid\"", "\"pending\"", "\"refunded\""])
        let r = try complete("{ status: \"re")
        XCTAssertEqual(r?.items.map(\.insert), ["refunded"])
        XCTAssertEqual(r?.range.length, 2)
        XCTAssertNil(try complete("{ status: [ \"re"))  // inside an array: no key context
    }

    func testConstructors() throws {
        let r = try XCTUnwrap(complete("{ owner: Obje"))
        XCTAssertEqual(r.items.first?.insert, "ObjectId(\"\")")
        XCTAssertEqual(r.items.first?.caretBack, 2)
        XCTAssertEqual(r.range.length, 4)
        XCTAssertEqual(try complete("{ owner: obj")?.items.first?.label, "ObjectId(\"\")")   // any case
        XCTAssertEqual(try complete("{ owner: { $in: [ObjectId(\"a\"), Obj")?.items.first?.label, "ObjectId(\"\")")
        XCTAssertEqual(try complete("{ createdAt: { $gte: IS")?.items.map(\.label), ["ISODate(\"\")"])
        XCTAssertEqual(try complete("{ done: tr")?.items.map(\.label), ["true"])
        XCTAssertNil(try complete("{ owner: \"Obj"))         // inside a string
        XCTAssertNil(try complete("{ Obj"))                   // key position: fields only
    }

    func testTypedEmptyValue() throws {
        // A Date field offers ISODate before anything is typed; other fields stay quiet.
        XCTAssertEqual(try complete("{ createdAt: ")?.items.map(\.label), ["ISODate(\"\")"])
        XCTAssertNil(try complete("{ shipping: "))
    }

    func testReferenceLinker() {
        let l = ReferenceLinker(db: "app", collections: ["auction_requests", "dealerships", "users", "companies", "vehicleModels"])
        XCTAssertEqual(l.target(forKey: "auction_request"), "auction_requests")
        XCTAssertEqual(l.target(forKey: "auctionRequestId"), "auction_requests")
        XCTAssertEqual(l.target(forKey: "dealership_id"), "dealerships")
        XCTAssertEqual(l.target(forKey: "dealershipIds"), "dealerships")
        XCTAssertEqual(l.target(forKey: "seller_dealership"), "dealerships")
        XCTAssertEqual(l.target(forKey: "company"), "companies")
        XCTAssertEqual(l.target(forKey: "vehicle_model_id"), "vehicleModels")
        XCTAssertEqual(l.target(forKey: "user"), "users")
        XCTAssertNil(l.target(forKey: "price"))
        XCTAssertEqual(ReferenceLinker.filter(for: .objectId("abc")), "{ _id: ObjectId(\"abc\") }")
        XCTAssertEqual(ReferenceLinker.filter(for: .array([.objectId("a"), .objectId("b")])), "{ _id: { $in: [ObjectId(\"a\"), ObjectId(\"b\")] } }")
        XCTAssertNil(ReferenceLinker.filter(for: .string("abc")))
    }

    func testPresets() throws {
        let c = try catalog()
        XCTAssertTrue(QueryPresets.sorts(c).contains { $0.sort == "{ createdAt: -1 }" })
        let day = try XCTUnwrap(QueryPresets.recent(c).first { $0.title == "24 hours" }).resolved(now: Date(timeIntervalSince1970: 1_800_000_000))
        let f = try ShellParser.parseDocument(XCTUnwrap(day.filter))
        if case .date(let d) = f["createdAt"]?.doc?["$gte"] { XCTAssertEqual(d.timeIntervalSince1970, 1_800_000_000 - 86400, accuracy: 1) } else { XCTFail() }
        let status = try XCTUnwrap(QueryPresets.values(c).first { $0.field == "status" })
        XCTAssertEqual(try ShellParser.parseDocument(XCTUnwrap(status.presets.first?.filter))["status"], .string("paid"))
    }
}

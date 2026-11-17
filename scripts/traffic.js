// Simulates app traffic on analytics.events / shop.orders for live-mode demos.
const an = db.getSiblingDB("analytics"), shop = db.getSiblingDB("shop");
const types = ["page_view","search","add_to_cart","purchase","login"];
for (let i = 0; i < (typeof N === "undefined" ? 40 : N); i++) {
  const t = types[Math.floor(Math.random()*types.length)];
  an.events.insertOne({ type: t, userId: null, ts: new Date(), device: { os: ["iOS","Android","macOS"][i%3], app: "web", version: "3.3.0" }, props: { path: "/p/tires", live: true } });
  if (i % 3 === 0) shop.orders.updateOne({ status: "processing" }, { $set: { status: "shipped", updatedAt: new Date() } });
  if (i % 7 === 0) an.events.deleteOne({ "props.live": true, type: "login" });
  sleep(350 + Math.random()*400);
}

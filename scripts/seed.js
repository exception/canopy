// Seeds a demo dataset into a throwaway MongoDB. Usage: mongosh <uri> scripts/seed.js
function rnd(a) { return a[Math.floor(Math.random() * a.length)]; }
function ri(lo, hi) { return lo + Math.floor(Math.random() * (hi - lo + 1)); }
const first = ["Ana","Bruno","Carla","Diego","Elena","Facundo","Gabriela","Hugo","Inés","Javier","Kiara","Lucas","Martina","Nicolás","Olivia","Pablo","Renata","Santiago","Tomás","Valentina","Ximena","Yago","Zoe","Lionel","Camila"];
const last = ["García","Fernández","López","Martínez","Rodríguez","Pérez","Gómez","Díaz","Sosa","Romero","Álvarez","Torres","Ruiz","Ramírez","Flores","Acosta","Benítez","Medina","Herrera","Suárez"];
const cities = [["Buenos Aires","AR",[-58.38,-34.60]],["Córdoba","AR",[-64.18,-31.42]],["Rosario","AR",[-60.65,-32.95]],["Montevideo","UY",[-56.16,-34.90]],["Santiago","CL",[-70.66,-33.45]],["São Paulo","BR",[-46.63,-23.55]],["Mendoza","AR",[-68.83,-32.89]],["Lima","PE",[-77.04,-12.05]]];
const day = 86400000, now = Date.now();

// ---------- shop ----------
let shop = db.getSiblingDB("shop");
shop.dropDatabase();
const cats = ["tires","brakes","oil","filters","batteries","lighting","audio","tools","accessories","suspension"];
const brands = ["Pirelli","Bosch","Castrol","Michelin","Brembo","NGK","Mobil 1","Philips","Moura","Monroe"];
let products = [];
for (let i = 0; i < 400; i++) {
  const c = rnd(cats);
  products.push({ _id: new ObjectId(), sku: "SKU-" + (10000 + i), name: rnd(brands) + " " + c.slice(0,1).toUpperCase() + c.slice(1) + " " + ri(100,999),
    category: c, brand: rnd(brands), price: NumberDecimal((ri(500, 250000) / 100).toFixed(2)), stock: ri(0, 500),
    tags: Array.from(new Set([rnd(["sale","new","premium","eco","bestseller","clearance"]), rnd(["sale","new","premium","eco"])])),
    dimensions: Math.random() < 0.7 ? { w: ri(5,80), h: ri(5,80), d: ri(5,80), unit: "cm" } : null,
    active: Math.random() < 0.9, createdAt: new Date(now - ri(0, 900) * day) });
}
shop.products.insertMany(products);
let customers = [];
for (let i = 0; i < 5000; i++) {
  const c = rnd(cities), f = rnd(first), l = rnd(last);
  const doc = { _id: new ObjectId(), name: f + " " + l, email: (f + "." + l + i).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "") + "@example.com",
    address: { city: c[0], country: c[1], location: { type: "Point", coordinates: [c[2][0] + Math.random()/10, c[2][1] + Math.random()/10] } },
    tier: rnd(["free","free","free","plus","plus","pro"]), signupAt: new Date(now - ri(0, 1200) * day), marketingOptIn: Math.random() < 0.4 };
  if (Math.random() < 0.6) doc.phone = "+54 9 11 " + ri(1000,9999) + "-" + ri(1000,9999);
  if (Math.random() < 0.15) doc.notes = rnd(["VIP customer","Prefers WhatsApp","Disputed a charge in 2025","Fleet account"]);
  customers.push(doc);
}
shop.customers.insertMany(customers);
let orders = [];
for (let i = 0; i < 40000; i++) {
  const cu = rnd(customers), n = ri(1, 4), items = [];
  let total = 0;
  for (let k = 0; k < n; k++) { const p = rnd(products), q = ri(1,4); const pr = parseFloat(p.price.toString()); total += pr * q;
    items.push({ productId: p._id, sku: p.sku, name: p.name, qty: q, unitPrice: p.price }); }
  const created = new Date(now - Math.pow(Math.random(), 1.6) * 365 * day);
  const status = rnd(["delivered","delivered","delivered","shipped","processing","cancelled","refunded"]);
  orders.push({ customerId: cu._id, number: 100000 + i, status, items, total: NumberDecimal(total.toFixed(2)), currency: "ARS",
    payment: { method: rnd(["card","card","mercadopago","transfer","cash"]), installments: rnd([1,1,3,6,12]) },
    shipping: { city: cu.address.city, country: cu.address.country, carrier: rnd(["Andreani","OCA","Correo Argentino","DHL"]) },
    createdAt: created, updatedAt: new Date(created.getTime() + ri(0, 10) * day) });
  if (orders.length === 5000) { shop.orders.insertMany(orders); orders = []; }
}
if (orders.length) shop.orders.insertMany(orders);
shop.orders.createIndex({ customerId: 1, createdAt: -1 });
shop.orders.createIndex({ status: 1 });
shop.customers.createIndex({ email: 1 }, { unique: true });
shop.customers.createIndex({ "address.location": "2dsphere" });
shop.products.createIndex({ sku: 1 }, { unique: true });
let reviews = [];
for (let i = 0; i < 8000; i++) { const p = rnd(products);
  reviews.push({ productId: p._id, customerId: rnd(customers)._id, rating: rnd([5,5,5,4,4,3,2,1]),
    title: rnd(["Excellent","Works as described","Not bad","Arrived late","Great value","Would not buy again"]),
    body: rnd(["Installed it on my Gol Trend, no issues.","Shipping took two weeks.","Exactly what I needed for the track day.","Quality is OK for the price."]),
    helpful: ri(0, 40), createdAt: new Date(now - ri(0, 400) * day) }); }
shop.reviews.insertMany(reviews);

// ---------- racing ----------
let race = db.getSiblingDB("racing");
race.dropDatabase();
const teams = ["Scuderia Pampa","Andes Motorsport","Rio Plata Racing","Patagonia GP","Tango Engineering"];
let drivers = [];
for (let i = 0; i < 20; i++) drivers.push({ _id: i + 1, code: (rnd(last).slice(0,3)).toUpperCase().normalize("NFD").replace(/[̀-ͯ]/g, ""), name: rnd(first) + " " + rnd(last), team: teams[i % 5], number: ri(2, 99), nationality: rnd(["AR","UY","CL","BR","PE"]), rookie: i > 15 });
race.drivers.insertMany(drivers);
const tracks = [["Autódromo Oscar y Juan Gálvez", 5.65], ["Termas de Río Hondo", 4.8], ["Interlagos", 4.309], ["Potrero de los Funes", 6.27]];
let laps = [];
let sessions = [];
for (let s = 0; s < 12; s++) {
  const t = tracks[s % tracks.length], start = new Date(now - (60 - s * 5) * day);
  const sid = new ObjectId();
  sessions.push({ _id: sid, track: t[0], lengthKm: t[1], kind: rnd(["practice","qualifying","race"]), startedAt: start, weather: { airTemp: ri(12, 34), trackTemp: ri(18, 52), rain: Math.random() < 0.2 } });
  for (const d of drivers) for (let l = 1; l <= 30; l++) {
    const base = t[1] * 16 + d._id * 0.05;
    laps.push({ sessionId: sid, driverId: d._id, lap: l, timeMs: Math.round((base + Math.random() * 2.5 + (l === 1 ? 4 : 0)) * 1000),
      sectors: [ri(25000, 32000), ri(28000, 36000), ri(24000, 30000)], tyre: l < 15 ? "soft" : "medium", pit: l === 15, topSpeedKph: ri(270, 318) });
  }
}
race.sessions.insertMany(sessions);
race.laps.insertMany(laps);

// ---------- analytics ----------
let an = db.getSiblingDB("analytics");
an.dropDatabase();
let evs = [];
const evTypes = ["page_view","page_view","page_view","search","add_to_cart","checkout_started","purchase","login","signup"];
for (let i = 0; i < 60000; i++) {
  const t = evTypes[Math.floor(Math.pow(Math.random(), 1.3) * evTypes.length)];
  const e = { type: t, userId: Math.random() < 0.8 ? rnd(customers)._id : null, sessionId: UUID(), ts: new Date(now - Math.random() * 30 * day),
    device: { os: rnd(["iOS","Android","macOS","Windows"]), app: rnd(["web","web","ios","android"]), version: rnd(["3.2.0","3.2.1","3.3.0"]) },
    props: {} };
  if (t === "page_view") e.props = { path: rnd(["/","/search","/p/tires","/p/brakes","/cart","/account"]), durationMs: ri(200, 90000) };
  if (t === "search") e.props = { q: rnd(["pirelli p zero","pastillas freno","aceite 5w30","bateria 75ah"]), results: ri(0, 120) };
  if (t === "purchase") e.props = { orderNumber: ri(100000, 140000), value: ri(5000, 900000) };
  evs.push(e);
  if (evs.length === 10000) { an.events.insertMany(evs); evs = []; }
}
an.events.createIndex({ ts: -1 });
an.events.createIndex({ type: 1, ts: -1 });
print("seeded");

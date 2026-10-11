import { PrismaClient, type AssetType } from '@prisma/client';
import { hashPassword } from '../src/auth/password.js';

const prisma = new PrismaClient();

const DEMO_EMAIL = 'demo@arcar.com';
const DEMO_PASSWORD = 'demo-password';
const STAND_IN_MESH = '/models/cesium-milk-truck.glb';

type CatalogCar = { make: string; model: string; year: number };
type Fit = 'all' | CatalogCar[];

const cars: CatalogCar[] = [
  { make: 'Toyota', model: 'Camry', year: 2018 },
  { make: 'Toyota', model: 'Corolla', year: 2018 },
  { make: 'Honda', model: 'Accord', year: 2017 },
  { make: 'Hyundai', model: 'Elantra', year: 2019 },
  { make: 'Honda', model: 'Civic', year: 2018 },
];

const assets: Array<{
  type: AssetType;
  name: string;
  materialBundleUrl: string;
  price: number;
  anchor: string;
  fit: Fit;
}> = [
  { type: 'PAINT', name: 'Gloss Black', materialBundleUrl: 'color:#111111', price: 150000, anchor: 'body', fit: 'all' },
  { type: 'PAINT', name: 'Metallic Silver', materialBundleUrl: 'color:#b7b7be', price: 180000, anchor: 'body', fit: 'all' },
  { type: 'PAINT', name: 'Carmine Red', materialBundleUrl: 'color:#9b1b30', price: 165000, anchor: 'body', fit: 'all' },
  { type: 'PAINT', name: 'Super White', materialBundleUrl: 'color:#f4f4f4', price: 155000, anchor: 'body', fit: [cars[0], cars[1]] },
  { type: 'PAINT', name: 'Modern Steel', materialBundleUrl: 'color:#6e7276', price: 170000, anchor: 'body', fit: [cars[2]] },
  { type: 'PAINT', name: 'Phantom Black', materialBundleUrl: 'color:#1a1a1a', price: 160000, anchor: 'body', fit: [cars[3]] },
  { type: 'PAINT', name: 'Rallye Red', materialBundleUrl: 'color:#c8102e', price: 175000, anchor: 'body', fit: [cars[4]] },
  { type: 'PAINT', name: 'Matte Black', materialBundleUrl: 'color:#1c1c1c;finish:matte', price: 168000, anchor: 'body', fit: 'all' },
  { type: 'PAINT', name: 'Candy Red', materialBundleUrl: 'color:#d0122d;finish:candy', price: 190000, anchor: 'body', fit: 'all' },
  { type: 'PAINT', name: 'Satin Graphite', materialBundleUrl: 'color:#6a6e73;finish:satin', price: 172000, anchor: 'body', fit: 'all' },
  { type: 'RIM', name: '17-inch Camry Alloy', materialBundleUrl: 'primitive:rim', price: 210000, anchor: 'wheels', fit: [cars[0]] },
  { type: 'RIM', name: '17-inch Corolla Sport Alloy', materialBundleUrl: 'primitive:rim', price: 195000, anchor: 'wheels', fit: [cars[1]] },
  { type: 'RIM', name: '18-inch Accord Sport', materialBundleUrl: 'primitive:rim', price: 240000, anchor: 'wheels', fit: [cars[2]] },
  { type: 'RIM', name: '17-inch Elantra Alloy', materialBundleUrl: 'primitive:rim', price: 200000, anchor: 'wheels', fit: [cars[3]] },
  { type: 'RIM', name: '18-inch Civic Si', materialBundleUrl: 'primitive:rim', price: 220000, anchor: 'wheels', fit: [cars[4]] },
  { type: 'SPOILER', name: 'Toyota TRD Lip Spoiler', materialBundleUrl: 'primitive:spoiler', price: 135000, anchor: 'trunk', fit: [cars[0], cars[1]] },
  { type: 'SPOILER', name: 'Accord Deck Lip', materialBundleUrl: 'primitive:spoiler', price: 140000, anchor: 'trunk', fit: [cars[2]] },
  { type: 'SPOILER', name: 'Elantra Sport Lip', materialBundleUrl: 'primitive:spoiler', price: 145000, anchor: 'trunk', fit: [cars[3]] },
  { type: 'SPOILER', name: 'Civic Si Wing', materialBundleUrl: 'primitive:spoiler', price: 190000, anchor: 'trunk', fit: [cars[4]] },
];

function carKey(car: CatalogCar): string {
  return `${car.make}|${car.model}|${car.year}`;
}

async function main() {
  const passwordHash = await hashPassword(DEMO_PASSWORD);

  const user = await prisma.user.upsert({
    where: { email: DEMO_EMAIL },
    update: {
      passwordHash,
      fullName: 'Demo Driver',
    },
    create: {
      email: DEMO_EMAIL,
      passwordHash,
      fullName: 'Demo Driver',
    },
  });

  const carIds = new Map<string, string>();
  for (const car of cars) {
    const existing = await prisma.carModel.findFirst({
      where: { make: car.make, model: car.model, year: car.year },
    });
    const row = existing
      ? await prisma.carModel.update({
          where: { id: existing.id },
          data: { baseMeshUrl: STAND_IN_MESH },
        })
      : await prisma.carModel.create({
          data: { ...car, baseMeshUrl: STAND_IN_MESH },
        });
    carIds.set(carKey(car), row.id);
  }

  const assetIds = new Map<string, string>();
  for (const asset of assets) {
    // If it's a RIM, set its materialBundleUrl to our rim.glb
    // If it's a SPOILER, set its materialBundleUrl to our spoiler.glb
    let bundle = asset.materialBundleUrl;
    if (asset.type === 'RIM') bundle = '/models/rim.glb';
    if (asset.type === 'SPOILER') bundle = '/models/spoiler.glb';

    const data = {
      type: asset.type,
      name: asset.name,
      materialBundleUrl: bundle,
      price: asset.price,
      anchor: asset.anchor,
    };
    const existing = await prisma.asset.findFirst({
      where: { type: asset.type, name: asset.name },
    });
    const row = existing
      ? await prisma.asset.update({ where: { id: existing.id }, data })
      : await prisma.asset.create({ data });
    assetIds.set(`${asset.type}|${asset.name}`, row.id);
  }

  const links = assets.flatMap((asset) => {
    const assetId = assetIds.get(`${asset.type}|${asset.name}`);
    if (!assetId) return [];
    const targets = asset.fit === 'all' ? cars : asset.fit;
    return targets.map((car) => {
      const carId = carIds.get(carKey(car));
      if (!carId) throw new Error(`Missing catalog car ${carKey(car)}`);
      return { assetId, carId };
    });
  });

  await prisma.assetFitment.deleteMany();
  await prisma.assetFitment.createMany({ data: links });

  const partsInventory = [
    { sku: 'BMP-F-001', name: 'OEM Front Bumper Cover', category: 'Body Panels', unitCost: 320.0, stockQuantity: 8 },
    { sku: 'BMP-R-002', name: 'OEM Rear Bumper Cover', category: 'Body Panels', unitCost: 310.0, stockQuantity: 6 },
    { sku: 'HOD-A-003', name: 'OEM Steel Hood Assembly', category: 'Body Panels', unitCost: 450.0, stockQuantity: 4 },
    { sku: 'DOR-D-004', name: 'Driver Front Door Shell', category: 'Body Panels', unitCost: 520.0, stockQuantity: 3 },
    { sku: 'LGT-HL-005', name: 'LED Headlight Assembly (LH)', category: 'Lighting', unitCost: 280.0, stockQuantity: 12 },
    { sku: 'LGT-HR-006', name: 'LED Headlight Assembly (RH)', category: 'Lighting', unitCost: 280.0, stockQuantity: 12 },
    { sku: 'WND-F-007', name: 'Acoustic Laminated Windshield', category: 'Glass', unitCost: 390.0, stockQuantity: 5 },
    { sku: 'PNT-KIT-008', name: 'High-Gloss Automotive Basecoat/Clearcoat Kit', category: 'Paint Supplies', unitCost: 85.0, stockQuantity: 25 },
  ];

  for (const part of partsInventory) {
    await prisma.partItem.upsert({
      where: { sku: part.sku },
      update: part,
      create: part,
    });
  }

  console.log(`Seeded demo user ${user.email} (${user.id})`);
  console.log(`Password: ${DEMO_PASSWORD}`);
  console.log(`Stand-in mesh: ${STAND_IN_MESH}`);
  console.log(`Fitment links: ${links.length}. Rims and spoilers are per car; meshes are still stand-ins.`);
  console.log(`Seeded ${partsInventory.length} replacement parts in inventory.`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });

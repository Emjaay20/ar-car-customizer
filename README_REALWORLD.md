# AR Car Customizer

A vertical slice, not a finished product.

Flutter shows a catalog and a paint picker. Unity is supposed to load a GLB and tint the body. NestJS stores users, cars, paint, and saved configurations.

## What works in this tree

- Login against a seeded user, or create an account. Demo account: `demo@arcar.com` / `demo-password`. JWT is required for saves, sharing, and vehicle identification.
- GraphQL catalog of cars. Paint, rims, and spoilers are filtered to the selected car.
- Saving a draft configuration requires the login token. The client does not send a user id. Saved drafts are the garage. A share code copies a token; it does not export a video.
- The backend hosts a real stand-in GLB at `/models/cesium-milk-truck.glb`. Rim and spoiler meshes are stand-in shapes, not brand parts.
- Flutter reads `API_URL` from `--dart-define`. It does not hardcode a LAN address.
- Unity source loads that GLB with GLTFast and paints materials named like the body (`truck`), skipping wheels, glass, and trim.
- Scan a car sends one photo to `identifyVehicle`. Without `VISION_API_KEY` the server says so and does not guess. A match returns only parts fitted to that catalog car.
- Live camera tint is a shader overlay. It stays off until a segmentation mask is loaded. `python ml/segment_car.py --synthetic --publish` writes a test mask the app can apply. That mask is a rectangle, not a real car. On-device Sentis runs only after the Inference Engine package, scripting define, and a 256x256 mask ONNX are added.
- Finish and panel are chosen in the paint picker: gloss, matte, satin, metallic, candy, and body, hood, roof, or doors. A hex field sends the same payload. The preview model gets metallic and smoothness. The camera overlay adds a clearcoat highlight and, when the opaque texture is available, shades it with the camera image. Hood, roof, and door choices are regions on the preview bounds, plus a screen crop of the mask. They are not a scan of those panels.
- If ARCore finds a horizontal floor in front of the camera, the preview sits on it. Otherwise it stays on the look ray. Room light estimation drives the scene light when the phone provides it.
- Save AR photo writes a PNG of the Unity view and opens the Android share sheet. It is a still, not a video. Share code is still a token for the saved catalog configuration.

## What does not work yet

- Brand-accurate car meshes. Catalog rows share the Cesium Milk Truck stand-in. See `backend/public/models/ATTRIBUTION.txt`.
- A trained on-device segmentation model. The Sentis hook refuses to pretend a raw YOLO graph is a paint mask.
- A different car mesh. The phone export includes the current preview shader, framing, and lighting. Catalog rows still share the Cesium Milk Truck stand-in, not a Camry or Accord.
- A real panel segmentation model. Hood, roof, and doors are placement regions, not recognized bodywork.
- Payments, quotes, JWT refresh, or a locked-down CORS policy.

## Run locally

```bash
cd backend
docker compose up -d
npx prisma db push
npx prisma db seed
npm run start:dev
```

Phone, from the repo root, with the PC's LAN IP:

```bat
run-on-phone.bat
```

That passes `--dart-define=API_URL=http://192.168.100.66:3000/graphql`. Change the IP in the bat file if the PC address changes. The phone and PC must be on the same Wi-Fi. Android cleartext HTTP is enabled so that LAN URL is allowed.

After changing C# under `My project/Assets`, the phone will not see it until Unity exports again.

# Build notes

This is a local vertical slice. Do not treat the docs or the UI copy as a release checklist.

## Backend

```bash
cd backend
docker compose up -d
npx prisma db push
npx prisma db seed
npm run start:dev
```

`prisma db push` is used because this repo has no migration history yet. Seed upserts the demo user, points every catalog car at `/models/cesium-milk-truck.glb`, and links rims and spoilers to the cars they fit. Run `npx prisma generate` after pulling schema changes.

Copy `backend/.env.example` to `backend/.env` if that file is missing. Docker credentials in `docker-compose.yml` are local-only defaults. Set `VISION_API_KEY` only if you want `identifyVehicle` to call an OpenAI-compatible vision model. Empty means the endpoint reports that it is not configured.

## Flutter

The app reads the API URL at compile time:

```bash
cd client
flutter pub get
flutter run --dart-define=API_URL=http://YOUR-LAN-IP:3000/graphql
```

`127.0.0.1` is the default and only works for a desktop process on this PC. A phone cannot reach it.

`run-on-phone.bat` already passes the define for `192.168.100.66`.

## Unity

Open `My project` in Unity 6 with the Android build module.

1. Confirm `com.unity.cloud.gltfast` is installed (it is in `Packages/manifest.json`).
2. Use `Flutter → Export Android for Flutter`.
3. Then run the Flutter app. The exported `unityLibrary` is what the phone executes, not the C# you just edited.

The viewer loads the GLB URL Flutter sends, tints body materials, and attaches rim/spoiler stand-ins at estimated anchors. `ApplyPaint` also sets finish (metallic, smoothness) and panel. Live tint uses `ARCar/LivePaint` and stays invisible until a mask arrives. The URP asset copies the opaque camera color so that overlay can follow room shading. Re-seed to add Matte Black, Candy Red, and Satin Graphite.

Save AR photo asks Unity for a PNG, then Flutter opens the share sheet. Sit on floor searches for an ARCore horizontal plane for about 12 seconds.

## Segmentation prototype

```bash
python ml/segment_car.py --self-test
python ml/segment_car.py --synthetic --publish
```

`--publish` writes `backend/public/masks/paint-mask.png` and `bridge-frame.json`. The app button "Apply published segmentation mask" loads that file. Synthetic output is a test rectangle. A real video needs `ml/requirements.txt` and `--video`.

On-device segmentation is behind scripting define `ARCAR_INFERENCE_ENGINE`, package `com.unity.ai.inference`, and a Resources model named `CarSegMask`. The model must already output a 256x256 body mask.

## Not in this build

- JWT refresh or password reset
- Real rim, spoiler, or brand meshes
- A bundled segmentation ONNX
- Video export of the augmented car
- iOS export verification

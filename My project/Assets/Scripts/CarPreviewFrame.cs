using UnityEngine;

/// <summary>
/// Keeps the stand-in vehicle fully inside the short camera pane.
/// A real-size car at arm's length becomes a wall. This frames a 3/4 view
/// with margin, then sits that same framed car on the floor when one is found.
/// </summary>
public static class CarPreviewFrame
{
    public const float TargetLengthMeters = 1.65f;
    public const float ComfortDistance = 2.7f;
    public const float MinDistance = 1.9f;
    public const float MaxDistance = 3.5f;
    public const float YawDegrees = 28f;
    public const float FrameDrop = 0.16f;

    public static void Fit(GameObject car)
    {
        if (car == null || !TryBounds(car, out var bounds)) return;
        var max = Mathf.Max(bounds.size.x, bounds.size.y, bounds.size.z);
        if (max < 0.001f) return;
        car.transform.localScale = Vector3.one * (TargetLengthMeters / max);
    }

    public static void PlaceOnLookRay(GameObject car)
    {
        if (car == null) return;
        var camera = Camera.main;
        if (camera == null)
        {
            car.transform.position = new Vector3(0f, 0f, ComfortDistance);
            car.transform.rotation = Quaternion.Euler(0f, YawDegrees, 0f);
            return;
        }

        var flat = FlatForward(camera);
        car.transform.rotation = Quaternion.LookRotation(flat, Vector3.up) * Quaternion.Euler(0f, YawDegrees, 0f);
        var anchor = camera.transform.position + camera.transform.forward * ComfortDistance;
        anchor.y -= FrameDrop;
        CenterOn(car, anchor);
    }

    public static void SitOnFloor(GameObject car, Vector3 floorPoint, Camera camera)
    {
        if (car == null || camera == null) return;
        var flat = FlatForward(camera);
        var flatHit = floorPoint - camera.transform.position;
        flatHit.y = 0f;
        var distance = flatHit.magnitude;
        if (distance < 0.05f)
            flatHit = flat;
        else
            flatHit /= distance;

        var framed = Mathf.Clamp(distance < 0.05f ? ComfortDistance : distance, MinDistance, MaxDistance);
        var point = camera.transform.position + flatHit * framed;
        point.y = floorPoint.y;

        car.transform.rotation = Quaternion.LookRotation(flat, Vector3.up) * Quaternion.Euler(0f, YawDegrees, 0f);
        car.transform.position = point;
        if (!TryBounds(car, out var bounds))
            return;
        car.transform.position += point - new Vector3(bounds.center.x, bounds.min.y, bounds.center.z);
    }

    public static void EnsureShadow(GameObject car)
    {
        if (car == null) return;
        var existing = car.transform.Find("GroundShadow");
        if (existing != null)
            Object.Destroy(existing.gameObject);
        if (!TryBounds(car, out var bounds))
            return;

        var shader = Shader.Find("ARCar/BlobShadow");
        if (shader == null)
            return;

        var quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
        quad.name = "GroundShadow";
        var collider = quad.GetComponent<Collider>();
        if (collider != null)
            Object.Destroy(collider);
        quad.transform.SetParent(car.transform, true);
        var footprint = Mathf.Max(bounds.size.x, bounds.size.z) * 1.15f;
        quad.transform.position = new Vector3(bounds.center.x, bounds.min.y + 0.012f, bounds.center.z);
        quad.transform.rotation = Quaternion.Euler(90f, car.transform.eulerAngles.y, 0f);
        quad.transform.localScale = new Vector3(footprint, footprint, 1f);
        var renderer = quad.GetComponent<Renderer>();
        if (renderer != null)
        {
            renderer.sharedMaterial = new Material(shader) { name = "ground-shadow" };
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            renderer.receiveShadows = false;
        }
    }

    static void CenterOn(GameObject car, Vector3 anchor)
    {
        car.transform.position = anchor;
        if (!TryBounds(car, out var bounds))
            return;
        car.transform.position += anchor - bounds.center;
    }

    static Vector3 FlatForward(Camera camera)
    {
        var flat = camera.transform.forward;
        flat.y = 0f;
        if (flat.sqrMagnitude < 0.01f)
            return Vector3.forward;
        return flat.normalized;
    }

    public static bool TryBounds(GameObject car, out Bounds bounds)
    {
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        var any = false;
        bounds = new Bounds(car.transform.position, Vector3.zero);
        for (var i = 0; i < renderers.Length; i++)
        {
            var renderer = renderers[i];
            if (renderer == null || !renderer.enabled) continue;
            var name = renderer.gameObject.name;
            if (name.StartsWith("panel-") || name == "PanelPaint" || name == "GroundShadow" || name == "SurfaceAnchorMarker")
                continue;
            if (!any)
            {
                bounds = renderer.bounds;
                any = true;
            }
            else
            {
                bounds.Encapsulate(renderer.bounds);
            }
        }
        return any;
    }
}

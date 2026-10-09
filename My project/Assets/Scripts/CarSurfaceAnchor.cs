using UnityEngine;
using UnityEngine.XR.ARFoundation;
using UnityEngine.XR.ARSubsystems;

/// <summary>
/// Sits the preview on a detected horizontal plane in front of the camera.
/// Falls back to the look-ray placement if ARCore has not found a floor yet.
/// </summary>
public class CarSurfaceAnchor : MonoBehaviour
{
    const float SearchSeconds = 12f;

    bool locked;
    bool reportedFallback;
    float searchUntil;
    GameObject marker;

    public static void Begin(GameObject car)
    {
        if (car == null) return;
        var anchor = car.GetComponent<CarSurfaceAnchor>();
        if (anchor == null)
            anchor = car.AddComponent<CarSurfaceAnchor>();
        anchor.Relock();
    }

    public void Relock()
    {
        locked = false;
        reportedFallback = false;
        searchUntil = Time.time + SearchSeconds;
    }

    void OnDestroy()
    {
        if (marker != null)
            Destroy(marker);
    }

    void Update()
    {
        if (locked) return;
        if (TrySnap())
        {
            locked = true;
            FlutterMessageReceiver.Report("ANCHORED:plane");
            return;
        }

        if (!reportedFallback && Time.time > searchUntil)
        {
            reportedFallback = true;
            FlutterMessageReceiver.Report("ANCHORED:camera");
        }
    }

    bool TrySnap()
    {
        var camera = Camera.main;
        if (camera == null) return false;

        var planes = FindObjectsByType<ARPlane>(FindObjectsInactive.Exclude);
        var ray = new Ray(camera.transform.position, camera.transform.forward);
        ARPlane best = null;
        var bestDistance = float.MaxValue;
        var bestHit = Vector3.zero;

        for (var i = 0; i < planes.Length; i++)
        {
            var plane = planes[i];
            if (plane.trackingState != TrackingState.Tracking) continue;
            if (plane.alignment != PlaneAlignment.HorizontalUp) continue;
            if (plane.size.x < 0.4f || plane.size.y < 0.4f) continue;

            var surface = new Plane(plane.normal, plane.center);
            if (!surface.Raycast(ray, out var distance)) continue;
            if (distance < 0.6f || distance > 6f) continue;

            var hit = ray.GetPoint(distance);
            if (!Contains(plane, hit)) continue;
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = plane;
                bestHit = hit;
            }
        }

        if (best == null) return false;
        SitOn(bestHit, camera);
        ShowMarker(bestHit, best.normal);
        return true;
    }

    static bool Contains(ARPlane plane, Vector3 worldPoint)
    {
        var local = plane.transform.InverseTransformPoint(worldPoint);
        var center = plane.centerInPlaneSpace;
        return Mathf.Abs(local.x - center.x) <= plane.size.x * 0.5f + 0.3f
            && Mathf.Abs(local.z - center.y) <= plane.size.y * 0.5f + 0.3f;
    }

    void SitOn(Vector3 hit, Camera camera)
    {
        CarPreviewFrame.SitOnFloor(gameObject, hit, camera);
        CarPreviewFrame.EnsureShadow(gameObject);
    }

    void ShowMarker(Vector3 hit, Vector3 normal)
    {
        if (marker == null)
        {
            marker = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
            marker.name = "SurfaceAnchorMarker";
            var collider = marker.GetComponent<Collider>();
            if (collider != null)
                Destroy(collider);
            var shader = Shader.Find("Universal Render Pipeline/Unlit");
            if (shader == null)
                shader = Shader.Find("Unlit/Color");
            if (shader != null)
            {
                var material = new Material(shader);
                material.color = new Color(0.85f, 0.9f, 0.92f, 0.35f);
                marker.GetComponent<Renderer>().sharedMaterial = material;
            }
        }

        marker.transform.position = hit + normal * 0.003f;
        marker.transform.rotation = Quaternion.FromToRotation(Vector3.up, normal);
        marker.transform.localScale = new Vector3(0.72f, 0.002f, 0.72f);
    }
}

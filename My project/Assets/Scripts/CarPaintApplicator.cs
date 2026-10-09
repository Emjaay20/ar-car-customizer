using UnityEngine;

/// <summary>
/// Applies a finish to body materials, or to a hood / roof / door region.
/// Named meshes win. A single-material stand-in gets a lit paint patch on that
/// region of its bounds. Windows, wheels, and trim stay out of the body pass.
/// </summary>
public static class CarPaintApplicator
{
    public static bool Apply(GameObject car, PaintRequest request)
    {
        if (car == null || request == null) return false;
        var color = ParseColor(request.color);
        var finish = request.FinishValues();

        if (PaintRequest.NormalizePanel(request.panel) == "body")
        {
            HidePatches(car);
            return PaintBody(car, color, finish);
        }

        if (PaintNamed(car, request.panel, color, finish))
            return true;
        return PlacePatch(car, request.panel, color, finish);
    }

    public static void ApplyToMaterial(Material material, Color color, PaintFinishValues finish)
    {
        if (material == null) return;
        if (material.HasProperty("baseColorFactor"))
            material.SetColor("baseColorFactor", color);
        if (material.HasProperty("baseColorTexture"))
            material.SetTexture("baseColorTexture", Texture2D.whiteTexture);
        if (material.HasProperty("metallicFactor"))
            material.SetFloat("metallicFactor", finish.metallic);
        if (material.HasProperty("roughnessFactor"))
            material.SetFloat("roughnessFactor", 1f - finish.smoothness);
        if (material.HasProperty("clearcoatFactor"))
            material.SetFloat("clearcoatFactor", finish.smoothness > 0.75f ? 0.7f : 0.05f);
        if (material.HasProperty("_BaseMap"))
            material.SetTexture("_BaseMap", Texture2D.whiteTexture);
        if (material.HasProperty("_MainTex"))
            material.SetTexture("_MainTex", Texture2D.whiteTexture);
        if (material.HasProperty("_BaseColor"))
            material.SetColor("_BaseColor", color);
        if (material.HasProperty("_Color"))
            material.SetColor("_Color", color);
        material.color = color;
        if (material.HasProperty("_Metallic"))
            material.SetFloat("_Metallic", finish.metallic);
        if (material.HasProperty("_Smoothness"))
            material.SetFloat("_Smoothness", finish.smoothness);
        if (material.HasProperty("_Clearcoat"))
            material.SetFloat("_Clearcoat", finish.smoothness > 0.75f ? 0.7f : 0.16f);
        if (material.HasProperty("_Painted"))
            material.SetFloat("_Painted", 1f);
        if (material.HasProperty("_Glossiness"))
            material.SetFloat("_Glossiness", finish.smoothness);
        if (material.HasProperty("_SpecularHighlights"))
            material.SetFloat("_SpecularHighlights", 1f);
        if (material.HasProperty("_EnvironmentReflections"))
            material.SetFloat("_EnvironmentReflections", finish.smoothness > 0.3f ? 1f : 0f);
    }

    static bool PaintBody(GameObject car, Color color, PaintFinishValues finish)
    {
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        var painted = 0;
        foreach (var renderer in renderers)
        {
            if (IsPatch(renderer.gameObject)) continue;
            if (CarBodyPaint.IsNonBodyObject(renderer.gameObject.name)) continue;

            var materials = renderer.materials;
            var changed = false;
            for (var i = 0; i < materials.Length; i++)
            {
                var material = materials[i];
                if (material == null) continue;
                if (!CarBodyPaint.IsBodyMaterial(material.name) && !CarBodyPaint.IsPaintableFallback(renderer.gameObject.name))
                    continue;
                ApplyToMaterial(material, color, finish);
                changed = true;
                painted++;
            }
            if (changed)
                renderer.materials = materials;
        }
        return painted > 0;
    }

    static bool PaintNamed(GameObject car, string panel, Color color, PaintFinishValues finish)
    {
        var token = PaintRequest.NormalizePanel(panel);
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        var painted = 0;
        foreach (var renderer in renderers)
        {
            if (IsPatch(renderer.gameObject)) continue;
            if (CarBodyPaint.IsNonBodyObject(renderer.gameObject.name)) continue;
            if (!NameMatches(renderer.gameObject.name, token) && !MaterialsMatch(renderer, token))
                continue;

            var materials = renderer.materials;
            for (var i = 0; i < materials.Length; i++)
            {
                if (materials[i] == null) continue;
                ApplyToMaterial(materials[i], color, finish);
                painted++;
            }
            renderer.materials = materials;
        }
        return painted > 0;
    }

    static bool MaterialsMatch(Renderer renderer, string token)
    {
        var shared = renderer.sharedMaterials;
        for (var i = 0; i < shared.Length; i++)
        {
            if (shared[i] != null && NameMatches(shared[i].name, token))
                return true;
        }
        return false;
    }

    static bool NameMatches(string name, string token)
    {
        if (string.IsNullOrEmpty(name)) return false;
        var lower = name.ToLowerInvariant();
        if (token == "hood") return lower.Contains("hood") || lower.Contains("bonnet");
        if (token == "roof") return lower.Contains("roof");
        if (token == "doors") return lower.Contains("door");
        return false;
    }

    static bool PlacePatch(GameObject car, string panel, Color color, PaintFinishValues finish)
    {
        if (!TryLocalBounds(car, out var bounds)) return false;
        var root = EnsureRoot(car);
        var token = PaintRequest.NormalizePanel(panel);
        ClearChildren(root, token);
        var material = CreateLit(color, finish, token);
        var lift = 0.012f / Mathf.Max(car.transform.lossyScale.x, 0.001f);

        if (token == "hood")
        {
            Spawn(root, "panel-hood", material,
                new Vector3(bounds.center.x, bounds.max.y + lift, bounds.center.z + bounds.extents.z * 0.55f),
                Quaternion.LookRotation(Vector3.up, Vector3.forward),
                new Vector3(bounds.size.x * 0.62f, bounds.size.z * 0.26f, 1f));
            return true;
        }

        if (token == "roof")
        {
            Spawn(root, "panel-roof", material,
                new Vector3(bounds.center.x, bounds.max.y + lift, bounds.center.z - bounds.extents.z * 0.08f),
                Quaternion.LookRotation(Vector3.up, Vector3.forward),
                new Vector3(bounds.size.x * 0.68f, bounds.size.z * 0.30f, 1f));
            return true;
        }

        Spawn(root, "panel-door-right", material,
            new Vector3(bounds.max.x + lift, bounds.center.y - bounds.extents.y * 0.08f, bounds.center.z),
            Quaternion.LookRotation(Vector3.right, Vector3.up),
            new Vector3(bounds.size.z * 0.36f, bounds.size.y * 0.32f, 1f));
        Spawn(root, "panel-door-left", material,
            new Vector3(bounds.min.x - lift, bounds.center.y - bounds.extents.y * 0.08f, bounds.center.z),
            Quaternion.LookRotation(Vector3.left, Vector3.up),
            new Vector3(bounds.size.z * 0.36f, bounds.size.y * 0.32f, 1f));
        return true;
    }

    static Material CreateLit(Color color, PaintFinishValues finish, string panel)
    {
        var shader = Shader.Find("ARCar/PhotoPaint");
        if (shader == null)
            shader = Shader.Find("Universal Render Pipeline/Lit");
        if (shader == null)
            shader = Shader.Find("Standard");
        var material = new Material(shader) { name = "carpaint-" + panel };
        ApplyToMaterial(material, color, finish);
        return material;
    }

    static void Spawn(Transform root, string name, Material material, Vector3 position, Quaternion rotation, Vector3 scale)
    {
        var quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
        quad.name = name;
        var collider = quad.GetComponent<Collider>();
        if (collider != null)
            Object.Destroy(collider);
        quad.transform.SetParent(root, false);
        quad.transform.localPosition = position;
        quad.transform.localRotation = rotation;
        quad.transform.localScale = scale;
        var renderer = quad.GetComponent<Renderer>();
        if (renderer != null)
            renderer.sharedMaterial = material;
    }

    static Transform EnsureRoot(GameObject car)
    {
        var existing = car.transform.Find("PanelPaint");
        if (existing != null) return existing;
        var root = new GameObject("PanelPaint");
        root.transform.SetParent(car.transform, false);
        return root.transform;
    }

    static void HidePatches(GameObject car)
    {
        var root = car.transform.Find("PanelPaint");
        if (root != null)
            root.gameObject.SetActive(false);
    }

    static void ClearChildren(Transform root, string token)
    {
        root.gameObject.SetActive(true);
        for (var i = root.childCount - 1; i >= 0; i--)
        {
            var child = root.GetChild(i);
            if (!child.name.Contains(token == "doors" ? "door" : token))
                continue;
            var renderer = child.GetComponent<Renderer>();
            if (renderer != null && renderer.sharedMaterial != null)
                Object.Destroy(renderer.sharedMaterial);
            Object.Destroy(child.gameObject);
        }
    }

    static bool IsPatch(GameObject gameObject)
    {
        return gameObject.name.StartsWith("panel-") || gameObject.name == "PanelPaint";
    }

    static bool TryLocalBounds(GameObject car, out Bounds bounds)
    {
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        var any = false;
        bounds = new Bounds(Vector3.zero, Vector3.zero);
        foreach (var renderer in renderers)
        {
            if (IsPatch(renderer.gameObject)) continue;
            if (!renderer.enabled) continue;
            Encapsulate(car.transform, renderer.bounds, ref bounds, ref any);
        }
        return any && bounds.size.sqrMagnitude > 0.0001f;
    }

    static void Encapsulate(Transform space, Bounds world, ref Bounds local, ref bool any)
    {
        var center = world.center;
        var extents = world.extents;
        for (var x = -1; x <= 1; x += 2)
        {
            for (var y = -1; y <= 1; y += 2)
            {
                for (var z = -1; z <= 1; z += 2)
                {
                    var point = space.InverseTransformPoint(center + Vector3.Scale(extents, new Vector3(x, y, z)));
                    if (!any)
                    {
                        local = new Bounds(point, Vector3.zero);
                        any = true;
                    }
                    else
                    {
                        local.Encapsulate(point);
                    }
                }
            }
        }
    }

    public static Color ParseColor(string value)
    {
        if (string.IsNullOrEmpty(value)) return Color.white;
        var token = value.Trim();
        var tagged = token.IndexOf("color:", System.StringComparison.OrdinalIgnoreCase);
        if (tagged >= 0)
            token = token.Substring(tagged + 6);
        var cut = token.IndexOf(';');
        if (cut >= 0)
            token = token.Substring(0, cut);
        token = token.Trim();
        if (token.StartsWith("#")) token = token.Substring(1);
        if (token.Length == 8) token = token.Substring(0, 6);

        if (token.Length == 6 && ColorUtility.TryParseHtmlString("#" + token, out var parsed))
            return parsed;

        switch (token.ToLowerInvariant())
        {
            case "gloss black":
            case "matte black":
            case "phantom black":
            case "black":
                return new Color(0.067f, 0.067f, 0.067f);
            case "metallic silver":
            case "silver":
                return new Color(0.72f, 0.72f, 0.75f);
            case "carmine red":
            case "candy red":
            case "rallye red":
            case "red":
                return new Color(0.61f, 0.11f, 0.19f);
            case "super white":
            case "white":
                return new Color(0.96f, 0.96f, 0.96f);
            case "modern steel":
            case "satin graphite":
                return new Color(0.43f, 0.45f, 0.46f);
            default:
                return Color.white;
        }
    }
}

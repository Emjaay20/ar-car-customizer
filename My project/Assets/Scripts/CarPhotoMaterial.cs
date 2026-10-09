using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// glTFast's shader graphs are stripped out of the Android player, which draws
/// the whole vehicle magenta. This copies the loaded textures onto a project
/// shader that the build cannot strip.
/// </summary>
public static class CarPhotoMaterial
{
    const string OpaqueName = "ARCar/PhotoPaint";
    const string GlassName = "ARCar/PhotoGlass";

    public static int Apply(GameObject car)
    {
        if (car == null) return 0;
        var opaque = Shader.Find(OpaqueName);
        var glass = Shader.Find(GlassName);
        if (opaque == null)
        {
            Debug.LogError("[AR] PhotoPaint shader missing from this build.");
            return 0;
        }

        var converted = 0;
        var renderers = car.GetComponentsInChildren<Renderer>(true);
        for (var i = 0; i < renderers.Length; i++)
        {
            var renderer = renderers[i];
            if (renderer == null || Skip(renderer.gameObject.name)) continue;
            renderer.shadowCastingMode = ShadowCastingMode.On;
            renderer.receiveShadows = true;

            var materials = renderer.materials;
            var changed = false;
            for (var m = 0; m < materials.Length; m++)
            {
                var source = materials[m];
                if (source == null) continue;
                if (source.shader != null && (source.shader.name == OpaqueName || source.shader.name == GlassName || source.shader.name == "ARCar/BlobShadow"))
                    continue;

                var useGlass = glass != null && IsGlass(renderer.gameObject.name, source.name);
                materials[m] = Convert(source, useGlass ? glass : opaque, useGlass);
                changed = true;
                converted++;
            }

            if (changed)
                renderer.materials = materials;
        }

        Debug.Log("[AR] Photo materials: " + converted);
        return converted;
    }

    static bool Skip(string name)
    {
        return name == "GroundShadow"
            || name == "SurfaceAnchorMarker"
            || name == "PanelPaint"
            || name.StartsWith("panel-");
    }

    static bool IsGlass(string objectName, string materialName)
    {
        return Has(objectName, "glass", "window", "windshield", "windscreen")
            || Has(materialName, "glass", "window", "windshield", "windscreen");
    }

    static bool Has(string value, params string[] tokens)
    {
        if (string.IsNullOrEmpty(value)) return false;
        var lower = value.ToLowerInvariant();
        for (var i = 0; i < tokens.Length; i++)
        {
            if (lower.Contains(tokens[i]))
                return true;
        }
        return false;
    }

    static Material Convert(Material source, Shader shader, bool glass)
    {
        var baseMap = Tex(source, "baseColorTexture", "_BaseMap", "_MainTex");
        var normal = Tex(source, "normalTexture", "_BumpMap");
        var metal = Tex(source, "metallicRoughnessTexture", "_MetallicGlossMap");
        var occlusion = Tex(source, "occlusionTexture", "_OcclusionMap");
        var emission = Tex(source, "emissiveTexture", "_EmissionMap");
        var color = Col(source, "baseColorFactor", "_BaseColor", "_Color");
        var metallic = Num(source, "metallicFactor", "_Metallic", glass ? 0f : 0.04f);
        var roughness = Num(source, "roughnessFactor", 1f);
        var smoothness = source.HasProperty("_Smoothness")
            ? source.GetFloat("_Smoothness")
            : 1f - roughness;
        var emissionColor = Col(source, "emissiveFactor", "_EmissionColor", null);

        var material = new Material(shader) { name = source.name };
        material.SetColor("_BaseColor", color);
        material.SetTexture("_BaseMap", baseMap != null ? baseMap : Texture2D.whiteTexture);
        if (!glass)
        {
            material.SetFloat("_HasNormal", normal != null ? 1f : 0f);
            if (normal != null)
                material.SetTexture("_BumpMap", normal);
            material.SetFloat("_HasMetallicRoughness", metal != null ? 1f : 0f);
            if (metal != null)
                material.SetTexture("_MetallicRoughnessMap", metal);
            material.SetFloat("_HasOcclusion", occlusion != null ? 1f : 0f);
            if (occlusion != null)
                material.SetTexture("_OcclusionMap", occlusion);
            material.SetFloat("_HasEmission", emission != null ? 1f : 0f);
            if (emission != null)
                material.SetTexture("_EmissionMap", emission);
            material.SetColor("_EmissionColor", emissionColor);
            material.SetFloat("_Metallic", metallic <= 0f ? 0.04f : metallic);
            material.SetFloat("_Smoothness", Mathf.Clamp(smoothness, 0.08f, 0.98f));
            material.SetFloat("_Clearcoat", 0.22f);
            material.SetFloat("_Painted", 0f);
            material.SetFloat("_OcclusionStrength", 1f);
        }
        else
        {
            var glassColor = color;
            if (glassColor.a > 0.85f)
                glassColor.a = 0.28f;
            material.SetColor("_BaseColor", glassColor);
            material.SetFloat("_Smoothness", 0.92f);
        }

        return material;
    }

    static Texture Tex(Material material, params string[] names)
    {
        for (var i = 0; i < names.Length; i++)
        {
            if (!material.HasProperty(names[i])) continue;
            var texture = material.GetTexture(names[i]);
            if (texture != null)
                return texture;
        }
        return null;
    }

    static Color Col(Material material, string primary, string secondary, string tertiary)
    {
        if (material.HasProperty(primary))
            return material.GetColor(primary);
        if (!string.IsNullOrEmpty(secondary) && material.HasProperty(secondary))
            return material.GetColor(secondary);
        if (!string.IsNullOrEmpty(tertiary) && material.HasProperty(tertiary))
            return material.GetColor(tertiary);
        return material.color;
    }

    static float Num(Material material, string name, string fallbackName, float fallback)
    {
        if (material.HasProperty(name))
            return material.GetFloat(name);
        if (!string.IsNullOrEmpty(fallbackName) && material.HasProperty(fallbackName))
            return material.GetFloat(fallbackName);
        return fallback;
    }

    static float Num(Material material, string name, float fallback)
    {
        return material.HasProperty(name) ? material.GetFloat(name) : fallback;
    }
}

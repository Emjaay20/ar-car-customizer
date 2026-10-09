/// <summary>
/// Decides which glTF material slots receive body paint.
/// Kept free of UnityEngine so the rule stays obvious: wheels, glass, and trim are not body.
/// </summary>
public static class CarBodyPaint
{
    public static bool IsBodyMaterial(string materialName)
    {
        if (string.IsNullOrEmpty(materialName)) return false;

        var name = materialName.ToLowerInvariant();
        if (ContainsAny(name, "wheel", "rim", "tire", "tyre", "glass", "window", "light", "lamp", "trim", "chrome", "interior"))
            return false;

        return ContainsAny(name, "truck", "body", "paint", "chassis", "carpaint");
    }

    public static bool IsPaintableFallback(string objectName)
    {
        if (string.IsNullOrEmpty(objectName)) return false;
        return objectName.ToLowerInvariant().Contains("body");
    }

    public static bool IsNonBodyObject(string objectName)
    {
        if (string.IsNullOrEmpty(objectName)) return false;
        var name = objectName.ToLowerInvariant();
        return ContainsAny(name, "wheel", "rim", "tire", "tyre");
    }

    static bool ContainsAny(string haystack, params string[] tokens)
    {
        for (int i = 0; i < tokens.Length; i++)
        {
            if (haystack.Contains(tokens[i])) return true;
        }
        return false;
    }
}

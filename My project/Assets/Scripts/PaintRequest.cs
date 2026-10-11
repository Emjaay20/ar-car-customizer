using System;

/// <summary>
/// Paint payload from Flutter. Accepts JSON, a catalog name, a hex color,
/// or a bundle string such as color:#111111;finish:matte.
/// </summary>
[Serializable]
public class PaintRequest
{
    public string color;
    public string finish;
    public string panel;

    public static PaintRequest Parse(string raw)
    {
        var request = new PaintRequest
        {
            color = "white",
            finish = "gloss",
            panel = "body",
        };
        if (string.IsNullOrEmpty(raw))
            return request;

        var token = raw.Trim();
        if (token.StartsWith("{"))
        {
            var parsed = UnityEngine.JsonUtility.FromJson<PaintRequest>(token);
            if (parsed != null)
            {
                request.color = string.IsNullOrEmpty(parsed.color) ? request.color : parsed.color;
                request.finish = NormalizeFinish(parsed.finish);
                request.panel = NormalizePanel(parsed.panel);
                return request;
            }
        }

        var finishTag = ReadTag(token, "finish");
        var colorTag = ReadTag(token, "color");
        request.color = string.IsNullOrEmpty(colorTag) ? token : colorTag;
        request.finish = NormalizeFinish(string.IsNullOrEmpty(finishTag) ? token : finishTag);
        request.panel = "body";
        return request;
    }

    public static string NormalizeFinish(string value)
    {
        if (string.IsNullOrEmpty(value)) return "gloss";
        var token = value.ToLowerInvariant();
        if (token == "gloss" || token == "matte" || token == "satin" || token == "metallic" || token == "candy")
            return token;
        if (token.Contains("matte")) return "matte";
        if (token.Contains("satin")) return "satin";
        if (token.Contains("metallic") || token.Contains("metal")) return "metallic";
        if (token.Contains("candy")) return "candy";
        if (token.Contains("gloss")) return "gloss";
        return "gloss";
    }

    public static string NormalizePanel(string value)
    {
        if (string.IsNullOrEmpty(value)) return "body";
        var token = value.ToLowerInvariant();
        if (token == "door" || token == "doors") return "doors";
        if (token == "hood" || token == "roof" || token == "body") return token;
        return "body";
    }

    public PaintFinishValues FinishValues()
    {
        switch (NormalizeFinish(finish))
        {
            case "matte":
                return new PaintFinishValues(0f, 0.12f, 0.96f);
            case "satin":
                return new PaintFinishValues(0.06f, 0.44f, 0.95f);
            case "metallic":
                return new PaintFinishValues(0.92f, 0.76f, 0.95f);
            case "candy":
                return new PaintFinishValues(0.42f, 0.92f, 0.96f);
            default:
                return new PaintFinishValues(0.10f, 0.90f, 0.95f);
        }
    }

    public float PanelId()
    {
        switch (NormalizePanel(panel))
        {
            case "hood": return 1f;
            case "roof": return 2f;
            case "doors": return 3f;
            default: return 0f;
        }
    }

    static string ReadTag(string raw, string key)
    {
        var needle = key + ":";
        var start = raw.IndexOf(needle, StringComparison.OrdinalIgnoreCase);
        if (start < 0) return null;
        start += needle.Length;
        var end = raw.IndexOf(';', start);
        if (end < 0) end = raw.Length;
        return raw.Substring(start, end - start).Trim();
    }
}

public struct PaintFinishValues
{
    public readonly float metallic;
    public readonly float smoothness;
    public readonly float strength;

    public PaintFinishValues(float metallic, float smoothness, float strength)
    {
        this.metallic = metallic;
        this.smoothness = smoothness;
        this.strength = strength;
    }
}

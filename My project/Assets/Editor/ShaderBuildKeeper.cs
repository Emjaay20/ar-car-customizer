using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

/// <summary>
/// The phone build strips glTFast's shader graphs unless something in the
/// project references them. That is why the preview draws solid magenta.
/// </summary>
public class ShaderBuildKeeper : IPreprocessBuildWithReport
{
    public int callbackOrder => 0;

    static readonly string[] ShaderNames =
    {
        "Shader Graphs/glTF-pbrMetallicRoughness",
        "Shader Graphs/glTF-pbrMetallicRoughness-Clearcoat",
        "Shader Graphs/glTF-unlit",
        "Shader Graphs/glTF-pbrSpecularGlossiness",
        "Universal Render Pipeline/Lit",
        "Universal Render Pipeline/Unlit",
        "Universal Render Pipeline/Simple Lit",
        "ARCar/LivePaint",
        "ARCar/BlobShadow",
        "ARCar/PhotoPaint",
        "ARCar/PhotoGlass",
        "ARCar/ShowroomFrame",
    };

    public void OnPreprocessBuild(BuildReport report)
    {
        Keep();
    }

    [MenuItem("Flutter/Keep Preview Shaders")]
    public static void Keep()
    {
        var folder = "Assets/Resources/ShaderKeep";
        if (!AssetDatabase.IsValidFolder("Assets/Resources"))
            AssetDatabase.CreateFolder("Assets", "Resources");
        if (!AssetDatabase.IsValidFolder(folder))
            AssetDatabase.CreateFolder("Assets/Resources", "ShaderKeep");

        var settings = new SerializedObject(
            AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/GraphicsSettings.asset")[0]);
        var included = settings.FindProperty("m_AlwaysIncludedShaders");
        var added = 0;
        var found = 0;

        foreach (var name in ShaderNames)
        {
            var shader = Shader.Find(name);
            if (shader == null)
            {
                Debug.LogWarning("[AR] Preview shader not in this editor: " + name);
                continue;
            }

            found++;
            if (!Contains(included, shader))
            {
                var index = included.arraySize;
                included.InsertArrayElementAtIndex(index);
                included.GetArrayElementAtIndex(index).objectReferenceValue = shader;
                added++;
            }

            var path = folder + "/" + Safe(name) + ".mat";
            var material = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (material == null)
            {
                material = new Material(shader) { name = Safe(name) };
                AssetDatabase.CreateAsset(material, path);
            }
            else if (material.shader != shader)
            {
                material.shader = shader;
                EditorUtility.SetDirty(material);
            }
        }

        settings.ApplyModifiedProperties();
        AssetDatabase.SaveAssets();
        Debug.Log("[AR] Preview shaders kept. Found " + found + ", newly included " + added + ".");
    }

    static bool Contains(SerializedProperty array, Shader shader)
    {
        for (var i = 0; i < array.arraySize; i++)
        {
            if (array.GetArrayElementAtIndex(i).objectReferenceValue == shader)
                return true;
        }
        return false;
    }

    static string Safe(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '-');
        return name.Replace('/', '-').Replace(' ', '-');
    }
}

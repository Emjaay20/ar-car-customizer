using UnityEditor;

[InitializeOnLoad]
public class AddDefine
{
    static AddDefine()
    {
        var buildTargetGroup = EditorUserBuildSettings.selectedBuildTargetGroup;
        string defines = PlayerSettings.GetScriptingDefineSymbolsForGroup(buildTargetGroup);
        if (!defines.Contains("ARCAR_INFERENCE_ENGINE"))
        {
            PlayerSettings.SetScriptingDefineSymbolsForGroup(buildTargetGroup, defines + ";ARCAR_INFERENCE_ENGINE");
        }
        
        PlayerSettings.insecureHttpOption = InsecureHttpOption.AlwaysAllowed;
    }
}

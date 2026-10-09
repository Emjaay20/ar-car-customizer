// Re-apply Unity 6 patches onto the cached flutter_unity_widget plugin
// before that project is evaluated. flutter pub get does not keep these edits.
val unityWidgetPatches = rootProject.file("unity-widget-patches")
if (unityWidgetPatches.exists()) {
    val unityWidgetProject = rootProject.project(":flutter_unity_widget")
    copy {
        from(unityWidgetPatches)
        into(unityWidgetProject.projectDir)
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        flatDir {
            dirs("${project(":unityLibrary").projectDir}/libs")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

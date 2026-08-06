allprojects {
    repositories {
        google()
        mavenCentral()
        // STAGING ONLY. Remove once com.pay-cross is on Maven Central - which is
        // already in this list, so a merchant will need no repository entry at
        // all. This line exists purely because the SDK is not published yet.
        mavenLocal()
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

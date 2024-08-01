import java.io.ByteArrayOutputStream
import kotlin.Exception

plugins {
    id("base")
    id("xyz.ronella.dotnet.core") version "3.0.0"
}

val dockerImageRegistry = project.findProperty("dockerImageRegistry") as String?
val dockerImageName = project.findProperty("dockerImageName") as String?
if (dockerImageRegistry.isNullOrEmpty()) {
    throw GradleException("A docker image registry must be specified to build an image")
}
if (dockerImageName.isNullOrEmpty()) {
    throw GradleException("A docker image name must be specified to build an image")
}
val dockerFullRegistryImageName = "${dockerImageRegistry}/${dockerImageName}"

val safePath = path.replaceFirst(":", "").replace(":", "_")
val imageIdFile = layout.buildDirectory.file(".docker/$safePath-imageId.txt")
val imageIdFilePublish = layout.buildDirectory.file(".docker/$safePath-imageId-publish.txt")

class LogOutputStream(private val logger: Logger, private val level: LogLevel) : ByteArrayOutputStream() {

    var logHistory: String = String()

    override fun flush() {
        logHistory += toString()
        logger.log(level, toString())
        reset()
    }
}

val buildDockerImageTask = tasks.register("buildDockerImage") {
    description = "Builds a local KafkaClusterMigration Docker image"
    group = "Docker"

    inputs.files(layout.projectDirectory.files(
        "Dockerfile",
        ".dockerignore",
        "./config",
        "./src",
        "pom.xml"
    )).normalizeLineEndings().withPathSensitivity(PathSensitivity.RELATIVE)

    inputs.property("tag", dockerFullRegistryImageName)

    outputs.file(imageIdFile)
    // This task can only use its cache when run in CI mode
    // This means that this task is never up-to-date locally and always runs making use of docker's own layer cache
    outputs.cacheIf { (ext.get("isCI") as Boolean) && (ext.get("cacheDockerBuildTasks") as Boolean) }
    outputs.upToDateWhen { true }

    doLast {
        // Make directory path to output file with the built docker image ID
        imageIdFile.get().asFile.parentFile.mkdirs()

        val logOutputStream = LogOutputStream(logger, LogLevel.LIFECYCLE)
        try {
            project.exec {
                commandLine = listOf("docker", "build", "-t", dockerFullRegistryImageName, "-f", "Dockerfile", ".")
                errorOutput = logOutputStream // docker build logs its output to errorOutput stream in this case
            }

            logOutputStream.logHistory = ""

            project.exec {
                commandLine = listOf("docker", "inspect", "--format={{.Id}}", dockerFullRegistryImageName)
                standardOutput = logOutputStream // docker build logs its output to errorOutput stream in this case
            }
        } catch (ex: Exception) {
            logger.error("Docker build command failed...")
            throw ex
        }

        // Parse output for docker image ID and save it to output file
        val imageId = "${logOutputStream.logHistory}[${dockerFullRegistryImageName}]"

        imageIdFile.get().asFile.writeText(imageId)

        logger.lifecycle("Docker image '${dockerFullRegistryImageName}' built successfully")
    }
}

val publishDockerImage = tasks.register("publishDockerImage") {
    description = "Tags and pushes Docker image produced by '${buildDockerImageTask.name}' task"
    group = "Docker"

    if (dockerImageRegistry.isNullOrEmpty()) {
        throw GradleException("A docker image registry must be specified to publish an image")
    }
    if (dockerImageName.isNullOrEmpty()) {
        throw GradleException("A docker image name must be specified to publish an image")
    }

    dependsOn(buildDockerImageTask)

    inputs.file(imageIdFile).normalizeLineEndings().withPathSensitivity(PathSensitivity.RELATIVE)

    outputs.file(imageIdFilePublish)
    // This task can only use its cache when run in CI mode
    // This means that this task is never up-to-date locally and always runs making use of docker's own layer cache
    outputs.cacheIf { ext.get("isCI") as Boolean }
    // This is required for tasks, that do not have outputs, to be up-to-date if the inputs have not changed
    outputs.upToDateWhen { ext.get("isCI") as Boolean }

    doLast {
        try {
            project.exec {
                commandLine = listOf("docker", "image", "push", dockerFullRegistryImageName)
            }
        } catch (ex: Exception) {
            logger.lifecycle("Docker image push command failed...")
            throw ex
        }
        // Save output file with pushed image id
        imageIdFilePublish.get().asFile.writeText(imageIdFile.get().asFile.readText())
        logger.lifecycle("Docker image '${dockerFullRegistryImageName}' pushed successfully")
    }
}

tasks.publish {
    dependsOn(publishDockerImage)
}

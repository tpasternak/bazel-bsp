package org.jetbrains.bsp.bazel.server.bsp.managers;

import com.google.common.base.Charsets;
import com.google.common.io.CharStreams;
import io.vavr.collection.Array;
import io.vavr.collection.Seq;
import org.jetbrains.bsp.bazel.bazelrunner.params.BazelFlag;
import org.jetbrains.bsp.bazel.commons.Constants;
import org.jetbrains.bsp.bazel.server.bep.BepOutput;
import org.jetbrains.bsp.bazel.server.bsp.utils.InternalAspectsResolver;
import org.jetbrains.bsp.bazel.workspacecontext.TargetsSpec;

import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.file.Paths;

public class BazelBspAspectsManager {

  private final BazelBspCompilationManager bazelBspCompilationManager;
  private final InternalAspectsResolver aspectsResolver;

  public BazelBspAspectsManager(
      BazelBspCompilationManager bazelBspCompilationManager,
      InternalAspectsResolver aspectResolver) {
    this.bazelBspCompilationManager = bazelBspCompilationManager;
    this.aspectsResolver = aspectResolver;
  }


  public BepOutput fetchFilesFromOutputGroups(
      TargetsSpec targetSpecs, String aspect, Seq<String> outputGroups) {
    try {
      Array<String> aspectFlags = semanticDbFlags(aspectsResolver);

      var result =
              bazelBspCompilationManager.buildTargetsWithBep(
                      targetSpecs,
                      Array.of(
                              BazelFlag.repositoryOverride(
                                      Constants.ASPECT_REPOSITORY, aspectsResolver.getBazelBspRoot()),
                              BazelFlag.aspect(aspectsResolver.resolveLabel(aspect)),
                              BazelFlag.outputGroups(outputGroups.toJavaList()),
                              BazelFlag.keepGoing(),
                              BazelFlag.color(true)).appendAll(aspectFlags));
      return result.bepOutput();
    } catch (IOException | InterruptedException e) {
      throw new RuntimeException(e);
    }
  }

  public static Array<String> semanticDbFlags(InternalAspectsResolver aspectsResolver) throws IOException, InterruptedException {
    var pwd = Paths.get(System.getProperty("user.dir"));
    var execroot = Paths.get("bazel-" + pwd.getFileName()).toRealPath();

    String semdbPluginPath = coursierFetchPlugin("com.sourcegraph:semanticdb-javac:0.7.8");
    String semdbScalacPluginPath = coursierFetchPlugin("org.scalameta:semanticdb-scalac_2.12.14:4.5.8");
    var aspectFlags = Array.of(
            BazelFlag.repositoryOverride(
                    Constants.ASPECT_REPOSITORY, aspectsResolver.getBazelBspRoot()),
            "--subcommands",
            BazelFlag.aspect(aspectsResolver.resolveLabel("semanticdb_aspect")),
            "--output_groups=semdb",
            "--define=execroot=" + execroot,
            "--define=semdb_path=" + semdbPluginPath,
            "--define=semdb_javac_path=" + semdbScalacPluginPath,
            "--define=semdb_output=" + pwd.resolve("semdb"),
            "--nojava_header_compilation",
            "--nouse_ijars",
            "--spawn_strategy=local"
    );
    return aspectFlags;
  }

private static String coursierFetchPlugin(String pluginCoordinates) throws IOException, InterruptedException {
    var semdbPluginProcess = Runtime.getRuntime().exec(new String[]{"cs", "fetch", pluginCoordinates, "--classpath", "--exclude", "org.scala-lang:scala-library"});
    semdbPluginProcess.waitFor();
    var semdbPluginPath = CharStreams.toString(new InputStreamReader(semdbPluginProcess.getInputStream(), Charsets.UTF_8)).strip().trim();
    return semdbPluginPath;
  }
}

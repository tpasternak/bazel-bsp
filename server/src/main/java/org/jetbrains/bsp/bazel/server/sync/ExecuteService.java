package org.jetbrains.bsp.bazel.server.sync;

import ch.epfl.scala.bsp4j.*;
import io.vavr.collection.Array;
import io.vavr.collection.List;
import io.vavr.collection.Set;
import org.eclipse.lsp4j.jsonrpc.ResponseErrorException;
import org.eclipse.lsp4j.jsonrpc.messages.ResponseError;
import org.eclipse.lsp4j.jsonrpc.messages.ResponseErrorCode;
import org.jetbrains.bsp.bazel.bazelrunner.BazelProcessResult;
import org.jetbrains.bsp.bazel.bazelrunner.BazelRunner;
import org.jetbrains.bsp.bazel.server.bsp.managers.BazelBspAspectsManager;
import org.jetbrains.bsp.bazel.server.bsp.managers.BazelBspCompilationManager;
import org.jetbrains.bsp.bazel.server.bsp.utils.InternalAspectsResolver;
import org.jetbrains.bsp.bazel.server.sync.model.Module;
import org.jetbrains.bsp.bazel.server.sync.model.Tag;
import org.jetbrains.bsp.bazel.workspacecontext.TargetsSpec;

import java.io.IOException;
import java.util.Collections;

import static org.jetbrains.bsp.bazel.server.sync.BspMappings.getModules;
import static org.jetbrains.bsp.bazel.server.sync.BspMappings.toBspUri;

public class ExecuteService {

  private final BazelBspCompilationManager compilationManager;
  private final ProjectProvider projectProvider;
  private final BazelRunner bazelRunner;
  private final InternalAspectsResolver aspectsResolver;

  public ExecuteService(
          BazelBspCompilationManager compilationManager,
          ProjectProvider projectProvider,
          BazelRunner bazelRunner, InternalAspectsResolver aspectsResolver) {
    this.compilationManager = compilationManager;
    this.projectProvider = projectProvider;
    this.bazelRunner = bazelRunner;
    this.aspectsResolver = aspectsResolver;
  }

  public CompileResult compile(CompileParams params) {
    var targets = selectTargets(params.getTargets());
    var result = build(targets);
    return new CompileResult(result.getStatusCode());
  }

  public TestResult test(TestParams params) {
    var targets = selectTargets(params.getTargets());
    var result = build(targets);

    if (result.isNotSuccess()) {
      return new TestResult(result.getStatusCode());
    }

    result =
        bazelRunner
            .commandBuilder()
            .test()
            .withTargets(targets.map(BspMappings::toBspUri).toJavaList())
            .withArguments(params.getArguments())
            .executeBazelBesCommand()
            .waitAndGetResult();

    return new TestResult(result.getStatusCode());
  }

  public RunResult run(RunParams params) {
    var targets = selectTargets(Collections.singletonList(params.getTarget()));

    if (targets.isEmpty()) {
      throw new ResponseErrorException(
          new ResponseError(
              ResponseErrorCode.InvalidRequest,
              "No supported target found for " + params.getTarget().getUri(),
              null));
    }

    var bspId = targets.single();

    var result = build(targets);

    if (result.isNotSuccess()) {
      return new RunResult(result.getStatusCode());
    }

    var bazelProcessResult =
        bazelRunner
            .commandBuilder()
            .run()
            .withArgument(toBspUri(bspId))
            .withArguments(params.getArguments())
            .executeBazelBesCommand()
            .waitAndGetResult();

    return new RunResult(bazelProcessResult.getStatusCode());
  }

  public CleanCacheResult clean(CleanCacheParams params) {
    var bazelResult =
        bazelRunner.commandBuilder().clean().executeBazelBesCommand().waitAndGetResult();

    return new CleanCacheResult(bazelResult.getStdout(), true);
  }

  private BazelProcessResult build(Set<BuildTargetIdentifier> bspIds) {
    var targetsSpec = new TargetsSpec(bspIds.toJavaList(), Collections.emptyList());
    Array<String> semanticdbFlags;
    try {
      semanticdbFlags = BazelBspAspectsManager.semanticDbFlags(aspectsResolver);
    } catch (IOException | InterruptedException e) {
      throw new RuntimeException(e);
    }
    return compilationManager
            .buildTargetsWithBep(targetsSpec, semanticdbFlags)
            .processResult();
  }

  private Set<BuildTargetIdentifier> selectTargets(java.util.List<BuildTargetIdentifier> targets) {
    var project = projectProvider.get();
    var modules = getModules(project, targets);
    var modulesToBuild = modules.filter(this::isBuildable);
    return modulesToBuild.map(BspMappings::toBspId);
  }

  private boolean isBuildable(Module m) {
    return !m.isSynthetic() && !m.tags().contains(Tag.NO_BUILD);
  }
}

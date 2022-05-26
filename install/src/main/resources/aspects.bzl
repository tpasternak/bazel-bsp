load("@io_bazel_rules_kotlin//kotlin/internal/jvm:compile.bzl", "kt_jvm_produce_jar_actions2")
load("@io_bazel_rules_kotlin//kotlin/internal:defs.bzl", "KtJvmInfo")
load("@io_bazel_rules_kotlin//kotlin/internal/jvm:associates.bzl", "associate_utils")
load(
    "@io_bazel_rules_kotlin//kotlin/internal:defs.bzl",
    _KtJvmInfo = "KtJvmInfo",
)
load(
    "@io_bazel_rules_kotlin//kotlin/internal/utils:sets.bzl",
    _sets = "sets",
)
load(
    "@io_bazel_rules_kotlin//kotlin/internal/utils:utils.bzl",
    _utils = "utils",
)

load("@io_bazel_rules_scala//scala/private:rule_impls.bzl", "compile_scala")
load("@io_bazel_rules_scala//scala/private:common.bzl", "write_manifest_file")

load(
    "@io_bazel_rules_scala//scala/private:common_attributes.bzl",
    "common_attrs",
    "common_attrs_for_plugin_bootstrapping",
    "implicit_deps",
    "resolve_deps",
)
def _scala_compiler_classpath_impl(target, ctx):
    files = depset()
    if hasattr(ctx.rule.attr, "jars"):
        for target in ctx.rule.attr.jars:
            files = depset(transitive = [files, target.files])

    compiler_classpath_file = ctx.actions.declare_file("%s.textproto" % target.label.name)
    ctx.actions.write(compiler_classpath_file, struct(files = [file.path for file in files.to_list()]).to_proto())

    return [
        OutputGroupInfo(scala_compiler_classpath_files = [compiler_classpath_file]),
    ]

scala_compiler_classpath_aspect = aspect(
    implementation = _scala_compiler_classpath_impl,
)

def _java_runtime_classpath_impl(target, ctx):
    files = depset()
    if JavaInfo in target:
        java_info = target[JavaInfo]
        files = java_info.compilation_info.runtime_classpath if java_info.compilation_info else java_info.transitive_runtime_jars

    output_file = ctx.actions.declare_file("%s-runtime_classpath.textproto" % target.label.name)
    ctx.actions.write(output_file, struct(files = [file.path for file in files.to_list()]).to_proto())

    return [
        OutputGroupInfo(java_runtime_classpath_files = [output_file]),
    ]

java_runtime_classpath_aspect = aspect(
    implementation = _java_runtime_classpath_impl,
)

def filter(f, xs):
    return [x for x in xs if f(x)]

def map(f, xs):
    return [f(x) for x in xs]

def map_not_none(f, xs):
    rs = [f(x) for x in xs if x != None]
    return [r for r in rs if r != None]

def map_with_resolve_files(f, xs):
    results = []
    resolve_files = []

    for x in xs:
        if x != None:
            res = f(x)
            if res != None:
                a, b = res
                if a != None:
                    results.append(a)
                if b != None:
                    resolve_files += b

    return results, resolve_files

def distinct(xs):
    seen = dict()
    res = []
    for x in xs:
        if x not in seen:
            seen[x] = True
            res.add(x)
    return res

def file_location(file):
    if file == None:
        return None

    return to_file_location(
        file.path,
        file.root.path if not file.is_source else "",
        file.is_source,
        file.owner.workspace_root.startswith("..") or file.owner.workspace_root.startswith("external"),
    )

def _strip_root_exec_path_fragment(path, root_fragment):
    if root_fragment and path.startswith(root_fragment + "/"):
        return path[len(root_fragment + "/"):]
    return path

def _strip_external_workspace_prefix(path):
    if path.startswith("../") or path.startswith("external/"):
        return "/".join(path.split("/")[2:])
    return path

def to_file_location(exec_path, root_exec_path_fragment, is_source, is_external):
    # directory structure:
    # exec_path = (../repo_name)? + (root_fragment)? + relative_path
    relative_path = _strip_external_workspace_prefix(exec_path)
    relative_path = _strip_root_exec_path_fragment(relative_path, root_exec_path_fragment)

    root_exec_path_fragment = exec_path[:-(len("/" + relative_path))] if relative_path != "" else exec_path

    return struct(
        relative_path = relative_path,
        is_source = is_source,
        is_external = is_external,
        root_execution_path_fragment = root_exec_path_fragment,
    )

def get_java_provider(target):
    if hasattr(target, "scala"):
        return target.scala
    if hasattr(target, "kt") and hasattr(target.kt, "outputs"):
        return target.kt
    if JavaInfo in target:
        return target[JavaInfo]
    return None

def get_interface_jars(output):
    if hasattr(output, "compile_jar") and output.compile_jar:
        return [output.compile_jar]
    elif hasattr(output, "ijar") and output.ijar:
        return [output.ijar]
    else:
        return []

def get_source_jars(output):
    if hasattr(output, "source_jars"):
        return output.source_jars
    if hasattr(output, "source_jar"):
        return [output.source_jar]
    return []

def get_generated_jars(provider):
    if hasattr(provider, "java_outputs"):
        return map_with_resolve_files(to_generated_jvm_outputs, provider.java_outputs)

    if hasattr(provider, "annotation_processing") and provider.annotation_processing and provider.annotation_processing.enabled:
        class_jar = provider.annotation_processing.class_jar
        source_jar = provider.annotation_processing.source_jar
        output = struct(
            binary_jars = [file_location(class_jar)],
            source_jars = [file_location(source_jar)],
        )
        resolve_files = [class_jar, source_jar]
        return [output], resolve_files

    return [], []

def to_generated_jvm_outputs(output):
    if output == None or output.generated_class_jar == None:
        return None

    class_jar = output.generated_class_jar
    source_jar = output.generated_source_jar

    output = struct(
        binary_jars = [file_location(class_jar)],
        source_jars = [file_location(source_jar)],
    )
    resolve_files = [class_jar, source_jar]
    return output, resolve_files

def to_jvm_outputs(output):
    if output == None or output.class_jar == None:
        return None

    binary_jars = [output.class_jar]
    interface_jars = get_interface_jars(output)
    source_jars = get_source_jars(output)
    output = struct(
        binary_jars = map(file_location, binary_jars),
        interface_jars = map(file_location, interface_jars),
        source_jars = map(file_location, source_jars),
    )
    resolve_files = binary_jars + interface_jars + source_jars
    return output, resolve_files

def extract_scala_info(target, ctx, output_groups):
    provider = get_java_provider(target)
    if not provider:
        return None

    scalac_opts = getattr(ctx.rule.attr, "scalacopts", [])

    scala_info = struct(
        scalac_opts = scalac_opts,
    )
    return scala_info

def extract_runtime_jars(target, provider):
    compilation_info = getattr(provider, "compilation_info", None)

    if compilation_info:
        return compilation_info.runtime_classpath

    return getattr(provider, "transitive_runtime_jars", target[JavaInfo].transitive_runtime_jars)

def extract_compile_jars(provider):
    compilation_info = getattr(provider, "compilation_info", None)

    return compilation_info.compilation_classpath if compilation_info else provider.transitive_compile_time_jars

def extract_java_info(target, ctx, output_groups):
    provider = get_java_provider(target)
    if not provider:
        return None

    if hasattr(provider, "java_outputs") and provider.java_outputs:
        java_outputs = provider.java_outputs
    elif hasattr(provider, "outputs") and provider.outputs:
        java_outputs = provider.outputs.jars
    else:
        return None

    resolve_files = []

    jars, resolve_files_jars = map_with_resolve_files(to_jvm_outputs, java_outputs)
    resolve_files += resolve_files_jars

    generated_jars, resolve_files_generated_jars = get_generated_jars(provider)
    resolve_files += resolve_files_generated_jars

    runtime_jars = extract_runtime_jars(target, provider).to_list()
    compile_jars = extract_compile_jars(provider).to_list()
    source_jars = provider.transitive_source_jars.to_list()
    resolve_files += runtime_jars
    resolve_files += compile_jars
    resolve_files += source_jars

    runtime_classpath = map(file_location, runtime_jars)
    compile_classpath = map(file_location, compile_jars)
    source_classpath = map(file_location, source_jars)

    javac_opts = getattr(ctx.rule.attr, "javacopts", [])
    jvm_flags = getattr(ctx.rule.attr, "jvm_flags", [])
    args = getattr(ctx.rule.attr, "args", [])
    main_class = getattr(ctx.rule.attr, "main_class", None)

    update_sync_output_groups(output_groups, "bsp-ide-resolve", depset(resolve_files))

    return create_struct(
        jars = jars,
        generated_jars = generated_jars,
        runtime_classpath = runtime_classpath,
        compile_classpath = compile_classpath,
        source_classpath = source_classpath,
        javac_opts = javac_opts,
        jvm_flags = jvm_flags,
        main_class = main_class,
        args = args,
    )

def find_scalac_classpath(runfiles):
    result = []
    for file in runfiles:
        name = file.basename
        if file.extension == "jar" and ("scala-compiler" in name or "scala-library" in name or "scala-reflect" in name):
            result.append(file)
    return result if len(result) >= 3 else []

def extract_scala_toolchain_info(target, ctx, output_groups):
    runfiles = target.default_runfiles.files.to_list()

    classpath = find_scalac_classpath(runfiles)

    if not classpath:
        return None

    resolve_files = classpath
    compiler_classpath = map(file_location, classpath)

    update_sync_output_groups(output_groups, "bsp-ide-resolve", depset(resolve_files))

    return struct(compiler_classpath = compiler_classpath)

def create_struct(**kwargs):
    d = {name: kwargs[name] for name in kwargs if kwargs[name] != None}
    return struct(**d)

def extract_java_toolchain(target, ctx, dep_targets):
    toolchain = None

    if hasattr(target, "java_toolchain"):
        toolchain = target.java_toolchain
    elif java_common.JavaToolchainInfo != platform_common.ToolchainInfo and \
         java_common.JavaToolchainInfo in target:
        toolchain = target[java_common.JavaToolchainInfo]

    toolchain_info = None
    if toolchain != None:
        java_home = to_file_location(toolchain.java_runtime.java_home, "", False, True) if hasattr(toolchain, "java_runtime") else None
        toolchain_info = create_struct(
            source_version = toolchain.source_version,
            target_version = toolchain.target_version,
            java_home = java_home,
        )
    else:
        for dep in dep_targets:
            if hasattr(dep.bsp_info, "java_toolchain_info"):
                toolchain_info = dep.bsp_info.java_toolchain_info
                break

    if toolchain_info != None:
        return toolchain_info, dict(java_toolchain_info = toolchain_info)
    else:
        return None, dict()

def extract_java_runtime(target, ctx, dep_targets):
    runtime = None

    if java_common.JavaRuntimeInfo in target:
        runtime = target[java_common.JavaRuntimeInfo]
    else:
        runtime_jdk = getattr(ctx.rule.attr, "runtime_jdk", None)
        if runtime_jdk and java_common.JavaRuntimeInfo in runtime_jdk:
            runtime = runtime_jdk[java_common.JavaRuntimeInfo]

    runtime_info = None
    if runtime != None:
        java_home = to_file_location(runtime.java_home, "", False, True) if hasattr(runtime, "java_home") else None
        runtime_info = create_struct(java_home = java_home)
    else:
        for dep in dep_targets:
            if hasattr(dep.bsp_info, "java_runtime_info"):
                runtime_info = dep.bsp_info.java_runtime_info
                break

    if runtime_info != None:
        return runtime_info, dict(java_runtime_info = runtime_info)
    else:
        return None, dict()

def get_aspect_ids(ctx, target):
    """Returns the all aspect ids, filtering out self."""
    aspect_ids = None
    if hasattr(ctx, "aspect_ids"):
        aspect_ids = ctx.aspect_ids
    elif hasattr(target, "aspect_ids"):
        aspect_ids = target.aspect_ids
    else:
        return None
    return [aspect_id for aspect_id in aspect_ids if "bsp_target_info_aspect" not in aspect_id]

def abs(num):
    if num < 0:
        return -num
    else:
        return num

def update_sync_output_groups(groups_dict, key, new_set):
    update_set_in_dict(groups_dict, key + "-transitive-deps", new_set)
    update_set_in_dict(groups_dict, key + "-outputs", new_set)
    update_set_in_dict(groups_dict, key + "-direct-deps", new_set)

def update_set_in_dict(input_dict, key, other_set):
    input_dict[key] = depset(transitive = [input_dict.get(key, depset()), other_set])

def _collect_target_from_attr(rule_attrs, attr_name, result):
    """Collects the targets from the given attr into the result."""
    if not hasattr(rule_attrs, attr_name):
        return
    attr_value = getattr(rule_attrs, attr_name)
    type_name = type(attr_value)
    if type_name == "Target":
        result.append(attr_value)
    elif type_name == "list":
        result.extend(attr_value)

def is_valid_aspect_target(target):
    return hasattr(target, "bsp_info")

def collect_targets_from_attrs(rule_attrs, attrs):
    result = []
    for attr_name in attrs:
        _collect_target_from_attr(rule_attrs, attr_name, result)
    return [target for target in result if is_valid_aspect_target(target)]

COMPILE = 0
RUNTIME = 1

COMPILE_DEPS = [
    "deps",
    "jars",
    "exports",
]

PRIVATE_COMPILE_DEPS = [
    "_java_toolchain",
    "_scala_toolchain",
    "_scalac",
    "_jvm",
    "runtime_jdk",
]

RUNTIME_DEPS = [
    "runtime_deps",
]

ALL_DEPS = COMPILE_DEPS + PRIVATE_COMPILE_DEPS + RUNTIME_DEPS

def make_dep(dep, dependency_type):
    return struct(
        id = str(dep.bsp_info.id),
        dependency_type = dependency_type,
    )

def make_deps(deps, dependency_type):
    return [make_dep(dep, dependency_type) for dep in deps]

def _is_proto_library_wrapper(target, ctx):
    if not ctx.rule.kind.endswith("proto_library") or ctx.rule.kind == "proto_library":
        return False

    deps = collect_targets_from_attrs(ctx.rule.attr, ["deps"])
    return len(deps) == 1 and deps[0].bsp_info and deps[0].bsp_info.kind == "proto_library"

def _get_forwarded_deps(target, ctx):
    if _is_proto_library_wrapper(target, ctx):
        return collect_targets_from_attrs(ctx.rule.attr, ["deps"])
    return []

def _bsp_target_info_aspect_impl(target, ctx):
    rule_attrs = ctx.rule.attr

    direct_dep_targets = collect_targets_from_attrs(rule_attrs, COMPILE_DEPS)
    private_direct_dep_targets = collect_targets_from_attrs(rule_attrs, PRIVATE_COMPILE_DEPS)
    direct_deps = make_deps(direct_dep_targets, COMPILE)

    exported_deps_from_deps = []
    for dep in direct_dep_targets:
        exported_deps_from_deps = exported_deps_from_deps + dep.bsp_info.export_deps

    compile_deps = direct_deps + exported_deps_from_deps

    runtime_dep_targets = collect_targets_from_attrs(rule_attrs, RUNTIME_DEPS)
    runtime_deps = make_deps(runtime_dep_targets, RUNTIME)

    all_deps = depset(compile_deps + runtime_deps).to_list()

    # Propagate my own exports
    export_deps = []
    direct_exports = []
    if JavaInfo in target:
        direct_exports = collect_targets_from_attrs(rule_attrs, ["exports"])
        export_deps.extend(make_deps(direct_exports, COMPILE))
        for export in direct_exports:
            export_deps.extend(export.bsp_info.export_deps)
        export_deps = depset(export_deps).to_list()

    forwarded_deps = _get_forwarded_deps(target, ctx) + direct_exports

    dep_targets = direct_dep_targets + private_direct_dep_targets + runtime_dep_targets + direct_exports
    output_groups = dict()
    for dep in dep_targets:
        for k, v in dep.bsp_info.output_groups.items():
            if dep in forwarded_deps:
                output_groups[k] = output_groups[k] + [v] if k in output_groups else [v]
            elif k.endswith("-direct-deps"):
                pass
            elif k.endswith("-outputs"):
                directs = k[:-len("outputs")] + "direct-deps"
                output_groups[directs] = output_groups[directs] + [v] if directs in output_groups else [v]
            else:
                output_groups[k] = output_groups[k] + [v] if k in output_groups else [v]

    for k, v in output_groups.items():
        output_groups[k] = depset(transitive = v)

    sources = [
        file_location(f)
        for t in getattr(ctx.rule.attr, "srcs", [])
        for f in t.files.to_list()
        if f.is_source
    ]

    resources = [
        file_location(f)
        for t in getattr(ctx.rule.attr, "resources", [])
        for f in t.files.to_list()
    ]

    java_target_info = extract_java_info(target, ctx, output_groups)
    scala_toolchain_info = extract_scala_toolchain_info(target, ctx, output_groups)
    scala_target_info = extract_scala_info(target, ctx, output_groups)
    java_toolchain_info, java_toolchain_info_exported = extract_java_toolchain(target, ctx, dep_targets)
    java_runtime_info, java_runtime_info_exported = extract_java_runtime(target, ctx, dep_targets)

    result = dict(
        id = str(target.label),
        kind = ctx.rule.kind,
        tags = rule_attrs.tags,
        dependencies = list(all_deps),
        sources = sources,
        resources = resources,
        scala_target_info = scala_target_info,
        scala_toolchain_info = scala_toolchain_info,
        java_target_info = java_target_info,
        java_toolchain_info = java_toolchain_info,
        java_runtime_info = java_runtime_info,
    )

    file_name = target.label.name
    file_name = file_name + "-" + str(abs(hash(file_name)))
    aspect_ids = get_aspect_ids(ctx, target)
    if aspect_ids:
        file_name = file_name + "-" + str(abs(hash(".".join(aspect_ids))))
    file_name = "%s.bsp-info.textproto" % file_name
    info_file = ctx.actions.declare_file(file_name)
    ctx.actions.write(info_file, create_struct(**result).to_proto())
    update_sync_output_groups(output_groups, "bsp-target-info", depset([info_file]))

    exported_properties = dict(
        id = target.label,
        kind = ctx.rule.kind,
        export_deps = export_deps,
        output_groups = output_groups,
    )
    exported_properties.update(java_toolchain_info_exported)
    exported_properties.update(java_runtime_info_exported)

    return struct(
        bsp_info = struct(**exported_properties),
        output_groups = output_groups,
    )

bsp_target_info_aspect = aspect(
    implementation = _bsp_target_info_aspect_impl,
    required_aspect_providers = [[JavaInfo]],
    attr_aspects = ALL_DEPS,
)

def _fetch_cpp_compiler(target, ctx):
    if cc_common.CcToolchainInfo in target:
        toolchain_info = target[cc_common.CcToolchainInfo]
        print(toolchain_info.compiler)
        print(toolchain_info.compiler_executable)
    return []

fetch_cpp_compiler = aspect(
    implementation = _fetch_cpp_compiler,
    fragments = ["cpp"],
    attr_aspects = ["_cc_toolchain"],
    required_aspect_providers = [[CcInfo]],
)

def _fetch_java_target_version(target, ctx):
    print(target[java_common.JavaToolchainInfo].target_version)
    return []

fetch_java_target_version = aspect(
    implementation = _fetch_java_target_version,
    attr_aspects = ["_java_toolchain"],
)

def _fetch_java_target_home(target, ctx):
    print(target[java_common.JavaRuntimeInfo].java_home)
    return []

fetch_java_target_home = aspect(
    implementation = _fetch_java_target_home,
    attr_aspects = ["_java_toolchain"],
)

def _get_target_info(ctx, field_name):
    fields = getattr(ctx.rule.attr, field_name, [])
    fields = [ctx.expand_location(field) for field in fields]
    fields = [ctx.expand_make_variables(field_name, field, {}) for field in fields]

    return fields

def _print_fields(fields):
    separator = ","
    print(separator.join(fields))

def _get_cpp_target_info(target, ctx):
    if CcInfo not in target:
        return []

    #TODO: Get copts from semantics
    copts = _get_target_info(ctx, "copts")
    defines = _get_target_info(ctx, "defines")
    linkopts = _get_target_info(ctx, "linkopts")

    linkshared = False
    if hasattr(ctx.rule.attr, "linkshared"):
        linkshared = ctx.rule.attr.linkshared

    _print_fields(copts)
    _print_fields(defines)
    _print_fields(linkopts)
    print(linkshared)

    return []

get_cpp_target_info = aspect(
    implementation = _get_cpp_target_info,
    fragments = ["cpp"],
    required_aspect_providers = [[CcInfo]],
)

# bazel build --subcommands --verbose_failures  //...:all  --aspects .bazelbsp/aspects.bzl%semanticdb_aspect --output_groups=semdb --define=execroot=$(realpath bazel-$(basename $(pwd))) --define=semdb_path=$(cs fetch com.sourcegraph:semanticdb-javac:0.7.8 --classpath) --define=semdb_output=$(pwd)/semdb --nojava_header_compilation --spawn_strategy=local

Jcc = provider(
    fields = {
        "jcc" : "jcc",
        "targets" : "targets"
    }
)
def get_associates(ctx):
    """Creates a struct of associates meta data"""

    friends_legacy = getattr(ctx.rule.attr, "friends", [])
    associates = getattr(ctx.rule.attr, "associates", [])

    if friends_legacy:
        print("WARNING: friends=[...] is deprecated, please prefer associates=[...] instead.")
        if associates:
            fail("friends= may not be used together with associates=. Use one or the other.")
        elif ctx.rule.attr.testonly == False:
            fail("Only testonly targets can use the friends attribute. ")
        else:
            associates = friends_legacy

    if not bool(associates):
        return struct(
            targets = [],
            module_name = _utils.derive_module_name(ctx),
            jars = [],
        )
    elif ctx.rule.attr.module_name:
        fail("if associates have been set then module_name cannot be provided")
    else:
        jars = [depset([a], transitive = a.kt.module_jars) for a in associates]
        module_names = _sets.copy_of([x.kt.module_name for x in associates])
        if len(module_names) > 1:
            fail("Dependencies from several different kotlin modules cannot be associated. " +
                 "Associates can see each other's \"internal\" members, and so must only be " +
                 "used with other targets in the same module: \n%s" % module_names)
        if len(module_names) < 1:
            # This should be impossible
            fail("Error in rules - a KtJvmInfo was found which did not have a module_name")
        return struct(
            targets = associates,
            jars = jars,
            module_name = list(module_names)[0],
        )

def get_plugin(ctx, plugin_path, output_name):
    semjar = ctx.actions.declare_file(output_name) #todo, logs from plugin are silenced

    semdbJavaInfo = JavaInfo(semjar, semjar)
    ctx.actions.run_shell(# todo use actions.symlink
        command="ln -s {} {} ".format(plugin_path, semjar.path),
        outputs=[semjar]
        )
    return JavaPluginInfo([semdbJavaInfo], processor_class= None)

def _semanticdb_aspect(target, ctx):
    if (not hasattr(ctx.rule.attr, "deps")) or (not hasattr(ctx.rule.attr, "srcs")):
      return []

    deps1 = [d for dep in ctx.rule.attr.deps for d in ([dep[JavaInfo]] if JavaInfo in dep else [])] #todo kotlin java info
    deps2 = [d for dep in ctx.rule.attr.deps for d in (dep[Jcc].jcc if Jcc in dep and repr(dep.label).startswith("@") else [])]
    deps3 = [d.kt for d in ctx.rule.attr.deps if KtJvmInfo in d] #todo kotlin java info # contains Target type
    deps = deps1 + deps2
    depTargetsFromRules = ctx.rule.attr.deps
    depTargetsFromDeps =  [t for dep in ctx.rule.attr.deps if Jcc in dep for t in dep[Jcc].targets ]

    associates = associate_utils.get_associates(ctx)
    associates3 = get_associates(ctx)

    depTargetsFromAssociates = ctx.rule.attr.associates if hasattr(ctx.rule.attr, "associates") else []
    depTargets = [d for d in depTargetsFromRules + depTargetsFromDeps if JavaInfo in d]

    inputs = depset([x for src in ctx.rule.attr.srcs for x in src.files.to_list()])
    plugin_jar = ctx.var["semdb_path"]
    scalac_plugin_jar = ctx.var["semdb_scalac_path"]
    semdb_output = ctx.var["semdb_output"]
    execroot = ctx.var["execroot"]

    semdbJavaInfo = get_plugin(ctx, plugin_jar,"semanticdb_plugin.jar") #todo, logs from plugin are silenced



    if(ctx.rule.kind.startswith("scala")):
        # todo for some reason this requires "bazel build /scala_library1" before
        out = ctx.actions.declare_file(ctx.label.name + "-with-semdb.jar")
        scalac_options = [
            "-Xplugin:{}".format(scalac_plugin_jar)
        ]

        manifest = ctx.actions.declare_file(ctx.label.name + "-manifest-with-semdb.jar")
        statsfile = ctx.actions.declare_file(ctx.label.name + "-statsfile-with-semdb.jar")
        diagnosticsFile = ctx.actions.declare_file(ctx.label.name + "-diagnostics-with-semdb.jar")

        write_manifest_file(ctx.actions, manifest, None)

        res = compile_scala(
            ctx,
            target_label = "target_label",
            output = out,
            manifest =manifest,
            statsfile =statsfile,
            diagnosticsfile =diagnosticsFile,
            sources= inputs.to_list(),
            cjars = ctx.rule.attr._scalac.data_runfiles.files,
            all_srcjars = depset([]),
            transitive_compile_jars = [], #= ctx.rule.attr._scalac.data_runfiles,
            plugins =[],
            resource_strip_prefix =[],
            resources =[],
            resource_jars =[],
            labels =[],
            in_scalacopts =scalac_options,
            print_compile_time =False,
            expect_java_output =False,
            scalac_jvm_flags= [],
            scalac= ctx.rule.attr._scalac.files.to_list()[1],
            dependency_info= struct(use_analyzer = False,
                                    dependency_mode = "direct",
                                    strict_deps_mode = "off",
                                    unused_deps_mode = "off",
                                    dependency_tracking_method = "bazinga",
                                    need_indirect_info = False,
                                    need_direct_info = False),
            unused_dependency_checker_ignored_targets=[]
        )
        return [

                                OutputGroupInfo(
                                  semdb = [out, statsfile, diagnosticsFile]
                                ),
                                Jcc(
                                  jcc = deps,
                                  targets = depTargets
                                       )
                  ]

    if ctx.rule.kind.startswith("kt"):
        out = ctx.actions.declare_file(ctx.label.name + "-with-semdb.jar")
        tcs = struct(
          kt = ctx.toolchains["@io_bazel_rules_kotlin//kotlin/internal:kt_toolchain_type"],
          java = ctx.rule.attr._java_toolchain.java_toolchain,
          java_runtime = ctx.rule.attr._host_javabase,
        )

        kt_res = kt_jvm_produce_jar_actions2(ctx,
           "kt_jvm_library",
           tcs,
           inputs.to_list(),
           depTargets,
           ctx.rule.attr.runtime_deps,
           ctx.rule.attr.plugins,
           ctx.rule.attr.tags,
           [],
           "-with-semdb",
           ["\"-Xplugin:semanticdb -sourceroot:{} -verbose -targetroot:{}\"".format(execroot, semdb_output)],
           associates3,
           [semdbJavaInfo]
           )

        outputs = [x.class_jar for x  in (kt_res.java.outputs.jars) + (kt_res.kt.outputs.jars)]

        return [
                 OutputGroupInfo(
                   semdb = outputs
                 ),
                 Jcc(
                   jcc = [kt_res.java] +deps  + [kt_res.kt],
                   targets = depTargets
                 )
        ]
    if ctx.rule.kind.startswith("java") and hasattr(ctx.rule.attr, "_java_toolchain"):
        out = ctx.actions.declare_file(ctx.label.name + "-with-semdb.jar")
        java_exec = ctx.rule.attr._java_toolchain.java_toolchain.java_runtime.java_executable_exec_path
        jvm_opt = ctx.rule.attr._java_toolchain.java_toolchain.jvm_opt
        toolchain = ctx.rule.attr._java_toolchain.java_toolchain

        jcc = java_common.compile(
            ctx,
            deps = deps,
            output = out,
            plugins = [semdbJavaInfo],
            java_toolchain = ctx.rule.attr._java_toolchain.java_toolchain,
            source_files = inputs.to_list() ,
            javac_opts = ["\"-Xplugin:semanticdb -sourceroot:{} -verbose -targetroot:{}\"".format(execroot, semdb_output)],
        )
        return [
            OutputGroupInfo(
                semdb = ([out])
            ),
            Jcc(jcc = [jcc] + deps,
                targets = depTargets)
        ]
    return []
semanticdb_aspect = aspect(
    implementation = _semanticdb_aspect,
    attr_aspects = ["deps", "associates"],
    fragments = ["java"],
    host_fragments = ["java"],
    toolchains = ["@io_bazel_rules_kotlin//kotlin/internal:kt_toolchain_type", "@io_bazel_rules_scala//scala:toolchain_type"],
)
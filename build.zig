const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const use_new = builtin.zig_version.minor >= 15;
    const root_path = if (use_new) "src/new.zig" else "src/old.zig";

    const shrivel = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
    });

    const main_test = b.addTest(.{
        .name = "test",
        .root_module = shrivel,
    });
    const run_test_new = b.addRunArtifact(main_test);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_test_new.step);

    _ = addFuzzer(b, "fuzz", &.{}, shrivel);
    _ = addFuzzer(b, "fuzz-old", &.{}, shrivel);
}

fn addFuzzer(
    b: *std.Build,
    comptime name: []const u8,
    afl_clang_args: []const []const u8,
    mod: *std.Build.Module,
) FuzzerSteps {
    const target = b.resolveTargetQuery(.{});

    // The library
    const fuzz_lib = b.addLibrary(.{
        .name = name ++ "-lib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/" ++ name ++ ".zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    fuzz_lib.root_module.addImport("shrivel", mod);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    // Seems to be necessary for LLVM >= 15
    fuzz_lib.root_module.pic = true;
    fuzz_lib.use_llvm = true;
    fuzz_lib.use_lld = true;

    // Setup the output name
    const fuzz_executable_name = name;

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o" });
    const fuzz_exe_path = fuzz_compile.addOutputFileArg(name);
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);
    // Custom args
    fuzz_compile.addArgs(afl_clang_args);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(fuzz_exe_path, fuzz_executable_name);
    fuzz_install.step.dependOn(&fuzz_compile.step);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(name, "Build executable for fuzz testing '" ++ name ++ "' using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = name ++ "-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/" ++ name ++ ".zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    fuzz_debug_exe.root_module.addImport("shrivel", mod);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    // Add a top-level step that compiles and installs only the debug executable
    const fuzz_debug_compile_run = b.step(name ++ "-debug", "Build executable for debugging '" ++ name ++ "'");
    fuzz_debug_compile_run.dependOn(&install_fuzz_debug_exe.step);

    return FuzzerSteps{
        .lib = fuzz_lib,
        .debug_exe = fuzz_debug_exe,
    };
}

const FuzzerSteps = struct {
    lib: *std.Build.Step.Compile,
    debug_exe: *std.Build.Step.Compile,

    pub fn libExes(self: *const FuzzerSteps) [2]*std.Build.Step.Compile {
        return [_]*std.Build.Step.Compile{ self.lib, self.debug_exe };
    }
};

//! Here we test our MachO linker for correctness and functionality.
//! TODO migrate standalone tests from test/link/macho/* to here.

pub fn testAll(b: *std.Build) *Step {
    const macho_step = b.step("test-macho", "Run MachO tests");

    const default_target = b.resolveTargetQuery(.{
        .os_tag = .macos,
    });

    macho_step.dependOn(testEntryPointDylib(b, .{ .target = default_target }));
    macho_step.dependOn(testSectionBoundarySymbols(b, .{ .target = default_target }));

    return macho_step;
}

fn testEntryPointDylib(b: *std.Build, opts: Options) *Step {
    const test_step = addTestStep(b, "macho-entry-point-dylib", opts);

    const dylib = addSharedLibrary(b, opts, .{ .name = "liba.dylib" });
    addCSourceBytes(dylib,
        \\extern int my_main();
        \\int bootstrap() {
        \\  return my_main();
        \\}
    , &.{});
    dylib.linker_allow_shlib_undefined = true;

    const exe = addExecutable(b, opts, .{ .name = "main" });
    addCSourceBytes(dylib,
        \\#include<stdio.h>
        \\int my_main() {
        \\  fprintf(stdout, "Hello!\n");
        \\  return 0;
        \\}
    , &.{});
    exe.linkLibrary(dylib);
    exe.entry = .{ .symbol_name = "_bootstrap" };
    exe.forceUndefinedSymbol("_my_main");

    const check = exe.checkObject();
    check.checkInHeaders();
    check.checkExact("segname __TEXT");
    check.checkExtract("vmaddr {text_vmaddr}");
    check.checkInHeaders();
    check.checkExact("sectname __stubs");
    check.checkExtract("addr {stubs_vmaddr}");
    check.checkInHeaders();
    check.checkExact("sectname __stubs");
    check.checkExtract("size {stubs_vmsize}");
    check.checkInHeaders();
    check.checkExact("cmd MAIN");
    check.checkExtract("entryoff {entryoff}");
    check.checkComputeCompare("text_vmaddr entryoff +", .{
        .op = .gte,
        .value = .{ .variable = "stubs_vmaddr" }, // The entrypoint should be a synthetic stub
    });
    check.checkComputeCompare("text_vmaddr entryoff + stubs_vmaddr -", .{
        .op = .lt,
        .value = .{ .variable = "stubs_vmsize" }, // The entrypoint should be a synthetic stub
    });
    test_step.dependOn(&check.step);

    const run = addRunArtifact(exe);
    run.expectStdOutEqual("Hello!\n");
    test_step.dependOn(&run.step);

    return test_step;
}

fn testSectionBoundarySymbols(b: *std.Build, opts: Options) *Step {
    const test_step = addTestStep(b, "macho-section-boundary-symbols", opts);

    const obj1 = addObject(b, opts, .{
        .name = "obj1",
        .cpp_source_bytes =
        \\constexpr const char* MESSAGE __attribute__((used, section("__DATA_CONST,__message_ptr"))) = "codebase";
        ,
    });

    const main_o = addObject(b, opts, .{
        .name = "main",
        .zig_source_bytes =
        \\const std = @import("std");
        \\extern fn interop() ?[*:0]const u8;
        \\pub fn main() !void {
        \\    std.debug.print("All your {s} are belong to us.\n", .{
        \\        if (interop()) |ptr| std.mem.span(ptr) else "(null)",
        \\    });
        \\}
        ,
    });

    {
        const obj2 = addObject(b, opts, .{
            .name = "obj2",
            .cpp_source_bytes =
            \\extern const char* message_pointer __asm("section$start$__DATA_CONST$__message_ptr");
            \\extern "C" const char* interop() {
            \\  return message_pointer;
            \\}
            ,
        });

        const exe = addExecutable(b, opts, .{ .name = "test" });
        exe.addObject(obj1);
        exe.addObject(obj2);
        exe.addObject(main_o);

        const run = b.addRunArtifact(exe);
        run.skip_foreign_checks = true;
        run.expectStdErrEqual("All your codebase are belong to us.\n");
        test_step.dependOn(&run.step);

        const check = exe.checkObject();
        check.checkInSymtab();
        check.checkNotPresent("external section$start$__DATA_CONST$__message_ptr");
        test_step.dependOn(&check.step);
    }

    {
        const obj3 = addObject(b, opts, .{
            .name = "obj3",
            .cpp_source_bytes =
            \\extern const char* message_pointer __asm("section$start$__DATA_CONST$__not_present");
            \\extern "C" const char* interop() {
            \\  return message_pointer;
            \\}
            ,
        });

        const exe = addExecutable(b, opts, .{ .name = "test" });
        exe.addObject(obj1);
        exe.addObject(obj3);
        exe.addObject(main_o);

        const run = b.addRunArtifact(exe);
        run.skip_foreign_checks = true;
        run.expectStdErrEqual("All your (null) are belong to us.\n");
        test_step.dependOn(&run.step);

        const check = exe.checkObject();
        check.checkInSymtab();
        check.checkNotPresent("external section$start$__DATA_CONST$__not_present");
        test_step.dependOn(&check.step);
    }

    return test_step;
}

fn addTestStep(b: *std.Build, comptime prefix: []const u8, opts: Options) *Step {
    return link.addTestStep(b, "macho-" ++ prefix, opts);
}

const addCSourceBytes = link.addCSourceBytes;
const addRunArtifact = link.addRunArtifact;
const addObject = link.addObject;
const addExecutable = link.addExecutable;
const addSharedLibrary = link.addSharedLibrary;
const expectLinkErrors = link.expectLinkErrors;
const link = @import("link.zig");
const std = @import("std");
const Options = link.Options;
const Step = std.Build.Step;

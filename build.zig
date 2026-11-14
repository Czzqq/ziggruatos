const std = @import("std");

const FsBackend = enum { tmpfs, zfs };
const MmuMode = enum { on, off };

const os_target = "zigguratOS";
const initramfs_target = "initramfs.cpio";
const kernel_statc_size: usize = 64 * 1024;
const page_size: usize = 4096;

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: []const u8,
    fs_backend: FsBackend,
    zfs_disk_mb: usize,
    copy_to_zfs_effective: bool,
    mmu_enabled: bool,
};

// build.zig need to read asm variable from 'board'
const BoardConfig = struct {
    max_cpus: usize,
    linear_image: bool,
    embedded_initramfs: bool,
    native_machine: bool = false,
};

const Modules = struct {
    common: *std.Build.Module,
    board: *std.Build.Module,
    arch: *std.Build.Module,
    device: *std.Build.Module,
    drivers: *std.Build.Module,
    block: *std.Build.Module,
    fs: *std.Build.Module,
    platform: *std.Build.Module,
    build_options: *std.Build.Step.Options,
};

const KernelArtifacts = struct {
    exe: *std.Build.Step.Compile,
    install_elf: *std.Build.Step.InstallArtifact,
    install_bin: *std.Build.Step.InstallFile,
};

const UserArtifacts = struct {
    step: *std.Build.Step, // "user"
    build: *std.Build.Step.Run, // run step in make
};

const InitramfsArtifacts = struct {
    step: *std.Build.Step,
    image: std.Build.LazyPath,
};

fn resolveOptions(b: *std.Build) Options {
    const platform = b.option([]const u8, "platform", "Target board/platform") orelse "virt";
    const small_core = std.mem.eql(u8, platform, "duos-smallcore");
    const mmu: MmuMode = b.option(MmuMode, "mmu", "Memory backend: on (Sv39) or off (native M-mode)") orelse if (small_core) .off else .on;
    if (small_core and mmu == .on) std.debug.panic("C906L has no MMU; use -Dmmu=off", .{});
    if (!small_core and mmu == .off) std.debug.panic("MMU-off execution is currently supported only on duos-smallcore", .{});
    const fs_backend: FsBackend = b.option(FsBackend, "fs", "Root filesystem backend (tmpfs, zfs)") orelse if (small_core) .tmpfs else .zfs;
    if (small_core and fs_backend != .tmpfs) {
        std.debug.panic("duos-smallcore requires -Dfs=tmpfs; Linux owns storage", .{});
    }
    const copy_to_zfs = b.option(bool, "copy-to-zfs", "Copy user binaries into the ZFS root image") orelse true;

    return .{
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_features_add = if (small_core) std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }) else .empty,
            .cpu_features_sub = if (small_core) std.Target.riscv.featureSet(&.{ .f, .d, .v }) else .empty,
        }),
        .optimize = b.standardOptimizeOption(.{}),
        .platform = platform,
        .fs_backend = fs_backend,
        .zfs_disk_mb = b.option(usize, "zfs-disk-mb", "ZFS disk image size in MB") orelse 10,
        .copy_to_zfs_effective = fs_backend == .zfs and copy_to_zfs,
        .mmu_enabled = mmu == .on,
    };
}

fn loadBoardConfig(platform: []const u8) BoardConfig {
    if (std.mem.eql(u8, "duos-smallcore", platform)) {
        const cfg = @import("src/kernel/board/duos-smallcore/config.zig");
        return .{
            .max_cpus = cfg.max_cpus,
            .linear_image = cfg.linear_image,
            .embedded_initramfs = cfg.initramfs.embedded,
            .native_machine = true,
        };
    }
    if (std.mem.eql(u8, "virt", platform)) {
        const cfg = @import("src/kernel/board/virt/config.zig");
        return .{
            .max_cpus = cfg.max_cpus,
            .linear_image = cfg.linear_image,
            .embedded_initramfs = cfg.initramfs.embedded,
        };
    }
    if (std.mem.eql(u8, "duos", platform)) {
        const cfg = @import("src/kernel/board/duos/config.zig");
        return .{
            .max_cpus = cfg.max_cpus,
            .linear_image = cfg.linear_image,
            .embedded_initramfs = cfg.initramfs.embedded,
        };
    }
    std.debug.panic("unsupported platform: {s}", .{platform});
}

fn setupModules(
    b: *std.Build,
    options: Options,
    board_config: BoardConfig,
    initramfs_image: std.Build.LazyPath,
) Modules {
    const board = b.addModule("board", .{
        .root_source_file = b.path(b.fmt("src/kernel/board/{s}/platform.zig", .{options.platform})),
        .target = options.target,
        .optimize = options.optimize,
    });

    const common = b.addModule("common", .{
        .root_source_file = b.path(b.fmt("src/kernel/common/common.zig", .{})),
        .target = options.target,
        .optimize = options.optimize,
    });
    common.addImport("board", board);

    const arch = b.addModule("arch", .{
        .root_source_file = b.path(b.fmt("src/kernel/arch/arch.zig", .{})),
        .target = options.target,
        .optimize = options.optimize,
    });
    arch.addImport("common", common);
    arch.addImport("board", board);
    const memory_policy = b.addOptions();
    memory_policy.addOption(bool, "enabled", options.mmu_enabled);
    arch.addOptions("memory_policy", memory_policy);

    const device = b.addModule("device", .{
        .root_source_file = b.path(b.fmt("src/kernel/device/device.zig", .{})),
        .target = options.target,
        .optimize = options.optimize,
    });

    const drivers = b.addModule("drivers", .{
        .root_source_file = b.path("src/kernel/drivers/drivers.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    drivers.addImport("board", board);
    drivers.addImport("arch", arch);
    drivers.addImport("common", common);
    drivers.addImport("device", device);
    // NOTE: drivers must NERVER addImport("kernel", ...) - that is a cycle.
    // Kernel services a drivers needs are handed in at init time instead.

    const block = b.addModule("block", .{
        .root_source_file = b.path("src/kernel/block/block.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    block.addImport("arch", arch);
    block.addImport("drivers", drivers);
    block.addImport("device", device);

    const fs = b.addModule("fs", .{
        .root_source_file = b.path("src/kernel/fs/fs.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    fs.addImport("common", common);
    fs.addImport("board", board);
    fs.addImport("device", device);
    fs.addImport("block", block);
    if (board_config.embedded_initramfs) {
        const generated = b.addWriteFiles();
        _ = generated.addCopyFile(initramfs_image, initramfs_target);
        const blob_source = generated.add("initramfs_blob.zig", b.fmt(
            \\pub const bytes align(4096) = @embedFile("{s}");
            \\
        ,
            .{initramfs_target},
        ));
        fs.addAnonymousImport("initramfs_blob", .{
            .root_source_file = blob_source,
            .target = options.target,
            .optimize = options.optimize,
        });
    }

    const platform = b.addModule("platform", .{
        .root_source_file = b.path(b.fmt("src/kernel/board/{s}/init.zig", .{options.platform})),
        .target = options.target,
        .optimize = options.optimize,
    });
    platform.addImport("common", common);
    platform.addImport("board", board);
    platform.addImport("arch", arch);
    platform.addImport("drivers", drivers);
    platform.addImport("device", device);
    platform.addImport("block", block);

    const build_options = b.addOptions();
    build_options.addOption(bool, "fs_tmpfs", options.fs_backend == .tmpfs);
    build_options.addOption(bool, "fs_zfs_root", options.fs_backend == .zfs);
    build_options.addOption(bool, "copy_to_zfs", options.copy_to_zfs_effective);
    build_options.addOption(usize, "zfs_disk_size_mb", options.zfs_disk_mb);
    fs.addOptions("build_options", build_options);

    return .{
        .common = common,
        .board = board,
        .arch = arch,
        .drivers = drivers,
        .device = device,
        .block = block,
        .fs = fs,
        .platform = platform,
        .build_options = build_options,
    };
}

fn generateAsmConstants(b: *std.Build, board_config: BoardConfig) std.Build.LazyPath {
    const max_va: usize = @as(usize, 1) << (9 + 9 + 9 + 12 - 1);
    const trampoline = max_va - 1 * page_size;
    const trapframe = max_va - 2 * page_size;

    const files = b.addWriteFiles();
    _ = files.add("constants.h", b.fmt(
        \\#define MAX_CPUS {d}
        \\#define KERNEL_STACK_SIZE {d}
        \\#define KERNEL_LINEAR_IMAGE {d}
        \\#define TRAMPOLINE 0x{x}
        \\#define TRAPFRAME 0x{x}
        \\
    , .{ board_config.max_cpus, kernel_statc_size, @intFromBool(board_config.linear_image), trampoline, trapframe }));
    return files.getDirectory();
}

fn buildKernel(
    b: *std.Build,
    options: Options,
    modules: Modules,
    board_config: BoardConfig,
) KernelArtifacts {
    const asm_constants_dir = generateAsmConstants(b, board_config);
    const artifact_name = if (board_config.native_machine) "zigguratOS-duos-smallcore" else os_target;

    const exe = b.addExecutable(.{
        .name = artifact_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(if (board_config.native_machine) "src/kernel/main_nommu.zig" else "src/kernel/main.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .code_model = .large,
            .strip = if (board_config.native_machine) false else null,
        }),
    });

    exe.setLinkerScript(b.path(if (board_config.native_machine)
        "src/kernel/board/duos-smallcore/linker.ld"
    else if (board_config.linear_image)
        "src/kernel/board/duos/linker.ld"
    else
        "src/kernel/linker.ld"));

    exe.root_module.addIncludePath(asm_constants_dir);
    exe.root_module.addIncludePath(b.path("src/kernel/arch/asm"));
    exe.root_module.addImport("common", modules.common);
    exe.root_module.addImport("board", modules.board);
    exe.root_module.addImport("arch", modules.arch);
    exe.root_module.addImport("drivers", modules.drivers);
    exe.root_module.addImport("device", modules.device);
    exe.root_module.addImport("block", modules.block);
    exe.root_module.addImport("fs", modules.fs);
    exe.root_module.addImport("platform", modules.platform);

    // add asm files
    const asm_sources: []const []const u8 = if (board_config.native_machine) &.{
        "src/kernel/board/duos-smallcore/start.S",
    } else &.{
        "src/kernel/arch/asm/boot.S",
        "src/kernel/arch/asm/entry.S",
        "src/kernel/arch/asm/trampoline.S",
        "src/kernel/arch/asm/swtch.S",
    };
    for (asm_sources) |source| {
        exe.root_module.addAssemblyFile(b.path(source));
    }

    const install_elf = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_elf.step);

    const objcopy = b.addObjCopy(exe.getEmittedBin(), .{
        .format = .binary,
        .basename = b.fmt("{s}.bin", .{artifact_name}),
    });
    const install_bin = b.addInstallBinFile(objcopy.getOutput(), b.fmt("{s}.bin", .{artifact_name}));
    if (board_config.native_machine) {
        const metadata = b.addSystemCommand(&.{ "python3", "tools/smallcore_manifest.py", "--elf" });
        metadata.addFileArg(exe.getEmittedBin());
        metadata.addArg("--binary");
        metadata.addFileArg(objcopy.getOutput());
        metadata.addArg("--output");
        const manifest = metadata.addOutputFileArg(b.fmt("{s}.bin.json", .{artifact_name}));
        const install_manifest = b.addInstallBinFile(manifest, b.fmt("{s}.bin.json", .{artifact_name}));
        install_bin.step.dependOn(&install_manifest.step);
    }

    return .{ .exe = exe, .install_elf = install_elf, .install_bin = install_bin };
}

fn setupKernelStep(b: *std.Build, kernel: KernelArtifacts) *std.Build.Step {
    const step = b.step("kernel", "Build the operation system kernel");
    step.dependOn(&kernel.exe.step);
    step.dependOn(&kernel.install_elf.step);
    step.dependOn(&kernel.install_bin.step);
    return step;
}

fn steupUserStep(b: *std.Build) UserArtifacts {
    const step = b.step("user", "Build user applications");

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/user" });
    const make = b.addSystemCommand(&.{ "sh", "-c", "echo \"Building user application\" &&" ++
        "make --no-print-directory -C src/user &&" ++
        "cp -rf src/user/user-out/* zig-out/user/ 2>/dev/null || true" });
    make.step.dependOn(&mkdir.step);
    step.dependOn(&make.step);

    return .{ .step = step, .build = make };
}

fn setupInitramfsStep(b: *std.Build, user: UserArtifacts) InitramfsArtifacts {
    // build initramfs step
    const step = b.step("initramfs", "Build the initramfs");

    // create output directory
    const copy = b.addSystemCommand(&.{
        "sh", "-c", "cp -rf zig-out/user/* initramfs_root/ 2>/dev/null || true",
    });
    // Create the CPIO archive in Zig's cache and install a copy under zig-out.
    const create_cpio = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p initramfs_root && cd initramfs_root && " ++
        "find . -print0 | cpio --null -o -H newc --quiet > \"$1\"", "initramfs" });
    const image = create_cpio.addOutputFileArg2(initramfs_target, .{ .make_absolute = true });
    copy.step.dependOn(&user.build.step);
    create_cpio.step.dependOn(&copy.step);
    const install_image = b.addInstallFileWithDir(image, .{ .custom = "initramfs" }, initramfs_target);
    step.dependOn(&install_image.step);

    return .{ .step = step, .image = image };
}

fn setupConfigStep(b: *std.Build, options: Options) void {
    const step = b.step("config", "Display the active build configuration");
    step.dependOn(&b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        "echo ' Platfom:        {s}' && " ++
            "echo ' Filesystem:     {s}' && " ++
            "echo ' ZFS disk size:  {d} MB' && " ++
            "echo ' Copy to ZFS:    {any}'",
        .{
            options.platform,
            @tagName(options.fs_backend),
            options.zfs_disk_mb,
            options.copy_to_zfs_effective,
        },
    ) }).step);
}

fn setupCleanStep(b: *std.Build) void {
    const step = b.step("clean", "Clean build argifacts");
    const clean_user = b.addSystemCommand(&.{ "make", "--no-print-directory", "-C", "src/user", "clean" });
    const rm_build = b.addSystemCommand(&.{ "rm", "-rf", "out" });

    step.dependOn(&rm_build.step);
    step.dependOn(&clean_user.step);
}

fn setupDiskSteps(b: *std.Build, options: Options, user: UserArtifacts) void {
    const mkfs_step = b.step("mkfs", "Build mkfs.zfs tool");
    const build_mkfs = b.addSystemCommand(&.{ "make", "-C", "tools/mkfs.zfs" });
    mkfs_step.dependOn(&build_mkfs.step);

    const disk_step = b.step("disk", "Create ZFS disk image");
    const create_disk = b.addSystemCommand(&.{
        "sh",
        "-c",
        b.fmt("echo ' Creating ZFS disk image ({d} MB)...' && " ++
            "./tools/mkfs.zfs/mkfs.zfs disk.img {d}", .{ options.zfs_disk_mb, options.zfs_disk_mb }),
    });
    create_disk.step.dependOn(&build_mkfs.step);
    disk_step.dependOn(&create_disk.step);

    // Optionally populate the freshly created image with user binaries.
    if (options.copy_to_zfs_effective) {
        const populate_disk = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo ' Copying user binaries to ZFS root...' && " ++
                "python3 ./tools/populate_zfs.py disk.img zig-out/user",
        });
        populate_disk.step.dependOn(&create_disk.step);
        populate_disk.step.dependOn(user.step);
        disk_step.dependOn(&populate_disk.step);
    }
}

fn setupDisasmStep(b: *std.Build, kernel_step: *std.Build.Step) void {
    // cat disasm
    const step = b.step("disasm", "Show disassembly of the kernel");
    const objdump = b.addSystemCommand(&.{
        "riscv64-linux-gnu-objdump",
        "-d",
        "./zig-out/bin/" ++ os_target,
    });
    objdump.step.dependOn(kernel_step);
    step.dependOn(&objdump.step);
}

pub fn build(b: *std.Build) void {
    const options = resolveOptions(b);
    const board_config = loadBoardConfig(options.platform);
    if (board_config.native_machine) {
        const generated = b.addWriteFiles();
        const unused_image = generated.add("unused-initramfs", "");
        const modules = setupModules(b, options, board_config, unused_image);
        const kernel = buildKernel(b, options, modules, board_config);
        const kernel_step = setupKernelStep(b, kernel);
        b.default_step.dependOn(kernel_step);
        setupConfigStep(b, options);
        return;
    }

    const user = steupUserStep(b);
    const initramfs = setupInitramfsStep(b, user);
    const modules = setupModules(b, options, board_config, initramfs.image);

    const kernel = buildKernel(b, options, modules, board_config);
    const kernel_step = setupKernelStep(b, kernel);

    if (board_config.embedded_initramfs) {
        kernel.exe.step.dependOn(initramfs.step);
        kernel.install_bin.step.dependOn(initramfs.step);
    }

    setupConfigStep(b, options);
    setupCleanStep(b);
    setupDiskSteps(b, options, user);
    setupDisasmStep(b, kernel_step);

    b.default_step.dependOn(kernel_step);
    b.default_step.dependOn(initramfs.step);

    // NOTE: QEMU/GDB are intentionally NOT launched from build.zig.
    // `zig build` runs steps as managed child processes and Ctrl-C would tear
    // down e.g. GDB. Interactive tools are launched by the Makefile with
    // `exec`, so terminal signals reach QEMU/GDB directly (see Makefile).
}

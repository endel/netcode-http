const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const quic = b.dependency("quic", .{ .target = target, .optimize = optimize }).module("quic");
    // Re-exported: an app takes quic-zig from here, so there's one, at our pin.
    b.modules.put(b.graph.arena, "quic", quic) catch @panic("OOM");

    // Endpoints' contracts, std only: shared code holds them whatever its
    // target, so the module takes its importer's.
    const endpoint = b.addModule("endpoint", .{ .root_source_file = b.path("src/endpoint.zig") });
    const http = b.addModule("http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quic", .module = quic },
            .{ .name = "endpoint", .module = endpoint },
        },
    });

    const bench = b.addExecutable(.{ .name = "bench-server", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "http", .module = http }, .{ .name = "quic", .module = quic } },
    }) });
    b.step("bench", "Build the benchmark server").dependOn(&b.addInstallArtifact(bench, .{}).step);

    const notes = b.addExecutable(.{ .name = "notes", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/notes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = http }},
    }) });
    b.step("notes", "Build the notes example").dependOn(&b.addInstallArtifact(notes, .{}).step);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&notes.step); // the example keeps compiling
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = http })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/endpoint.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
}

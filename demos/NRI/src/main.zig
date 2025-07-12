// -- Imports -- //

const std = @import("std");

const tracy = @import("tracy.zig");

const c = @cImport({
    @cDefine("MIDL_INTERFACE", "struct");

    // GLFW
    @cDefine("GLFW_DLL", {});
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("GLFW/glfw3native.h");

    // NRI
    @cInclude("NRI/NRI.h");
    @cInclude("NRI/Extensions/NRIDeviceCreation.h");
    @cInclude("NRI/Extensions/NRIHelper.h");
    @cInclude("NRI/Extensions/NRIStreamer.h");
    @cInclude("NRI/Extensions/NRISwapChain.h");
});

// -- Global Constants -- //

pub const DEBUG = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub const std_options: std.Options = .{ .log_level = if (DEBUG) .debug else .info };

// -- Constants -- //

const GRAPHICS_API = c.NriGraphicsAPI_VK;
const VALIDATE_API = true;
const VALIDATE_NRI = true;
const VK_BINDING_OFFSETS = c.NriVKBindingOffsets{
    .samplerOffset = 0,
    .textureOffset = 128,
    .constantBufferOffset = 32,
    .storageTextureAndBufferOffset = 64,
};
const VSYNC = false;
const QUEUED_FRAME_NUM = if (VSYNC) 2 else 3;

const WINDOW_WIDTH = 1024;
const WINDOW_HEIGHT = 1024;

// -- State -- //

var window: *c.GLFWwindow = undefined;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();

    const allocator = if (DEBUG) debug_allocator.allocator() else std.heap.smp_allocator;

    // ---

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    if (c.glfwInit() == c.GLFW_FALSE) return error.GLFWInitFailure;
    defer c.glfwTerminate();

    // --- [ INIT ]

    std.log.info("Using NRI Version: {}", .{c.NRI_VERSION});

    var result: c.NriResult = undefined;

    var adapterDescs: [2]c.NriAdapterDesc = undefined;
    var adapterDescsNum: u32 = adapterDescs.len;
    result = c.nriEnumerateAdapters(&adapterDescs, &adapterDescsNum);
    try enri(result);

    std.log.info("{} Adapter(s) Found.", .{adapterDescsNum});
    for (adapterDescs[0..@intCast(adapterDescsNum)], 0..) |adapter, i| {
        std.log.info("Adapter {}: '{s}'", .{ i, adapter.name });
    }

    // ---

    const device_creation_desc = c.NriDeviceCreationDesc{
        .graphicsAPI = GRAPHICS_API,
        .enableGraphicsAPIValidation = VALIDATE_API,
        .enableNRIValidation = VALIDATE_NRI,
        .vkBindingOffsets = VK_BINDING_OFFSETS,
        .adapterDesc = &adapterDescs[0],
    };
    var device_opt: ?*c.NriDevice = null;
    result = c.nriCreateDevice(&device_creation_desc, &device_opt);
    try enri(result);

    const device = device_opt orelse {
        std.log.err("`device` was null!", .{});
        return error.NRIDeviceError;
    };

    // ---

    var core_interface: NriCoreInterface = undefined;
    result = c.nriGetInterface(device, "NriCoreInterface", @sizeOf(NriCoreInterface), &core_interface);
    try enri(result);

    var helper_interface: c.NriHelperInterface = undefined;
    result = c.nriGetInterface(device, "NriHelperInterface", @sizeOf(c.NriHelperInterface), &helper_interface);
    try enri(result);

    var swapchain_interface: c.NriSwapChainInterface = undefined;
    result = c.nriGetInterface(device, "NriSwapChainInterface", @sizeOf(c.NriSwapChainInterface), &swapchain_interface);
    try enri(result);

    // ---

    var graphics_queue_opt: ?*c.NriQueue = null;
    result = core_interface.GetQueue.?(device, c.NriQueueType_GRAPHICS, 0, &graphics_queue_opt);
    try enri(result);

    const queue = graphics_queue_opt orelse {
        std.log.err("`queue` was null!", .{});
        return error.NRICoreError;
    };

    // ---

    var fence_opt: ?*c.NriFence = null;
    result = core_interface.CreateFence.?(device, 0, &fence_opt);
    try enri(result);

    const frame_fence = fence_opt orelse {
        std.log.err("`fence` was null!", .{});
        return error.NRICoreError;
    };

    // ---

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    window = c.glfwCreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "NRI Demo", null, null) orelse return error.GLFWCreateWindowFailure;
    defer c.glfwDestroyWindow(window);

    // ---

    const swapchain_desc = c.NriSwapChainDesc{
        .window = .{ .windows = .{ .hwnd = c.glfwGetWin32Window(window) } },
        .queue = queue,
        .format = c.NriSwapChainFormat_BT709_G22_8BIT,
        .flags = (if (VSYNC) c.NriSwapChainBits_VSYNC else c.NriSwapChainBits_NONE) | c.NriSwapChainBits_ALLOW_TEARING,
        .width = WINDOW_WIDTH,
        .height = WINDOW_HEIGHT,
        .textureNum = QUEUED_FRAME_NUM + 1,
        .queuedFrameNum = QUEUED_FRAME_NUM,
    };

    var swapchain_opt: ?*c.NriSwapChain = null;
    result = swapchain_interface.CreateSwapChain.?(device, &swapchain_desc, &swapchain_opt);
    try enri(result);

    const swapchain = swapchain_opt orelse {
        std.log.err("`swapchain` was null!", .{});
        return error.NRISwapchainError;
    };

    // ---

    var swapchain_texture_num: u32 = 0;
    const c_swapchain_textures = swapchain_interface.GetSwapChainTextures.?(swapchain, &swapchain_texture_num);
    const swapchain_textures = c_swapchain_textures[0..swapchain_texture_num];

    const swapchain_format: c.NriFormat = core_interface.GetTextureDesc.?(swapchain_textures[0]).*.format;

    var swapchain_texture_textures = try allocator.alloc(SwapChainTexture, swapchain_texture_num);
    defer allocator.free(swapchain_texture_textures);

    for (0..swapchain_texture_num) |i| {
        const texture_view_desc = c.NriTexture2DViewDesc{
            .texture = swapchain_textures[i],
            .viewType = c.NriTexture2DViewType_COLOR_ATTACHMENT,
            .format = swapchain_format,
        };

        var color_attachment_opt: ?*c.NriDescriptor = null;
        result = core_interface.CreateTexture2DView.?(&texture_view_desc, &color_attachment_opt);
        try enri(result);

        var acquire_semaphore_opt: ?*c.NriFence = null;
        result = core_interface.CreateFence.?(device, c.NRI_SWAPCHAIN_SEMAPHORE, &acquire_semaphore_opt);
        try enri(result);

        var release_semaphore_opt: ?*c.NriFence = null;
        result = core_interface.CreateFence.?(device, c.NRI_SWAPCHAIN_SEMAPHORE, &release_semaphore_opt);
        try enri(result);

        swapchain_texture_textures[i] = .{
            .acquire_semaphore = acquire_semaphore_opt orelse {
                std.log.err("`acquire_semaphore` was null!", .{});
                return error.NRICoreError;
            },
            .release_semaphore = release_semaphore_opt orelse {
                std.log.err("`release_semaphore` was null!", .{});
                return error.NRICoreError;
            },
            .texture = swapchain_textures[i].?,
            .color_attachment = color_attachment_opt orelse {
                std.log.err("`color_attachment` was null!", .{});
                return error.NRICoreError;
            },
            .attachment_format = swapchain_format,
        };
    }

    // ---

    var queued_frames: [QUEUED_FRAME_NUM]QueuedFrame = undefined;
    for (&queued_frames) |*qf| {
        result = core_interface.CreateCommandAllocator.?(queue, @ptrCast(&qf.command_allocator));
        try enri(result);

        result = core_interface.CreateCommandBuffer.?(qf.command_allocator, @ptrCast(&qf.command_buffer));
        try enri(result);
    }

    // --- [ INIT ] => [ RENDER ] [ UPDATE ]

    var frame_index: usize = 0;
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) : (frame_index += 1) {
        c.glfwPollEvents();

        const queued_frame_index = frame_index % QUEUED_FRAME_NUM;
        const queued_frame = &queued_frames[queued_frame_index];

        core_interface.Wait.?(frame_fence, if (frame_index >= QUEUED_FRAME_NUM) 1 + frame_index - QUEUED_FRAME_NUM else 0);
        core_interface.ResetCommandAllocator.?(queued_frame.command_allocator);

        tracy.frameMark();

        const recycled_semaphore_index = frame_index % swapchain_texture_textures.len;
        const swapchain_acquire_semaphore = swapchain_texture_textures[recycled_semaphore_index].acquire_semaphore;

        {
            var current_swapchain_texture_index: u32 = 0;
            result = swapchain_interface.AcquireNextTexture.?(swapchain, swapchain_acquire_semaphore, &current_swapchain_texture_index);
            try enri(result);

            const swapchain_texture = &swapchain_texture_textures[current_swapchain_texture_index];

            const command_buffer = queued_frame.command_buffer;
            result = core_interface.BeginCommandBuffer.?(command_buffer, null);
            try enri(result);
            {
                var texture_barriers = c.NriTextureBarrierDesc{
                    .texture = swapchain_texture.texture,
                    .after = .{ .access = c.NriAccessBits_COLOR_ATTACHMENT, .layout = c.NriLayout_COLOR_ATTACHMENT },
                    .layerNum = 1,
                    .mipNum = 1,
                };

                const barrier_group_desc = c.NriBarrierGroupDesc{
                    .textureNum = 1,
                    .textures = &texture_barriers,
                };
                core_interface.CmdBarrier.?(command_buffer, &barrier_group_desc);

                const attachments_desc = c.NriAttachmentsDesc{
                    .colorNum = 1,
                    .colors = &swapchain_texture.color_attachment,
                };

                core_interface.CmdBeginRendering.?(command_buffer, &attachments_desc);
                {
                    var clear_desc = c.NriClearDesc{
                        .colorAttachmentIndex = 0,
                        .planes = c.NriPlaneBits_COLOR,
                    };

                    const w: c.NriDim_t = @intCast(WINDOW_WIDTH);
                    const h: c.NriDim_t = @intCast(WINDOW_HEIGHT);
                    const h3 = h / 3;
                    const y: i16 = @intCast(h3);

                    clear_desc.value.color.f = .{ .x = 1, .w = 1 };
                    const rect1: c.NriRect = .{ .height = h3, .width = w, .x = 0, .y = 0 };
                    core_interface.CmdClearAttachments.?(command_buffer, &clear_desc, 1, &rect1, 1);

                    clear_desc.value.color.f = .{ .y = 1, .w = 1 };
                    const rect2: c.NriRect = .{ .height = h3, .width = w, .x = 0, .y = y };
                    core_interface.CmdClearAttachments.?(command_buffer, &clear_desc, 1, &rect2, 1);

                    clear_desc.value.color.f = .{ .z = 1, .w = 1 };
                    const rect3: c.NriRect = .{ .height = h3, .width = w, .x = 0, .y = 2 * y };
                    core_interface.CmdClearAttachments.?(command_buffer, &clear_desc, 1, &rect3, 1);
                }
                core_interface.CmdEndRendering.?(command_buffer);

                texture_barriers.before = texture_barriers.after;
                texture_barriers.after = .{ .access = c.NriAccessBits_NONE, .layout = c.NriLayout_PRESENT };

                core_interface.CmdBarrier.?(command_buffer, &barrier_group_desc);
            }
            result = core_interface.EndCommandBuffer.?(command_buffer);
            try enri(result);

            // ---

            const texture_acquired_fence = c.NriFenceSubmitDesc{
                .fence = swapchain_acquire_semaphore,
                .stages = c.NriStageBits_COLOR_ATTACHMENT,
            };

            const rendering_finished_fence = c.NriFenceSubmitDesc{
                .fence = swapchain_texture.release_semaphore,
            };

            const queue_submit_desc = c.NriQueueSubmitDesc{
                .waitFences = &texture_acquired_fence,
                .waitFenceNum = 1,
                .commandBuffers = &command_buffer,
                .commandBufferNum = 1,
                .signalFences = &rendering_finished_fence,
                .signalFenceNum = 1,
            };

            result = core_interface.QueueSubmit.?(queue, &queue_submit_desc);
            try enri(result);

            // ---

            result = swapchain_interface.QueuePresent.?(swapchain, swapchain_texture.release_semaphore);
            try enri(result);
        }

        // ---

        {
            const signal_fence = c.NriFenceSubmitDesc{
                .fence = frame_fence,
                .value = 1 + frame_index,
            };

            const queue_submit_desc = c.NriQueueSubmitDesc{
                .signalFences = &signal_fence,
                .signalFenceNum = 1,
            };

            result = core_interface.QueueSubmit.?(queue, &queue_submit_desc);
            try enri(result);
        }
    }

    // --- [ RENDER ] [ UPDATE ] => [ CLEANUP ]

    {
        result = core_interface.DeviceWaitIdle.?(device);
        try enri(result);

        for (queued_frames) |qf| {
            core_interface.DestroyCommandBuffer.?(qf.command_buffer);
            core_interface.DestroyCommandAllocator.?(qf.command_allocator);
        }

        for (swapchain_texture_textures) |swapchain_texture| {
            core_interface.DestroyFence.?(swapchain_texture.acquire_semaphore);
            core_interface.DestroyFence.?(swapchain_texture.release_semaphore);
            core_interface.DestroyDescriptor.?(swapchain_texture.color_attachment);
        }

        core_interface.DestroyFence.?(frame_fence);

        swapchain_interface.DestroySwapChain.?(swapchain);

        c.nriDestroyDevice(device);
    }
}

// -- Helper Functions -- //

export fn glfwErrorCallback(err: c_int, description: [*c]const u8) void {
    std.log.err("GLFW Error: {s}", .{description});
    std.process.exit(@intCast(err));
}

fn enri(result: c.NriResult) !void {
    if (result != c.NriResult_SUCCESS) {
        std.log.err("nriEnumerateAdapters(): {}", .{result});
        return error.NriError;
    }
}

// -- Ingenuity -- //

pub const SwapChainTexture = struct {
    acquire_semaphore: *c.NriFence,
    release_semaphore: *c.NriFence,
    texture: *c.NriTexture,
    color_attachment: *c.NriDescriptor,
    attachment_format: c.NriFormat,
};

pub const QueuedFrame = struct { command_allocator: *c.NriCommandAllocator, command_buffer: *c.NriCommandBuffer };

// --- God Help Me --- //

pub const NriDeviceDesc = extern struct {
    adapterDesc: c.NriAdapterDesc = @import("std").mem.zeroes(c.NriAdapterDesc),
    graphicsAPI: c.NriGraphicsAPI = @import("std").mem.zeroes(c.NriGraphicsAPI),
    nriVersion: u16 = @import("std").mem.zeroes(u16),
    shaderModel: u8 = @import("std").mem.zeroes(u8),
    viewport: Viewport = @import("std").mem.zeroes(Viewport),
    dimensions: Dimensions = @import("std").mem.zeroes(Dimensions),
    precision: Precision = @import("std").mem.zeroes(Precision),
    memory: Memory = @import("std").mem.zeroes(Memory),
    memoryAlignment: MemoryAlignment = @import("std").mem.zeroes(MemoryAlignment),
    pipelineLayout: PipelineLayout = @import("std").mem.zeroes(PipelineLayout),
    descriptorSet: DescriptorSet = @import("std").mem.zeroes(DescriptorSet),
    shaderStage: ShaderStage = @import("std").mem.zeroes(ShaderStage),
    other: Other = @import("std").mem.zeroes(Other),
    tiers: Tiers = @import("std").mem.zeroes(Tiers),
    features: u16 = @import("std").mem.zeroes(u16), // c.struct_unnamed_22
    shaderFeatures: u32 = @import("std").mem.zeroes(u32), // c.struct_unnamed_23

    const Viewport = extern struct {
        maxNum: u32 = @import("std").mem.zeroes(u32),
        boundsMin: i16 = @import("std").mem.zeroes(i16),
        boundsMax: i16 = @import("std").mem.zeroes(i16),
    };
    const Dimensions = extern struct {
        typedBufferMaxDim: u32 = @import("std").mem.zeroes(u32),
        attachmentMaxDim: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
        attachmentLayerMaxNum: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
        texture1DMaxDim: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
        texture2DMaxDim: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
        texture3DMaxDim: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
        textureLayerMaxNum: c.NriDim_t = @import("std").mem.zeroes(c.NriDim_t),
    };
    const Precision = extern struct {
        viewportBits: u32 = @import("std").mem.zeroes(u32),
        subPixelBits: u32 = @import("std").mem.zeroes(u32),
        subTexelBits: u32 = @import("std").mem.zeroes(u32),
        mipmapBits: u32 = @import("std").mem.zeroes(u32),
    };
    const Memory = extern struct {
        deviceUploadHeapSize: u64 = @import("std").mem.zeroes(u64),
        allocationMaxNum: u32 = @import("std").mem.zeroes(u32),
        samplerAllocationMaxNum: u32 = @import("std").mem.zeroes(u32),
        constantBufferMaxRange: u32 = @import("std").mem.zeroes(u32),
        storageBufferMaxRange: u32 = @import("std").mem.zeroes(u32),
        bufferTextureGranularity: u32 = @import("std").mem.zeroes(u32),
        bufferMaxSize: u64 = @import("std").mem.zeroes(u64),
    };
    const MemoryAlignment = extern struct {
        uploadBufferTextureRow: u32 = @import("std").mem.zeroes(u32),
        uploadBufferTextureSlice: u32 = @import("std").mem.zeroes(u32),
        shaderBindingTable: u32 = @import("std").mem.zeroes(u32),
        bufferShaderResourceOffset: u32 = @import("std").mem.zeroes(u32),
        constantBufferOffset: u32 = @import("std").mem.zeroes(u32),
        scratchBufferOffset: u32 = @import("std").mem.zeroes(u32),
        accelerationStructureOffset: u32 = @import("std").mem.zeroes(u32),
        micromapOffset: u32 = @import("std").mem.zeroes(u32),
    };
    const PipelineLayout = extern struct {
        descriptorSetMaxNum: u32 = @import("std").mem.zeroes(u32),
        rootConstantMaxSize: u32 = @import("std").mem.zeroes(u32),
        rootDescriptorMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const UpdateAfterSet1 = extern struct {
        samplerMaxNum: u32 = @import("std").mem.zeroes(u32),
        constantBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        storageBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        textureMaxNum: u32 = @import("std").mem.zeroes(u32),
        storageTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const DescriptorSet = extern struct {
        samplerMaxNum: u32 = @import("std").mem.zeroes(u32),
        constantBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        storageBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        textureMaxNum: u32 = @import("std").mem.zeroes(u32),
        storageTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
        updateAfterSet: UpdateAfterSet1 = @import("std").mem.zeroes(UpdateAfterSet1),
    };
    const UpdateAfterSet2 = extern struct {
        descriptorSamplerMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorConstantBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorStorageBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorStorageTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
        resourceMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const Vertex = extern struct {
        attributeMaxNum: u32 = @import("std").mem.zeroes(u32),
        streamMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const TesselationControl = extern struct {
        generationMaxLevel: f32 = @import("std").mem.zeroes(f32),
        patchPointMaxNum: u32 = @import("std").mem.zeroes(u32),
        perVertexInputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        perVertexOutputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        perPatchOutputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        totalOutputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const TesselationEvaluation = extern struct {
        inputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const Geometry = extern struct {
        invocationMaxNum: u32 = @import("std").mem.zeroes(u32),
        inputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputVertexMaxNum: u32 = @import("std").mem.zeroes(u32),
        totalOutputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const Fragment = extern struct {
        inputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        attachmentMaxNum: u32 = @import("std").mem.zeroes(u32),
        dualSourceAttachmentMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const Compute = extern struct {
        sharedMemoryMaxSize: u32 = @import("std").mem.zeroes(u32),
        workGroupMaxNum: [3]u32 = @import("std").mem.zeroes([3]u32),
        workGroupInvocationMaxNum: u32 = @import("std").mem.zeroes(u32),
        workGroupMaxDim: [3]u32 = @import("std").mem.zeroes([3]u32),
    };
    const RayTracing = extern struct {
        shaderGroupIdentifierSize: u32 = @import("std").mem.zeroes(u32),
        tableMaxStride: u32 = @import("std").mem.zeroes(u32),
        recursionMaxDepth: u32 = @import("std").mem.zeroes(u32),
    };
    const MeshControl = extern struct {
        sharedMemoryMaxSize: u32 = @import("std").mem.zeroes(u32),
        workGroupInvocationMaxNum: u32 = @import("std").mem.zeroes(u32),
        payloadMaxSize: u32 = @import("std").mem.zeroes(u32),
    };
    const MeshEvaluation = extern struct {
        outputVerticesMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputPrimitiveMaxNum: u32 = @import("std").mem.zeroes(u32),
        outputComponentMaxNum: u32 = @import("std").mem.zeroes(u32),
        sharedMemoryMaxSize: u32 = @import("std").mem.zeroes(u32),
        workGroupInvocationMaxNum: u32 = @import("std").mem.zeroes(u32),
    };
    const ShaderStage = extern struct {
        descriptorSamplerMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorConstantBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorStorageBufferMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
        descriptorStorageTextureMaxNum: u32 = @import("std").mem.zeroes(u32),
        resourceMaxNum: u32 = @import("std").mem.zeroes(u32),
        updateAfterSet: UpdateAfterSet2 = @import("std").mem.zeroes(UpdateAfterSet2),
        vertex: Vertex = @import("std").mem.zeroes(Vertex),
        tesselationControl: TesselationControl = @import("std").mem.zeroes(TesselationControl),
        tesselationEvaluation: TesselationEvaluation = @import("std").mem.zeroes(TesselationEvaluation),
        geometry: Geometry = @import("std").mem.zeroes(Geometry),
        fragment: Fragment = @import("std").mem.zeroes(Fragment),
        compute: Compute = @import("std").mem.zeroes(Compute),
        rayTracing: RayTracing = @import("std").mem.zeroes(RayTracing),
        meshControl: MeshControl = @import("std").mem.zeroes(MeshControl),
        meshEvaluation: MeshEvaluation = @import("std").mem.zeroes(MeshEvaluation),
    };
    const Other = extern struct {
        timestampFrequencyHz: u64 = @import("std").mem.zeroes(u64),
        micromapSubdivisionMaxLevel: u32 = @import("std").mem.zeroes(u32),
        drawIndirectMaxNum: u32 = @import("std").mem.zeroes(u32),
        samplerLodBiasMax: f32 = @import("std").mem.zeroes(f32),
        samplerAnisotropyMax: f32 = @import("std").mem.zeroes(f32),
        texelOffsetMin: i8 = @import("std").mem.zeroes(i8),
        texelOffsetMax: u8 = @import("std").mem.zeroes(u8),
        texelGatherOffsetMin: i8 = @import("std").mem.zeroes(i8),
        texelGatherOffsetMax: u8 = @import("std").mem.zeroes(u8),
        clipDistanceMaxNum: u8 = @import("std").mem.zeroes(u8),
        cullDistanceMaxNum: u8 = @import("std").mem.zeroes(u8),
        combinedClipAndCullDistanceMaxNum: u8 = @import("std").mem.zeroes(u8),
        viewMaxNum: u8 = @import("std").mem.zeroes(u8),
        shadingRateAttachmentTileSize: u8 = @import("std").mem.zeroes(u8),
    };
    const Tiers = extern struct {
        conservativeRaster: u8 = @import("std").mem.zeroes(u8),
        sampleLocations: u8 = @import("std").mem.zeroes(u8),
        rayTracing: u8 = @import("std").mem.zeroes(u8),
        shadingRate: u8 = @import("std").mem.zeroes(u8),
        bindless: u8 = @import("std").mem.zeroes(u8),
        resourceBinding: u8 = @import("std").mem.zeroes(u8),
        memory: u8 = @import("std").mem.zeroes(u8),
    };
};

pub const NriCoreInterface = extern struct {
    GetDeviceDesc: ?*const fn (?*const c.NriDevice) callconv(.c) ?*const NriDeviceDesc = @import("std").mem.zeroes(?*const fn (?*const c.NriDevice) callconv(.c) ?*const NriDeviceDesc),
    GetBufferDesc: ?*const fn (?*const c.NriBuffer) callconv(.c) [*c]const c.NriBufferDesc = @import("std").mem.zeroes(?*const fn (?*const c.NriBuffer) callconv(.c) [*c]const c.NriBufferDesc),
    GetTextureDesc: ?*const fn (?*const c.NriTexture) callconv(.c) [*c]const c.NriTextureDesc = @import("std").mem.zeroes(?*const fn (?*const c.NriTexture) callconv(.c) [*c]const c.NriTextureDesc),
    GetFormatSupport: ?*const fn (?*const c.NriDevice, c.NriFormat) callconv(.c) c.NriFormatSupportBits = @import("std").mem.zeroes(?*const fn (?*const c.NriDevice, c.NriFormat) callconv(.c) c.NriFormatSupportBits),
    GetQuerySize: ?*const fn (?*const c.NriQueryPool) callconv(.c) u32 = @import("std").mem.zeroes(?*const fn (?*const c.NriQueryPool) callconv(.c) u32),
    GetFenceValue: ?*const fn (?*c.NriFence) callconv(.c) u64 = @import("std").mem.zeroes(?*const fn (?*c.NriFence) callconv(.c) u64),
    GetQueue: ?*const fn (?*c.NriDevice, c.NriQueueType, u32, [*c]?*c.NriQueue) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, c.NriQueueType, u32, [*c]?*c.NriQueue) callconv(.c) c.NriResult),
    CreateCommandAllocator: ?*const fn (?*c.NriQueue, [*c]?*c.NriCommandAllocator) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriQueue, [*c]?*c.NriCommandAllocator) callconv(.c) c.NriResult),
    CreateCommandBuffer: ?*const fn (?*c.NriCommandAllocator, [*c]?*c.NriCommandBuffer) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriCommandAllocator, [*c]?*c.NriCommandBuffer) callconv(.c) c.NriResult),
    CreateFence: ?*const fn (?*c.NriDevice, u64, [*c]?*c.NriFence) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, u64, [*c]?*c.NriFence) callconv(.c) c.NriResult),
    CreateDescriptorPool: ?*const fn (?*c.NriDevice, [*c]const c.NriDescriptorPoolDesc, [*c]?*c.NriDescriptorPool) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriDescriptorPoolDesc, [*c]?*c.NriDescriptorPool) callconv(.c) c.NriResult),
    CreateBuffer: ?*const fn (?*c.NriDevice, [*c]const c.NriBufferDesc, [*c]?*c.NriBuffer) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriBufferDesc, [*c]?*c.NriBuffer) callconv(.c) c.NriResult),
    CreateTexture: ?*const fn (?*c.NriDevice, [*c]const c.NriTextureDesc, [*c]?*c.NriTexture) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriTextureDesc, [*c]?*c.NriTexture) callconv(.c) c.NriResult),
    CreatePipelineLayout: ?*const fn (?*c.NriDevice, [*c]const c.NriPipelineLayoutDesc, [*c]?*c.NriPipelineLayout) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriPipelineLayoutDesc, [*c]?*c.NriPipelineLayout) callconv(.c) c.NriResult),
    CreateGraphicsPipeline: ?*const fn (?*c.NriDevice, [*c]const c.NriGraphicsPipelineDesc, [*c]?*c.NriPipeline) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriGraphicsPipelineDesc, [*c]?*c.NriPipeline) callconv(.c) c.NriResult),
    CreateComputePipeline: ?*const fn (?*c.NriDevice, [*c]const c.NriComputePipelineDesc, [*c]?*c.NriPipeline) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriComputePipelineDesc, [*c]?*c.NriPipeline) callconv(.c) c.NriResult),
    CreateQueryPool: ?*const fn (?*c.NriDevice, [*c]const c.NriQueryPoolDesc, [*c]?*c.NriQueryPool) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriQueryPoolDesc, [*c]?*c.NriQueryPool) callconv(.c) c.NriResult),
    CreateSampler: ?*const fn (?*c.NriDevice, [*c]const c.NriSamplerDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriSamplerDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult),
    CreateBufferView: ?*const fn ([*c]const c.NriBufferViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn ([*c]const c.NriBufferViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult),
    CreateTexture1DView: ?*const fn ([*c]const c.NriTexture1DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn ([*c]const c.NriTexture1DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult),
    CreateTexture2DView: ?*const fn ([*c]const c.NriTexture2DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn ([*c]const c.NriTexture2DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult),
    CreateTexture3DView: ?*const fn ([*c]const c.NriTexture3DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn ([*c]const c.NriTexture3DViewDesc, [*c]?*c.NriDescriptor) callconv(.c) c.NriResult),
    DestroyCommandAllocator: ?*const fn (?*c.NriCommandAllocator) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandAllocator) callconv(.c) void),
    DestroyCommandBuffer: ?*const fn (?*c.NriCommandBuffer) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer) callconv(.c) void),
    DestroyDescriptorPool: ?*const fn (?*c.NriDescriptorPool) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorPool) callconv(.c) void),
    DestroyBuffer: ?*const fn (?*c.NriBuffer) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriBuffer) callconv(.c) void),
    DestroyTexture: ?*const fn (?*c.NriTexture) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriTexture) callconv(.c) void),
    DestroyDescriptor: ?*const fn (?*c.NriDescriptor) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptor) callconv(.c) void),
    DestroyPipelineLayout: ?*const fn (?*c.NriPipelineLayout) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriPipelineLayout) callconv(.c) void),
    DestroyPipeline: ?*const fn (?*c.NriPipeline) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriPipeline) callconv(.c) void),
    DestroyQueryPool: ?*const fn (?*c.NriQueryPool) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriQueryPool) callconv(.c) void),
    DestroyFence: ?*const fn (?*c.NriFence) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriFence) callconv(.c) void),
    GetBufferMemoryDesc: ?*const fn (?*const c.NriBuffer, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*const c.NriBuffer, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void),
    GetTextureMemoryDesc: ?*const fn (?*const c.NriTexture, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*const c.NriTexture, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void),
    GetBufferMemoryDesc2: ?*const fn (?*const c.NriDevice, [*c]const c.NriBufferDesc, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*const c.NriDevice, [*c]const c.NriBufferDesc, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void),
    GetTextureMemoryDesc2: ?*const fn (?*const c.NriDevice, [*c]const c.NriTextureDesc, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*const c.NriDevice, [*c]const c.NriTextureDesc, c.NriMemoryLocation, [*c]c.NriMemoryDesc) callconv(.c) void),
    AllocateMemory: ?*const fn (?*c.NriDevice, [*c]const c.NriAllocateMemoryDesc, [*c]?*c.NriMemory) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriAllocateMemoryDesc, [*c]?*c.NriMemory) callconv(.c) c.NriResult),
    BindBufferMemory: ?*const fn (?*c.NriDevice, [*c]const c.NriBufferMemoryBindingDesc, u32) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriBufferMemoryBindingDesc, u32) callconv(.c) c.NriResult),
    BindTextureMemory: ?*const fn (?*c.NriDevice, [*c]const c.NriTextureMemoryBindingDesc, u32) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice, [*c]const c.NriTextureMemoryBindingDesc, u32) callconv(.c) c.NriResult),
    FreeMemory: ?*const fn (?*c.NriMemory) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriMemory) callconv(.c) void),
    AllocateDescriptorSets: ?*const fn (?*c.NriDescriptorPool, ?*const c.NriPipelineLayout, u32, [*c]?*c.NriDescriptorSet, u32, u32) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorPool, ?*const c.NriPipelineLayout, u32, [*c]?*c.NriDescriptorSet, u32, u32) callconv(.c) c.NriResult),
    ResetDescriptorPool: ?*const fn (?*c.NriDescriptorPool) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorPool) callconv(.c) void),
    UpdateDescriptorRanges: ?*const fn (?*c.NriDescriptorSet, u32, u32, [*c]const c.NriDescriptorRangeUpdateDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorSet, u32, u32, [*c]const c.NriDescriptorRangeUpdateDesc) callconv(.c) void),
    UpdateDynamicConstantBuffers: ?*const fn (?*c.NriDescriptorSet, u32, u32, [*c]const ?*const c.NriDescriptor) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorSet, u32, u32, [*c]const ?*const c.NriDescriptor) callconv(.c) void),
    CopyDescriptorSet: ?*const fn (?*c.NriDescriptorSet, [*c]const c.NriDescriptorSetCopyDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriDescriptorSet, [*c]const c.NriDescriptorSetCopyDesc) callconv(.c) void),
    BeginCommandBuffer: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriDescriptorPool) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriDescriptorPool) callconv(.c) c.NriResult),
    CmdSetDescriptorPool: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriDescriptorPool) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriDescriptorPool) callconv(.c) void),
    CmdSetPipelineLayout: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriPipelineLayout) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriPipelineLayout) callconv(.c) void),
    CmdSetPipeline: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriPipeline) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriPipeline) callconv(.c) void),
    CmdSetDescriptorSet: ?*const fn (?*c.NriCommandBuffer, u32, ?*const c.NriDescriptorSet, [*c]const u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, u32, ?*const c.NriDescriptorSet, [*c]const u32) callconv(.c) void),
    CmdSetRootConstants: ?*const fn (?*c.NriCommandBuffer, u32, ?*const anyopaque, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, u32, ?*const anyopaque, u32) callconv(.c) void),
    CmdSetRootDescriptor: ?*const fn (?*c.NriCommandBuffer, u32, ?*c.NriDescriptor) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, u32, ?*c.NriDescriptor) callconv(.c) void),
    CmdBarrier: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriBarrierGroupDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriBarrierGroupDesc) callconv(.c) void),
    CmdSetIndexBuffer: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, c.NriIndexType) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, c.NriIndexType) callconv(.c) void),
    CmdSetVertexBuffers: ?*const fn (?*c.NriCommandBuffer, u32, [*c]const c.NriVertexBufferDesc, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, u32, [*c]const c.NriVertexBufferDesc, u32) callconv(.c) void),
    CmdSetViewports: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriViewport, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriViewport, u32) callconv(.c) void),
    CmdSetScissors: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriRect, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriRect, u32) callconv(.c) void),
    CmdSetStencilReference: ?*const fn (?*c.NriCommandBuffer, u8, u8) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, u8, u8) callconv(.c) void),
    CmdSetDepthBounds: ?*const fn (?*c.NriCommandBuffer, f32, f32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, f32, f32) callconv(.c) void),
    CmdSetBlendConstants: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriColor32f) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriColor32f) callconv(.c) void),
    CmdSetSampleLocations: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriSampleLocation, c.NriSample_t, c.NriSample_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriSampleLocation, c.NriSample_t, c.NriSample_t) callconv(.c) void),
    CmdSetShadingRate: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriShadingRateDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriShadingRateDesc) callconv(.c) void),
    CmdSetDepthBias: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDepthBiasDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDepthBiasDesc) callconv(.c) void),
    CmdBeginRendering: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriAttachmentsDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriAttachmentsDesc) callconv(.c) void),
    CmdClearAttachments: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriClearDesc, u32, [*c]const c.NriRect, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriClearDesc, u32, [*c]const c.NriRect, u32) callconv(.c) void),
    CmdDraw: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDrawDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDrawDesc) callconv(.c) void),
    CmdDrawIndexed: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDrawIndexedDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDrawIndexedDesc) callconv(.c) void),
    CmdDrawIndirect: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, u32, u32, ?*const c.NriBuffer, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, u32, u32, ?*const c.NriBuffer, u64) callconv(.c) void),
    CmdDrawIndexedIndirect: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, u32, u32, ?*const c.NriBuffer, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64, u32, u32, ?*const c.NriBuffer, u64) callconv(.c) void),
    CmdEndRendering: ?*const fn (?*c.NriCommandBuffer) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer) callconv(.c) void),
    CmdDispatch: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDispatchDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriDispatchDesc) callconv(.c) void),
    CmdDispatchIndirect: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriBuffer, u64) callconv(.c) void),
    CmdCopyBuffer: ?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, u64, ?*const c.NriBuffer, u64, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, u64, ?*const c.NriBuffer, u64, u64) callconv(.c) void),
    CmdCopyTexture: ?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void),
    CmdUploadBufferToTexture: ?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriBuffer, [*c]const c.NriTextureDataLayoutDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriBuffer, [*c]const c.NriTextureDataLayoutDesc) callconv(.c) void),
    CmdReadbackTextureToBuffer: ?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, [*c]const c.NriTextureDataLayoutDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, [*c]const c.NriTextureDataLayoutDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void),
    CmdZeroBuffer: ?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, u64, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriBuffer, u64, u64) callconv(.c) void),
    CmdResolveTexture: ?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriTexture, [*c]const c.NriTextureRegionDesc, ?*const c.NriTexture, [*c]const c.NriTextureRegionDesc) callconv(.c) void),
    CmdClearStorage: ?*const fn (?*c.NriCommandBuffer, [*c]const c.NriClearStorageDesc) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const c.NriClearStorageDesc) callconv(.c) void),
    CmdResetQueries: ?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32, u32) callconv(.c) void),
    CmdBeginQuery: ?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32) callconv(.c) void),
    CmdEndQuery: ?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*c.NriQueryPool, u32) callconv(.c) void),
    CmdCopyQueries: ?*const fn (?*c.NriCommandBuffer, ?*const c.NriQueryPool, u32, u32, ?*c.NriBuffer, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, ?*const c.NriQueryPool, u32, u32, ?*c.NriBuffer, u64) callconv(.c) void),
    CmdBeginAnnotation: ?*const fn (?*c.NriCommandBuffer, [*c]const u8, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const u8, u32) callconv(.c) void),
    CmdEndAnnotation: ?*const fn (?*c.NriCommandBuffer) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer) callconv(.c) void),
    CmdAnnotation: ?*const fn (?*c.NriCommandBuffer, [*c]const u8, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer, [*c]const u8, u32) callconv(.c) void),
    EndCommandBuffer: ?*const fn (?*c.NriCommandBuffer) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriCommandBuffer) callconv(.c) c.NriResult),
    QueueBeginAnnotation: ?*const fn (?*c.NriQueue, [*c]const u8, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriQueue, [*c]const u8, u32) callconv(.c) void),
    QueueEndAnnotation: ?*const fn (?*c.NriQueue) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriQueue) callconv(.c) void),
    QueueAnnotation: ?*const fn (?*c.NriQueue, [*c]const u8, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriQueue, [*c]const u8, u32) callconv(.c) void),
    ResetQueries: ?*const fn (?*c.NriQueryPool, u32, u32) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriQueryPool, u32, u32) callconv(.c) void),
    QueueSubmit: ?*const fn (?*c.NriQueue, [*c]const c.NriQueueSubmitDesc) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriQueue, [*c]const c.NriQueueSubmitDesc) callconv(.c) c.NriResult),
    DeviceWaitIdle: ?*const fn (?*c.NriDevice) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriDevice) callconv(.c) c.NriResult),
    QueueWaitIdle: ?*const fn (?*c.NriQueue) callconv(.c) c.NriResult = @import("std").mem.zeroes(?*const fn (?*c.NriQueue) callconv(.c) c.NriResult),
    Wait: ?*const fn (?*c.NriFence, u64) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriFence, u64) callconv(.c) void),
    ResetCommandAllocator: ?*const fn (?*c.NriCommandAllocator) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriCommandAllocator) callconv(.c) void),
    MapBuffer: ?*const fn (?*c.NriBuffer, u64, u64) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (?*c.NriBuffer, u64, u64) callconv(.c) ?*anyopaque),
    UnmapBuffer: ?*const fn (?*c.NriBuffer) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriBuffer) callconv(.c) void),
    SetDebugName: ?*const fn (?*c.NriObject, [*c]const u8) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*c.NriObject, [*c]const u8) callconv(.c) void),
    GetDeviceNativeObject: ?*const fn (?*const c.NriDevice) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (?*const c.NriDevice) callconv(.c) ?*anyopaque),
    GetQueueNativeObject: ?*const fn (?*const c.NriQueue) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (?*const c.NriQueue) callconv(.c) ?*anyopaque),
    GetCommandBufferNativeObject: ?*const fn (?*const c.NriCommandBuffer) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (?*const c.NriCommandBuffer) callconv(.c) ?*anyopaque),
    GetBufferNativeObject: ?*const fn (?*const c.NriBuffer) callconv(.c) u64 = @import("std").mem.zeroes(?*const fn (?*const c.NriBuffer) callconv(.c) u64),
    GetTextureNativeObject: ?*const fn (?*const c.NriTexture) callconv(.c) u64 = @import("std").mem.zeroes(?*const fn (?*const c.NriTexture) callconv(.c) u64),
    GetDescriptorNativeObject: ?*const fn (?*const c.NriDescriptor) callconv(.c) u64 = @import("std").mem.zeroes(?*const fn (?*const c.NriDescriptor) callconv(.c) u64),
};

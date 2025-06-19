const std = @import("std");

const ffi = @import("ffi.zig");
const log = @import("log.zig");

const gdn = log.gdn;
const sdl = log.sdl;

const c = ffi.c;
const cstr = ffi.cstr;

/// An `SDL_Window`-wrapper.
pub const Window = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,

    content_scale: f32 = 1.0,
    size: [2]u32,
    position: [2]u32,

    flags: Flags,

    // Types

    const Self = @This();
    pub const InitOptions = struct {
        /// The name of the window.
        name: []const u8,
        /// The initial size of the window in pixels.
        initial_size: [2]u32,
        /// The initial position of the window in pixels from the top-left.
        /// Can be centered per-axis with `c.SDL_WINDOWPOS_CENTERED`.
        initial_position: [2]u32 = .{ @intCast(c.SDL_WINDOWPOS_CENTERED), @intCast(c.SDL_WINDOWPOS_CENTERED) },
        /// The `SDL_WindowFlags` to initial the `SDL_Window` with.
        window_flags: c.SDL_WindowFlags = 0,
        /// The swapchain parameters for the `SDL_GPUDevice`.
        swapchain_parameters: struct {
            composition: c.SDL_GPUSwapchainComposition = c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            present_mode: c.SDL_GPUPresentMode = c.SDL_GPU_PRESENTMODE_MAILBOX,
        } = .{},
        /// The amount of frames that can be in-flight at once.
        /// SDL supports [1-3].
        frames_in_flight: u8 = 3,
    };
    pub const Flags = struct {
        /// Has the window closed?
        close_window: *bool,
    };
    pub const SDLError = error{SDLError};
    pub const InitError = error{
        SDLNotInitialized,
    } || SDLError;

    // (De)Initialization

    pub fn init(allocator: std.mem.Allocator, options: InitOptions, flags: Flags) !Self {
        // Make sure video has been initialized.
        if (c.SDL_WasInit(c.SDL_INIT_VIDEO) & c.SDL_INIT_VIDEO == 0) {
            gdn.err(
                "Attempted to initialize a window without first initializing" ++
                    " SDL for video.",
                .{},
            );
            return InitError.SDLNotInitialized;
        }

        // Setup the window instance.
        var self: Self = undefined;
        self.flags = flags;

        // Get the display scale for the primary display to set the initial window size.
        // TODO: Not sure of the behavior of `SDL_GetPrimaryDisplay`.
        {
            self.content_scale = c.SDL_GetDisplayContentScale(c.SDL_GetPrimaryDisplay());
            self.size = [_]u32{
                @intFromFloat(self.content_scale * @as(f32, @floatFromInt(options.initial_size[0]))),
                @intFromFloat(self.content_scale * @as(f32, @floatFromInt(options.initial_size[1]))),
            };
        }

        // Create the window handle.
        {
            const name = try cstr(allocator, options.name);
            defer allocator.free(name);

            self.window = c.SDL_CreateWindow(
                name,
                @intCast(self.size[0]),
                @intCast(self.size[1]),
                options.window_flags | c.SDL_WINDOW_HIDDEN,
            ) orelse {
                sdl.err("SDL_CreateWindow");
                return SDLError.SDLError;
            };
        }

        // Move the window to the correct position then show the window.
        {
            if (!c.SDL_SetWindowPosition(self.window, @intCast(options.initial_position[0]), @intCast(options.initial_position[1]))) {
                sdl.err("SDL_SetWindowPosition");
                return SDLError.SDLError;
            }
            if (!c.SDL_ShowWindow(self.window)) {
                sdl.err("SDL_ShowWindow");
                return SDLError.SDLError;
            }
        }

        // Create the GPU device and claim the window for it.
        // TODO: If `debug_mode` is enabled, `c.cImGui_ImplSDLGPU3_RenderDrawData` below crashes
        // with an a load of some random value not being "valid for type 'bool'". I am not sure
        // how to fix this currently but it appears to be some sort of use-after-free?
        // TODO: We are locked for Vulkan currently and will be for some time. There are plans
        // to migrate to Vulkan fully and create my own SDL3GPU-esque API.
        {
            self.device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, false, null) orelse {
                sdl.err("SDL_CreateGPUDevice");
                return SDLError.SDLError;
            };
            if (!c.SDL_ClaimWindowForGPUDevice(self.device, self.window)) {
                sdl.err("SDL_ClaimWindowForGPUDevice");
                return SDLError.SDLError;
            }
        }

        // Configure additional device parameters.
        {
            if (!c.SDL_SetGPUSwapchainParameters(self.device, self.window, options.swapchain_parameters.composition, options.swapchain_parameters.present_mode)) {
                sdl.err("SDL_SetGPUSwapchainParameters");
                return SDLError.SDLError;
            }
            if (!c.SDL_SetGPUAllowedFramesInFlight(self.device, options.frames_in_flight)) {
                sdl.err("SDL_SetGPUAllowedFramesInFlight");
                return SDLError.SDLError;
            }
        }

        // Poll information about the window and cache it.
        {
            var tmp1: c_int = 0;
            var tmp2: c_int = 0;

            if (c.SDL_GetWindowPosition(self.window, &tmp1, &tmp2)) {
                self.position = .{ @intCast(tmp1), @intCast(tmp2) };
            } else {
                // TODO: Does `self.content_scale` affect this?
                self.position = options.initial_position;
            }

            // TODO: This may be unnecessary as we set it previously.
            if (c.SDL_GetWindowSizeInPixels(self.window, &tmp1, &tmp2)) {
                self.size = .{ @intCast(tmp1), @intCast(tmp2) };
            } else {
                self.size = options.initial_size;
            }
        }

        return self;
    }

    pub fn deinit(self: Self) void {
        _ = c.SDL_WaitForGPUIdle(self.device);

        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
    }

    // Lifecycle Methods

    pub fn processEvents(self: *Self, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, c.SDL_EVENT_WINDOW_DESTROYED => self.flags.close_window.* = true,
        }
    }

    // Usage Methods

    pub fn acquireCommandBuffer(self: *const Self) SDLError!*c.SDL_GPUCommandBuffer {
        return c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            sdl.err("SDL_AcquireGPUCommandBuffer");
            return SDLError.SDLError;
        };
    }

    pub fn waitAndAcquireGPUSwapchainTexture(self: *const Self, cmd: *c.SDL_GPUCommandBuffer) SDLError!?*c.SDL_GPUTexture {
        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain_texture, null, null)) {
            sdl.err("SDL_WaitAndAcquireGPUSwapchainTexture");
            return SDLError.SDLError;
        }
        return swapchain_texture;
    }

    // Getters

    pub fn getSwapchainTextureFormat(self: *const Self) c.SDL_GPUTextureFormat {
        return c.SDL_GetGPUSwapchainTextureFormat(self.device, self.window);
    }
};

const std = @import("std");

const FZ = @import("perf/tracy.zig").FnZone;
const DEBUG = @import("root").DEBUG;

// C export

const build_opts = @import("build-opts");

pub const c = @cImport({
    // SDL3
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");

    // ImGui
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_sdlgpu3.h");
    @cInclude("backends/dcimgui_impl_sdl3.h");

    // tinyobj_loader_c
    @cInclude("tinyobj_loader_c.h");

    // Tracy
    if (build_opts.enable_tracy) {
        @cDefine("TRACY_ENABLE", {});
        if (build_opts.enable_tracy_callstack) @cDefine("TRACY_CALLSTACK", {});

        @cInclude("tracy/TracyC.h");
    }
});

// C-Interop

pub fn CStr(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    const out = try allocator.alloc(u8, str.len + 1);
    @memset(out, 0);
    std.mem.copyForwards(u8, out, str);
    return @ptrCast(out);
}

pub fn freeCStr(allocator: std.mem.Allocator, str: [:0]const u8) void {
    allocator.free(str[0..str.len]);
}

// SDL

/// Usage Notes:
/// - [Cycling](https://moonside.games/posts/sdl-gpu-concepts-cycling/):
///     - Previous commands using the resource have their data integrity preserved.
///     - The data in the resource is undefined for subsequent commands until it is written to.
/// - Upload all dynamic buffer data early in the frame before you do any render or compute passes.
pub const SDL = struct {
    // -- Logging -- //

    pub const log = std.log.scoped(.sdl);

    pub fn err(comptime sdl_function: []const u8, comptime format: []const u8, args: anytype) void {
        log.err("" ++ sdl_function ++ ": {s}. " ++ format, .{c.SDL_GetError()} ++ args);
    }

    // -- Enums -- //

    pub const ShaderStage = enum {
        Vertex,
        Fragment,
    };

    // -- Initialization -- //

    /// [SDL_Init](https://wiki.libsdl.org/SDL3/SDL_Init):
    /// Initialize the SDL library.
    ///
    /// `SDL_Init()` simply forwards to calling `SDL_InitSubSystem()`. Therefore, the two may be used interchangeably.
    /// Though for readability of your code `SDL_InitSubSystem()` might be preferred.
    ///
    /// The file I/O (for example: `SDL_IOFromFile`) and threading (`SDL_CreateThread`) subsystems are initialized by
    /// default. Message boxes (`SDL_ShowSimpleMessageBox`) also attempt to work without initializing the video
    /// subsystem,in hopes of being useful in showing an error dialog when `SDL_Init` fails. You must specifically
    /// initialize other  subsystems if you use them in your application.
    ///
    /// Logging (such as `SDL_Log`) works without initialization, too.
    ///
    /// `flags` may be any of the following OR'd together:
    ///
    ///     `SDL_INIT_AUDIO`: audio subsystem; automatically initializes the events subsystem
    ///     `SDL_INIT_VIDEO`: video subsystem; automatically initializes the events subsystem, should be initialized on
    ///                       the main thread.
    ///     `SDL_INIT_JOYSTICK`: joystick subsystem; automatically initializes the events subsystem
    ///     `SDL_INIT_HAPTIC`: haptic (force feedback) subsystem
    ///     `SDL_INIT_GAMEPAD`: gamepad subsystem; automatically initializes the joystick subsystem
    ///     `SDL_INIT_EVENTS`: events subsystem
    ///     `SDL_INIT_SENSOR`: sensor subsystem; automatically initializes the events subsystem
    ///     `SDL_INIT_CAMERA`: camera subsystem; automatically initializes the events subsystem
    ///
    /// Subsystem initialization is ref-counted, you must call `SDL_QuitSubSystem()` for each `SDL_InitSubSystem()` to
    /// correctly shutdown a subsystem manually (or call `SDL_Quit()` to force shutdown). If a subsystem is already
    /// loaded then this call will increase the ref-count and return.
    ///
    /// Consider reporting some basic metadata about your application before calling `SDL_Init`, using either
    /// `SDL_SetAppMetadata()` or `SDL_SetAppMetadataProperty()`.
    ///
    /// Additionally calls `SDL_SetMainReady()` before `SDL_Init`:
    ///
    /// [SDL_SetMainReady](https://wiki.libsdl.org/SDL3/SDL_SetMainReady):
    /// Circumvent failure of SDL_Init() when not using SDL_main() as an entry point.
    ///
    /// This function is defined in SDL_main.h, along with the preprocessor rule to redefine main() as SDL_main(). Thus
    /// to ensure that your main() function will not be changed it is necessary to define SDL_MAIN_HANDLED before
    /// including SDL.h.
    pub fn initialize(flags: c.SDL_InitFlags) !void {
        // Initialize SDL.
        if (!c.SDL_Init(flags)) {
            err("Init", "flags = {b}", .{flags});
            return error.SDLError;
        }

        log.info("Successfully initialized SDL with flags = {b}.", .{flags});
    }

    // TODO: `SDL_InitSubSystem()`

    /// [SDL_WasInit](https://wiki.libsdl.org/SDL3/SDL_WasInit):
    /// Get a mask of the specified subsystems which are currently initialized.
    pub fn isInitialized(mask: c.SDL_InitFlags) bool {
        return c.SDL_WasInit(mask) == mask;
    }

    // -- Properties -- //

    /// [SDL_SetStringProperty](https://wiki.libsdl.org/SDL3/SDL_SetStringProperty):
    /// Set a string property in a group of properties.
    ///
    /// This function makes a copy of the string; the caller does not have to preserve the data after this call
    /// completes.
    ///
    /// It is safe to call this function from any thread.
    pub fn setGlobalStringProperty(allocator: std.mem.Allocator, name: [:0]const u8, value: []const u8) !void {
        const cvalue = try CStr(allocator, value);
        defer freeCStr(allocator, cvalue);

        if (!c.SDL_SetStringProperty(c.SDL_GetGlobalProperties(), name, cvalue)) {
            err("SetStringProperty", "{s} = {s}", .{ name, cvalue });
        }
    }

    // -- Window -- //

    pub const Window = struct {
        handle: *c.SDL_Window,
        display_scale: f32 = 1.0,

        // -- Initialization -- //

        /// [SDL_CreateWindow](https://wiki.libsdl.org/SDL3/SDL_CreateWindow):
        /// Create a window with the specified dimensions and flags.
        ///
        /// The window size is a request and may be different than expected based on the desktop layout and window
        /// manager policies. Your application should be prepared to handle a window of any size.
        ///
        /// `flags` may be any of the following OR'd together:
        ///
        ///     `SDL_WINDOW_FULLSCREEN`: fullscreen window at desktop resolution
        ///     `SDL_WINDOW_OPENGL`: window usable with an OpenGL context
        ///     `SDL_WINDOW_OCCLUDED`: window partially or completely obscured by another window
        ///     `SDL_WINDOW_HIDDEN`: window is not visible
        ///     `SDL_WINDOW_BORDERLESS`: no window decoration
        ///     `SDL_WINDOW_RESIZABLE`: window can be resized
        ///     `SDL_WINDOW_MINIMIZED`: window is minimized
        ///     `SDL_WINDOW_MAXIMIZED`: window is maximized
        ///     `SDL_WINDOW_MOUSE_GRABBED`: window has grabbed mouse focus
        ///     `SDL_WINDOW_INPUT_FOCUS`: window has input focus
        ///     `SDL_WINDOW_MOUSE_FOCUS`: window has mouse focus
        ///     `SDL_WINDOW_EXTERNAL`: window not created by SDL
        ///     `SDL_WINDOW_MODAL`: window is modal
        ///     `SDL_WINDOW_HIGH_PIXEL_DENSITY`: window uses high pixel density back buffer if possible
        ///     `SDL_WINDOW_MOUSE_CAPTURE`: window has mouse captured (unrelated to `MOUSE_GRABBED`)
        ///     `SDL_WINDOW_ALWAYS_ON_TOP`: window should always be above others
        ///     `SDL_WINDOW_UTILITY`: window should be treated as a utility window, not showing in the task bar and
        ///                           window list
        ///     `SDL_WINDOW_TOOLTIP`: window should be treated as a tooltip and does not get mouse or keyboard focus,
        ///                           requires a parent window
        ///     `SDL_WINDOW_POPUP_MENU`: window should be treated as a popup menu, requires a parent window
        ///     `SDL_WINDOW_KEYBOARD_GRABBED`: window has grabbed keyboard input
        ///     `SDL_WINDOW_VULKAN`: window usable with a Vulkan instance
        ///     `SDL_WINDOW_METAL`: window usable with a Metal instance
        ///     `SDL_WINDOW_TRANSPARENT`: window with transparent buffer
        ///     `SDL_WINDOW_NOT_FOCUSABLE`: window should not be focusable
        ///
        /// The `SDL_Window` is implicitly shown if `SDL_WINDOW_HIDDEN` is not set.
        ///
        /// On Apple's macOS, you must set the NSHighResolutionCapable Info.plist property to YES, otherwise you will
        /// not receive a High-DPI OpenGL canvas.
        ///
        /// The window pixel size may differ from its window coordinate size if the window is on a high pixel density
        /// display. Use `SDL_GetWindowSize()` to query the client area's size in window coordinates, and
        /// `SDL_GetWindowSizeInPixels()` or `SDL_GetRenderOutputSize()` to query the drawable size in pixels. Note that
        /// the drawable size can vary after the window is created and should be queried again if you get an
        /// `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` event.
        ///
        /// If the window is created with any of the `SDL_WINDOW_OPENGL` or `SDL_WINDOW_VULKAN` flags, then the
        /// corresponding `LoadLibrary` function (`SDL_GL_LoadLibrary()` or `SDL_Vulkan_LoadLibrary()`) is called and
        /// the corresponding `UnloadLibrary` function is called by `SDL_DestroyWindow()`.
        ///
        /// If `SDL_WINDOW_VULKAN` is specified and there isn't a working Vulkan driver, `SDL_CreateWindow()` will fail,
        /// because `SDL_Vulkan_LoadLibrary()` will fail.
        ///
        /// If `SDL_WINDOW_METAL` is specified on an OS that does not support Metal, `SDL_CreateWindow()` will fail.
        ///
        /// If you intend to use this window with an `SDL_Renderer`, you should use `SDL_CreateWindowAndRenderer()`
        /// instead of this function, to avoid window flicker.
        ///
        /// On non-Apple devices, SDL requires you to either not link to the Vulkan loader or link to a dynamic library
        /// version. This limitation may be removed in a future version of SDL.
        ///
        /// This function should only be called on the main thread.
        pub fn create(
            allocator: std.mem.Allocator,
            /// the title of the window, in UTF-8 encoding.
            title: []const u8,
            /// the (w, h) of the window.
            size: [2]u32,
            /// the (x, y)) of the window.
            position: [2]u32,
        ) !Window {
            var fz = FZ.init(@src(), "SDL.Window.create");
            defer fz.end();

            fz.push(@src(), "title -> ctitle");
            const ctitle = try CStr(allocator, title);
            defer freeCStr(allocator, ctitle);

            // Create the window.
            fz.replace(@src(), "SDL_CreateWindowWithProperties");
            const props = c.SDL_CreateProperties();
            if (props == 0) err("CreateProperties", "", .{});

            _ = c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, ctitle);
            _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
            _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_VULKAN_BOOLEAN, true);
            // TODO: _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true);
            _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, @intCast(size[0]));
            _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, @intCast(size[1]));
            _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, @intCast(position[0]));
            _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, @intCast(position[1]));

            var window = Window{
                .handle = c.SDL_CreateWindowWithProperties(props) orelse {
                    err("CreateWindowWithProperties", "title = {s}, size = {any}, position = {any}", .{
                        title,
                        size,
                        position,
                    });
                    return error.SDLError;
                },
            };

            // Scale the window up to the proper display scale.
            fz.replace(@src(), "sync size");
            _ = try window.syncSizeToDisplayScale();

            // Debug the creation.
            if (DEBUG) {
                fz.replace(@src(), "debug logging");
                const display = try window.getDisplay();
                const display_scale = try window.getDisplayScaleAndUpdateCachedValue();
                const display_mode = display.getCurrentDisplayMode();

                const actual_position = try window.getPosition();
                const actual_size = try window.getSizeInPixels();

                log.debug(
                    "Window '{s}' created on display '{s}' ({}x{}({d}x)@{d}hz) " ++
                        "at ({}px, {}px) with a size of ({}px, {}px).",
                    .{
                        title,
                        c.SDL_GetDisplayName(display.id),
                        display_mode.w,
                        display_mode.h,
                        display_scale,
                        display_mode.refresh_rate,
                        actual_position[0],
                        actual_position[1],
                        actual_size[0],
                        actual_size[1],
                    },
                );
            }

            // Return the new window handle.
            return window;
        }

        // -- Deinitialization -- //

        /// [SDL_DestroyWindow](https://wiki.libsdl.org/SDL3/SDL_DestroyWindow):
        /// Destroy a window.
        ///
        /// Any child windows owned by the window will be recursively destroyed as well.
        ///
        /// Note that on some platforms, the visible window may not actually be removed from the screen until the SDL
        /// event loop is pumped again, even though the `SDL_Window` is no longer valid after this call.
        pub fn destroy(window: *Window) !void {
            var fz = FZ.init(@src(), "SDL.Window.destroy");
            defer fz.end();

            c.SDL_DestroyWindow(window.handle);
        }

        // -- Getters -- //

        /// [SDL_GetDisplayForWindow](https://wiki.libsdl.org/SDL3/SDL_GetDisplayForWindow):
        /// Get the display associated with a window.
        ///
        /// This function should only be called on the main thread.
        pub fn getDisplay(window: *const Window) !Display {
            const id = c.SDL_GetDisplayForWindow(window.handle);
            if (id == 0) {
                err("GetDisplayForWindow", "", .{});
                return error.SDLError;
            }
            return .{ .id = id };
        }

        /// [SDL_GetWindowDisplayScale](https://wiki.libsdl.org/SDL3/SDL_GetWindowDisplayScale):
        /// Get the content display scale relative to a window's pixel size.
        ///
        /// This is a combination of the window pixel density and the display content scale, and is the expected scale
        /// for displaying content in this window. For example, if a 3840x2160 window had a display scale of 2.0, the
        /// user expects the content to take twice as many pixels and be the same physical size as if it were being
        /// displayed in a 1920x1080 window with a display scale of 1.0.
        ///
        /// Conceptually this value corresponds to the scale display setting, and is updated when that setting is
        /// changed, or the window moves to a display with a different scale setting.
        ///
        /// This function should only be called on the main thread.
        pub fn getDisplayScale(window: *const Window) !f32 {
            const display_scale = c.SDL_GetWindowDisplayScale(window.handle);
            if (display_scale == 0) {
                err("GetWindowDisplayScale", "", .{});
                return error.SDLError;
            }
            return display_scale;
        }

        /// Gets the display scale of the window then updates the cached value in `Window`.
        /// This value is intended to be used to properly scale a window when the display scale has changed.
        pub fn getDisplayScaleAndUpdateCachedValue(window: *Window) !f32 {
            window.display_scale = try window.getDisplayScale();
            return window.display_scale;
        }

        /// [SDL_GetWindowPosition](https://wiki.libsdl.org/SDL3/SDL_GetWindowPosition):
        /// Get the position of a window.
        ///
        /// This is the current position of the window as last reported by the windowing system.
        ///
        /// This function should only be called on the main thread.
        pub fn getPosition(window: *const Window) ![2]u32 {
            var position: [2]c_int = undefined;
            if (!c.SDL_GetWindowPosition(window.handle, &position[0], &position[1])) {
                err("GetWindowPosition", "", .{});
                return error.SDLError;
            }
            return .{ @intCast(position[0]), @intCast(position[1]) };
        }

        /// [SDL_GetWindowSizeInPixels](https://wiki.libsdl.org/SDL3/SDL_GetWindowSizeInPixels):
        /// Get the size of a window's client area, in pixels.
        ///
        /// This function should only be called on the main thread.
        pub fn getSizeInPixels(window: *const Window) ![2]u32 {
            var size: [2]c_int = undefined;
            if (!c.SDL_GetWindowSizeInPixels(window.handle, &size[0], &size[1])) {
                err("GetWindowSizeInPixels", "", .{});
                return error.SDLError;
            }
            return .{ @intCast(size[0]), @intCast(size[1]) };
        }

        /// [SDL_GetWindowTitle](https://wiki.libsdl.org/SDL3/SDL_GetWindowTitle):
        /// Get the title of a window.
        ///
        /// Returns the title of the window in UTF-8 format or "" if there is no title.
        ///
        /// This function should only be called on the main thread.
        pub fn getTitle(window: *const Window) [:0]const u8 {
            return std.mem.span(c.SDL_GetWindowTitle(window.handle));
        }

        // -- Setters -- //

        /// [SDL_SetWindowPosition](https://wiki.libsdl.org/SDL3/SDL_SetWindowPosition):
        /// Request that the window's position be set.
        ///
        /// If the window is in an exclusive fullscreen or maximized state, this request has no effect.
        ///
        /// This can be used to reposition fullscreen-desktop windows onto a different display, however, as exclusive
        /// fullscreen windows are locked to a specific display, they can only be repositioned programmatically via
        /// SDL_SetWindowFullscreenMode().
        ///
        /// On some windowing systems this request is asynchronous and the new coordinates may not have have been
        /// applied immediately upon the return of this function. If an immediate change is required, call
        /// SDL_SyncWindow() to block until the changes have taken effect.
        ///
        /// When the window position changes, an SDL_EVENT_WINDOW_MOVED event will be emitted with the window's new
        /// coordinates. Note that the new coordinates may not match the exact coordinates requested, as some windowing
        /// systems can restrict the position of the window in certain scenarios (e.g. constraining the position so the
        /// window is always within desktop bounds). Additionally, as this is just a request, it can be denied by the
        /// windowing system.
        ///
        /// This function should only be called on the main thread.
        pub fn setPosition(
            window: *const Window,
            /// the x coordinate of the window, or SDL_WINDOWPOS_CENTERED or SDL_WINDOWPOS_UNDEFINED.
            x: u32,
            /// the y coordinate of the window, or SDL_WINDOWPOS_CENTERED or SDL_WINDOWPOS_UNDEFINED.
            y: u32,
        ) !void {
            var fz = FZ.init(@src(), "SDL.Window.setPosition");
            defer fz.end();

            if (!c.SDL_SetWindowPosition(window.handle, @intCast(x), @intCast(y))) {
                err("SetWindowPosition", "x = {}, y = {}", .{ x, y });
                return error.SDLError;
            }

            // TODO: Query the window position again and then show if they diff form the intended position.
            log.debug(
                "Window '{s}' has changed position to ({}, {}). NOTE: A coordinate of {} means centered.",
                .{ window.getTitle(), x, y, c.SDL_WINDOWPOS_CENTERED },
            );
        }

        /// [SDL_SetWindowSize](https://wiki.libsdl.org/SDL3/SDL_SetWindowSize):
        /// Request that the size of a window's client area be set.
        ///
        /// If the window is in a fullscreen or maximized state, this request has no effect.
        ///
        /// To change the exclusive fullscreen mode of a window, use `SDL_SetWindowFullscreenMode()`.
        ///
        /// On some windowing systems, this request is asynchronous and the new window size may not have have been
        /// applied immediately upon the return of this function. If an immediate change is required, call
        /// `SDL_SyncWindow()` to block until the changes have taken effect.
        ///
        /// When the window size changes, an `SDL_EVENT_WINDOW_RESIZED` event will be emitted with the new window
        /// dimensions. Note that the new dimensions may not match the exact size requested, as some windowing systems
        /// can restrict the window size in certain scenarios (e.g. constraining the size of the content area to remain
        /// within the usable desktop bounds). Additionally, as this is just a request, it can be denied by the
        /// windowing system.
        pub fn setSize(window: *const Window, w: u32, h: u32) !void {
            std.debug.assert(w > 0);
            std.debug.assert(h > 0);

            var fz = FZ.init(@src(), "SDL.Window.setSize");
            defer fz.end();

            if (!c.SDL_SetWindowSize(window.handle, @intCast(w), @intCast(h))) {
                err("SetWindowSize", "w = {}, h = {}", .{ w, h });
                return error.SDLError;
            }

            // TODO: Query the window size again and then show if they diff form the intended size.
            log.debug("Window '{s}' has changed size to ({}px, {}px).", .{ window.getTitle(), w, h });
        }

        /// [SDL_ShowWindow](https://wiki.libsdl.org/SDL3/SDL_ShowWindow):
        /// Show a window.
        ///
        /// This function should only be called on the main thread.
        pub fn show(window: *const Window) !void {
            var fz = FZ.init(@src(), "SDL.Window.show");
            defer fz.end();

            if (!c.SDL_ShowWindow(window.handle)) {
                err("ShowWindow", "", .{});
                return error.SDLError;
            }

            log.debug("Window '{s}' shown.", .{window.getTitle()});
        }

        /// [SDL_SyncWindow](https://wiki.libsdl.org/SDL3/SDL_SyncWindow):
        /// Block until any pending window state is finalized.
        ///
        /// On asynchronous windowing systems, this acts as a synchronization barrier for pending window state. It will
        /// attempt to wait until any pending window state has been applied and is guaranteed to return within finite
        /// time. Note that for how long it can potentially block depends on the underlying window system, as window
        /// state changes may involve somewhat lengthy animations that must complete before the window is in its final
        /// requested state.
        ///
        /// On windowing systems where changes are immediate, this does nothing.
        ///
        /// This function should only be called on the main thread.
        pub fn sync(window: *const Window) !void {
            var fz = FZ.init(@src(), "SDL.Window.sync");
            defer fz.end();

            log.debug("Blocking until pending window state is finalized for window '{s}'.", .{window.getTitle()});
            if (!c.SDL_SyncWindow(window.handle)) {
                err("SyncWindow", "", .{});
                return error.SDLError;
            }
        }

        /// Scales the window's size by the display scale.
        /// Also updates the cached display scale value.
        ///
        /// Returns the ratio between the new and old display scales.
        pub fn syncSizeToDisplayScale(window: *Window) !f32 {
            var fz = FZ.init(@src(), "SDL.Window.syncSizeToDisplayScale");
            defer fz.end();

            const display_scale = try window.getDisplayScale();
            if (display_scale == window.display_scale) return 1;
            defer window.display_scale = display_scale;

            const size = try window.getSizeInPixels();
            const ratio = display_scale / window.display_scale;
            const new_size = [_]u32{
                @intFromFloat(@as(f32, @floatFromInt(size[0])) * ratio),
                @intFromFloat(@as(f32, @floatFromInt(size[1])) * ratio),
            };

            try window.setSize(new_size[0], new_size[1]);

            log.debug(
                "Window '{s}' has changed display scale from {d} to {d}, " ++
                    "thus changing the window size from ({}px, {}px) to ({}px, {}px).",
                .{ window.getTitle(), window.display_scale, display_scale, size[0], size[1], new_size[0], new_size[1] },
            );

            return ratio;
        }
    };

    /// See `Window.getDisplayId()`.
    pub const Display = struct {
        id: c.SDL_DisplayID,

        // -- Getters -- //

        /// [SDL_GetCurrentDisplayMode](https://wiki.libsdl.org/SDL3/SDL_GetCurrentDisplayMode):
        /// Get information about the current display mode.
        pub fn getCurrentDisplayMode(display_id: *const Display) *const c.SDL_DisplayMode {
            return c.SDL_GetCurrentDisplayMode(display_id.id);
        }

        /// [SDL_GetDisplayContentScale](https://wiki.libsdl.org/SDL3/SDL_GetDisplayContentScale):
        /// Get the content scale of a display.
        pub fn getContentScale(display_id: *const Display) f32 {
            return c.SDL_GetDisplayContentScale(display_id.id);
        }
    };

    // -- GPU -- //

    // Device

    /// See `Window.createGPUDevice()`.
    pub const GPUDevice = struct {
        handle: *c.SDL_GPUDevice,

        // -- Types -- //

        /// Parameters to configure the GPU Swapchain.
        pub const SwapchainParameters = struct {
            swapchain_composition: SwapchainComposition = .SDR,
            present_mode: PresentMode = .VSYNC,

            pub const SwapchainComposition = enum(c.SDL_GPUSwapchainComposition) {
                SDR = 0,
                SDR_LINEAR = 1,
                HDR_EXTENDED_LINEAR = 2,
                HDR10_ST2084 = 3,
            };

            pub const PresentMode = enum(c.SDL_GPUPresentMode) {
                VSYNC = 0,
                IMMEDIATE = 1,
                MAILBOX = 2,
            };
        };

        // -- Initialization -- //

        /// Creates a `GPUDevice` and claims the supplied `Window`.
        pub fn createAndClaimForWindow(
            allocator: std.mem.Allocator,
            /// a bitflag indicating which shader formats the app is able to provide.
            format_flags: c.SDL_GPUShaderFormat,
            // TODO: If `debug_mode` is enabled, `c.cImGui_ImplSDLGPU3_RenderDrawData` crashes
            // with an a load of some random value not being "valid for type 'bool'". I am not sure
            // how to fix this currently but it appears to be some sort of use-after-free?
            /// enable debug mode properties and validations.
            debug_mode: bool,
            /// the preferred GPU driver, or `NULL` to let SDL pick the optimal driver.
            name_opt: ?[]const u8,
            window: *const Window,
        ) !GPUDevice {
            var fz = FZ.init(@src(), "SDL.GPUDevice.createAndClaimForWindow");
            defer fz.end();

            const device = try create(allocator, format_flags, debug_mode, name_opt);
            try device.claimWindow(window);
            return device;
        }

        /// [SDL_CreateGPUDevice](https://wiki.libsdl.org/SDL3/SDL_CreateGPUDevice):
        /// Creates a GPU context.
        ///
        /// The GPU driver name can be one of the following:
        ///
        ///     "vulkan": Vulkan
        ///     "direct3d12": D3D12
        ///     "metal": Metal
        ///     `NULL`: let SDL pick the optimal driver
        pub fn create(
            allocator: std.mem.Allocator,
            /// a bitflag indicating which shader formats the app is able to provide.
            format_flags: c.SDL_GPUShaderFormat,
            // TODO: If `debug_mode` is enabled, `c.cImGui_ImplSDLGPU3_RenderDrawData` crashes
            // with an a load of some random value not being "valid for type 'bool'". I am not sure
            // how to fix this currently but it appears to be some sort of use-after-free?
            /// enable debug mode properties and validations.
            debug_mode: bool,
            /// the preferred GPU driver, or `NULL` to let SDL pick the optimal driver.
            name_opt: ?[]const u8,
        ) !GPUDevice {
            var fz = FZ.init(@src(), "SDL.GPUDevice.create");
            defer fz.end();

            if (debug_mode) {
                log.warn("Attempting to create a GPUDevice with `debug_mode` enabled!" ++
                    "This is probably going to cause issues.", .{});
            }

            _ = c.SDL_SetHint(c.SDL_HINT_GPU_DRIVER, "vulkan");

            const handle_opt = if (name_opt) |name| outer: {
                const cname = try CStr(allocator, name);
                defer freeCStr(allocator, cname);

                break :outer c.SDL_CreateGPUDevice(format_flags, debug_mode, cname);
            } else c.SDL_CreateGPUDevice(format_flags, debug_mode, null);

            if (handle_opt) |handle| {
                log.debug("GPU Device for driver '{s}' created!", .{name_opt orelse "optimal"});
                return .{ .handle = handle };
            } else {
                err("CreateGPUDevice", "format_flags = {b}, debug_mode = {}, name_opt = {?s}", .{
                    format_flags,
                    debug_mode,
                    name_opt,
                });
                return error.SDLError;
            }
        }

        /// [SDL_ClaimWindowForGPUDevice](https://wiki.libsdl.org/SDL3/SDL_ClaimWindowForGPUDevice):
        /// Claims a window, creating a swapchain structure for it.
        ///
        /// This must be called before `SDL_AcquireGPUSwapchainTexture` is called using the window. You should only call
        /// this function from the thread that created the window.
        ///
        /// The swapchain will be created with `SDL_GPU_SWAPCHAINCOMPOSITION_SDR` and `SDL_GPU_PRESENTMODE_VSYNC`. If
        /// you want to have different swapchain parameters, you must call SDL_SetGPUSwapchainParameters after claiming
        /// the window.
        ///
        /// This function should only be called from the thread that created the window.
        pub fn claimWindow(device: *const GPUDevice, window: *const Window) !void {
            var fz = FZ.init(@src(), "SDL.GPUDevice.claimWindow");
            defer fz.end();

            if (!c.SDL_ClaimWindowForGPUDevice(device.handle, window.handle)) {
                err("ClaimWindowForGPUDevice", "", .{});
                return error.SDLError;
            }

            log.debug("GPU Device claimed window '{s}'.", .{window.getTitle()});
        }

        // -- Deinitialization -- //

        /// [SDL_DestroyGPUDevice](https://wiki.libsdl.org/SDL3/SDL_DestroyGPUDevice):
        /// Destroys a GPU context previously returned by `SDL_CreateGPUDevice`.
        pub fn destroy(device: *GPUDevice) !void {
            var fz = FZ.init(@src(), "SDL.GPUDevice.destroy");
            defer fz.end();

            try device.waitForIdle();
            // I am assuming calling `SDL_ReleaseWindowFromGPUDevice` is unnecessary.
            c.SDL_DestroyGPUDevice(device.handle);
            log.debug("GPU Device has been destroyed!", .{});
        }

        // -- Getters -- //

        /// [SDL_WaitForGPUIdle](https://wiki.libsdl.org/SDL3/SDL_WaitForGPUIdle):
        /// Blocks the thread until the GPU is completely idle.
        pub fn waitForIdle(device: *const GPUDevice) !void {
            var fz = FZ.init(@src(), "SDL.GPUDevice.waitForIdle");
            defer fz.end();

            if (!c.SDL_WaitForGPUIdle(device.handle)) {
                err("WaitForGPUIdle", "", .{});
                return error.SDLError;
            }
        }

        /// [SDL_GetGPUSwapchainTextureFormat](https://wiki.libsdl.org/SDL3/SDL_GetGPUSwapchainTextureFormat):
        /// Obtains the texture format of the swapchain for the given window.
        ///
        /// Note that this format can change if the swapchain parameters change.
        pub fn getSwapchainTextureFormat(device: *const GPUDevice, window: *const Window) !c.SDL_GPUTextureFormat {
            return c.SDL_GetGPUSwapchainTextureFormat(device.handle, window.handle);
        }

        // -- Setters -- //

        /// [SDL_SetGPUSwapchainParameters](https://wiki.libsdl.org/SDL3/SDL_SetGPUSwapchainParameters):
        /// Changes the swapchain parameters for the given claimed window.
        ///
        /// This function will fail if the requested present mode or swapchain composition are unsupported by the
        /// device. Check if the parameters are supported via `SDL_WindowSupportsGPUPresentMode` /
        /// `SDL_WindowSupportsGPUSwapchainComposition` prior to calling this function.
        ///
        /// `SDL_GPU_PRESENTMODE_VSYNC` with `SDL_GPU_SWAPCHAINCOMPOSITION_SDR` is always supported.
        pub fn setSwapchainParameters(
            device: *const GPUDevice,
            window: *const Window,
            parameters: SwapchainParameters,
        ) !void {
            var fz = FZ.init(@src(), "SDL.GPUDevice.setSwapchainParameters");
            defer fz.end();

            // Check that the parameters are supported.
            if (DEBUG) {
                fz.push(@src(), "check support");
                if (!c.SDL_WindowSupportsGPUPresentMode(device.handle, window.handle, @intFromEnum(parameters.present_mode))) {
                    log.err(
                        "Window does not support '{}', defaulting back to {}!",
                        .{ parameters.present_mode, SwapchainParameters.PresentMode.VSYNC },
                    );
                    return error.SDLError;
                }
                if (!c.SDL_WindowSupportsGPUSwapchainComposition(
                    device.handle,
                    window.handle,
                    @intFromEnum(parameters.swapchain_composition),
                )) {
                    log.err(
                        "Window does not support '{}', defaulting back to {}!",
                        .{ parameters.swapchain_composition, SwapchainParameters.SwapchainComposition.SDR },
                    );
                    return error.SDLError;
                }
            }

            // Set the parameters.
            fz.replace(@src(), "SDL_SetGPUSwapchainParameters");
            if (!c.SDL_SetGPUSwapchainParameters(
                device.handle,
                window.handle,
                @intFromEnum(parameters.swapchain_composition),
                @intFromEnum(parameters.present_mode),
            )) {
                err(
                    "SetGPUSwapchainParameters",
                    "swapchain_composition = {s}, present_mode = {s}",
                    .{
                        @tagName(parameters.swapchain_composition),
                        @tagName(parameters.present_mode),
                    },
                );
                return error.SDLError;
            }

            log.debug(
                "GPU Device's swapchain parameters changed to swapchain_composition = {s} and present_mode = {s}.",
                .{
                    @tagName(parameters.swapchain_composition),
                    @tagName(parameters.present_mode),
                },
            );
        }

        /// [SDL_SetGPUAllowedFramesInFlight](https://wiki.libsdl.org/SDL3/SDL_SetGPUAllowedFramesInFlight):
        /// Configures the maximum allowed number of frames in flight.
        ///
        /// The default value when the device is created is 2. This means that after you have submitted 2 frames for
        /// presentation, if the GPU has not finished working on the first frame, SDL_AcquireGPUSwapchainTexture() will
        /// fill the swapchain texture pointer with NULL, and SDL_WaitAndAcquireGPUSwapchainTexture() will block.
        ///
        /// Higher values increase throughput at the expense of visual latency. Lower values decrease visual latency at
        /// the expense of throughput.
        ///
        /// Note that calling this function will stall and flush the command queue to prevent synchronization issues.
        ///
        /// The minimum value of allowed frames in flight is 1, and the maximum is 3.
        pub fn setAllowedFramesInFlight(device: *const GPUDevice, allowed_frames_in_flight: u32) !void {
            var fz = FZ.init(@src(), "SDL.GPUDevice.setAllowedFramesInFlight");
            defer fz.end();

            if (!c.SDL_SetGPUAllowedFramesInFlight(device.handle, allowed_frames_in_flight)) {
                err("SetGPUAllowedFramesInFlight", "allowed_frames_in_flight = {}", .{allowed_frames_in_flight});
                return error.SDLError;
            }

            log.debug("GPU Device's allowed frames in flight changed to {}.", .{allowed_frames_in_flight});
        }
    };

    // Command Buffer

    // See `GPUDevice.acquireCommandBuffer()`.
    pub const GPUCommandBuffer = struct {
        handle: *c.SDL_GPUCommandBuffer,

        // -- Lifecycle -- //

        /// [SDL_AcquireGPUCommandBuffer](https://wiki.libsdl.org/SDL3/SDL_AcquireGPUCommandBuffer):
        /// Acquire a command buffer.
        ///
        /// This command buffer is managed by the implementation and should not be freed by the user. The command buffer
        /// may only be used on the thread it was acquired on. The command buffer should be submitted on the thread it
        /// was acquired on.
        ///
        /// It is valid to acquire multiple command buffers on the same thread at once. In fact a common design pattern
        /// is to acquire two command buffers per frame where one is dedicated to render and compute passes and the
        /// other is dedicated to copy passes and other preparatory work such as generating mipmaps. Interleaving
        /// commands between the two command buffers reduces the total amount of passes overall which improves rendering
        /// performance.
        pub fn acquire(device: *const GPUDevice) !GPUCommandBuffer {
            var fz = FZ.init(@src(), "SDL.GPUCommandBuffer.acquire");
            defer fz.end();

            return .{
                .handle = c.SDL_AcquireGPUCommandBuffer(device.handle) orelse {
                    err("AcquireGPUCommandBuffer", "", .{});
                    return error.SDLError;
                },
            };
        }

        /// [SDL_SubmitGPUCommandBuffer](https://wiki.libsdl.org/SDL3/SDL_SubmitGPUCommandBuffer):
        /// Submits a command buffer so its commands can be processed on the GPU.
        ///
        /// It is invalid to use the command buffer after this is called.
        ///
        /// This must be called from the thread the command buffer was acquired on.
        ///
        /// All commands in the submission are guaranteed to begin executing before any command in a subsequent
        /// submission begins executing.
        pub fn submit(cmd: *const GPUCommandBuffer) !void {
            var fz = FZ.init(@src(), "SDL.GPUCommandBuffer.submit");
            defer fz.end();

            if (!c.SDL_SubmitGPUCommandBuffer(cmd.handle)) {
                err("SubmitGPUCommandBuffer", "", .{});
                return error.SDLError;
            }
        }

        // -- Usage -- //

        /// [SDL_WaitAndAcquireGPUSwapchainTexture](https://wiki.libsdl.org/SDL3/SDL_WaitAndAcquireGPUSwapchainTexture):
        /// Blocks the thread until a swapchain texture is available to be acquired, and then acquires it.
        ///
        /// When a swapchain texture is acquired on a command buffer, it will automatically be submitted for
        /// presentation when the command buffer is submitted. The swapchain texture should only be referenced by the
        /// command buffer used to acquire it. It is an error to call `SDL_CancelGPUCommandBuffer()` after a swapchain
        /// texture is acquired.
        ///
        /// This function can fill the swapchain texture handle with NULL in certain cases, for example if the window
        /// is minimized. This is not an error. You should always make sure to check whether the pointer is NULL before
        /// actually using it.
        ///
        /// The swapchain texture is managed by the implementation and must not be freed by the user. You MUST NOT call
        /// this function from any thread other than the one that created the window.
        ///
        /// The swapchain texture is write-only and cannot be used as a sampler or for another reading operation.
        pub fn waitAndAcquireSwapchainTexture(cmd: *const GPUCommandBuffer, window: *const Window) !?*c.SDL_GPUTexture {
            var fz = FZ.init(@src(), "SDL.GPUCommandBuffer.waitAndAcquireSwapchainTexture");
            defer fz.end();

            var texture: ?*c.SDL_GPUTexture = null;
            if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd.handle, window.handle, &texture, null, null)) {
                err("WaitAndAcquireGPUSwapchainTexture", "", .{});
                return error.SDLError;
            }
            return texture;
        }

        /// [SDL_PushGPUVertexUniformData](https://wiki.libsdl.org/SDL3/SDL_PushGPUVertexUniformData):
        /// Pushes data to a stage's uniform slot on the command buffer.
        ///
        /// Subsequent draw calls will use this uniform data.
        ///
        /// The data being pushed must respect std140 layout conventions. In practical terms this means you must ensure
        /// that vec3 and vec4 fields are 16-byte aligned.
        ///
        /// For detailed information about accessing uniform data from a shader, please refer to `SDL_CreateGPUShader`.
        pub fn pushUniformData(
            cmd: *const GPUCommandBuffer,
            comptime Stage: ShaderStage,
            comptime T: type,
            /// the uniform slot to push data to.
            slot: u32,
            /// client data to write.
            data: *const T,
        ) void {
            var fz = FZ.init(@src(), "SDL.GPUCommandBuffer.pushUniformData");
            defer fz.end();

            switch (Stage) {
                .Vertex => c.SDL_PushGPUVertexUniformData(cmd.handle, slot, @ptrCast(data), @sizeOf(T)),
                .Fragment => c.SDL_PushGPUFragmentUniformData(cmd.handle, slot, @ptrCast(data), @sizeOf(T)),
            }
        }
    };

    // Textures

    pub const GPUTexture = struct {
        handle: *c.SDL_GPUTexture,

        // -- Lifecycle -- //

        /// [SDL_CreateGPUTexture](https://wiki.libsdl.org/SDL3/SDL_CreateGPUTexture):
        /// Creates a texture object to be used in graphics or compute workflows.
        ///
        /// The contents of this texture are undefined until data is written to the texture.
        ///
        /// Note that certain combinations of usage flags are invalid. For example, a texture cannot have both the
        /// `SAMPLER` and `GRAPHICS_STORAGE_READ` flags.
        ///
        /// If you request a sample count higher than the hardware supports, the implementation will automatically fall
        /// back to the highest available sample count.
        ///
        /// There are optional properties that can be provided through `SDL_GPUTextureCreateInfo`'s props. These are the
        /// supported properties:
        ///
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_R_FLOAT`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_COLOR_TARGET`, clear the texture to a color with this red intensity.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_G_FLOAT`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_COLOR_TARGET`, clear the texture to a color with this green intensity.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_B_FLOAT`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_COLOR_TARGET`, clear the texture to a color with this blue intensity.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_A_FLOAT`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_COLOR_TARGET`, clear the texture to a color with this alpha intensity.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET`, clear the texture to a depth of this value.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_STENCIL_NUMBER`: (Direct3D 12 only) if the texture usage is
        ///         `SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET`, clear the texture to a stencil of this `u8` value.
        ///         Defaults to zero.
        ///     `SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING`: a name that can be displayed in debugging tools.
        pub fn create(allocator: std.mem.Allocator, device: *const GPUDevice, name: []const u8, create_info: c.SDL_GPUTextureCreateInfo) !GPUTexture {
            var fz = FZ.init(@src(), "SDL.GPUTexture.create");
            defer fz.end();

            // TODO: Don't use global properties (see Window.create).
            try setGlobalStringProperty(allocator, c.SDL_PROP_GPU_TEXTURE_CREATE_NAME_STRING, name);

            var ci = create_info;
            ci.props = c.SDL_GetGlobalProperties();

            return .{
                .handle = c.SDL_CreateGPUTexture(device.handle, &ci) orelse {
                    err("CreateGPUTexture", "", .{}); // TODO: Fill in *CreateInfo fields.
                    return error.SDLError;
                },
            };
        }

        /// Creates a `GPUTexture` from an image.
        pub fn createAndUploadImage(
            cpass: *const GPUCopyPass,
            allocator: std.mem.Allocator,
            device: *const SDL.GPUDevice,
            tbuf: *const SDL.GPUTransferBuffer(.Upload),
            image: *const @import("img").Image,
            name: []const u8,
        ) !SDL.GPUTexture {
            var fz = FZ.init(@src(), "SDL.GPUTexture.createAndUploadImage");
            defer fz.end();

            log.debug("Loading {s} image '{s}' into GPUTexture.", .{ @tagName(image.pixelFormat()), name });

            // Create the create_info and the texture.
            const create_info = c.SDL_GPUTextureCreateInfo{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                .width = @intCast(image.width),
                .height = @intCast(image.height),
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            };

            fz.push(@src(), "create");
            const texture: GPUTexture = try GPUTexture.create(
                allocator,
                device,
                name,
                create_info,
            );

            // Upload the image data to the texture.
            fz.replace(@src(), "upload");
            try cpass.uploadImageToTexture(tbuf, device, &texture, image, true, false);

            return texture;
        }

        /// [SDL_ReleaseGPUTexture](https://wiki.libsdl.org/SDL3/SDL_ReleaseGPUTexture):
        /// Frees the given texture as soon as it is safe to do so.
        ///
        /// You must not reference the texture after calling this function.
        pub fn release(texture: *const GPUTexture, device: *const GPUDevice) void {
            var fz = FZ.init(@src(), "SDL.GPUTexture.release");
            defer fz.end();

            c.SDL_ReleaseGPUTexture(device.handle, texture.handle);
        }

        // -- Usage -- //

    };

    pub const GPUSampler = struct {
        handle: *c.SDL_GPUSampler,

        // -- Lifecycle -- //

        /// [SDL_CreateGPUSampler](https://wiki.libsdl.org/SDL3/SDL_CreateGPUSampler):
        /// Creates a sampler object to be used when binding textures in a graphics workflow.
        pub fn create(allocator: std.mem.Allocator, device: *const GPUDevice, name: []const u8, create_info: c.SDL_GPUSamplerCreateInfo) !GPUSampler {
            var fz = FZ.init(@src(), "SDL.GPUSampler.create");
            defer fz.end();

            // TODO: Don't use global properties (see Window.create).
            try setGlobalStringProperty(allocator, c.SDL_PROP_GPU_SAMPLER_CREATE_NAME_STRING, name);

            var ci = create_info;
            ci.props = c.SDL_GetGlobalProperties();

            return .{
                .handle = c.SDL_CreateGPUSampler(device.handle, &ci) orelse {
                    err("CreateGPUSampler", "", .{});
                    return error.SDLError;
                },
            };
        }

        /// [SDL_ReleaseGPUSampler](https://wiki.libsdl.org/SDL3/SDL_ReleaseGPUSampler):
        /// Frees the given sampler as soon as it is safe to do so.
        ///
        /// You must not reference the sampler after calling this function.
        pub fn release(sampler: *const GPUSampler, device: *const GPUDevice) void {
            var fz = FZ.init(@src(), "SDL.GPUSampler.release");
            defer fz.end();

            c.SDL_ReleaseGPUSampler(device.handle, sampler.handle);
        }
    };

    // Passes

    pub const GPURenderPass = struct {
        handle: *c.SDL_GPURenderPass,

        // -- Lifecycle -- //

        /// [SDL_BeginGPURenderPass](https://wiki.libsdl.org/SDL3/SDL_BeginGPURenderPass):
        /// Begins a render pass on a command buffer.
        ///
        /// A render pass consists of a set of texture subresources (or depth slices in the 3D texture case) which will
        /// be rendered to during the render pass, along with corresponding clear values and load/store operations. All
        /// operations related to graphics pipelines must take place inside of a render pass. A default viewport and
        /// scissor state are automatically set when this is called. You cannot begin another render pass, or begin a
        /// compute pass or copy pass until you have ended the render pass.
        pub fn begin(
            cmd: *const GPUCommandBuffer,
            color_target_infos: []const c.SDL_GPUColorTargetInfo,
            depth_stencil_target_info: c.SDL_GPUDepthStencilTargetInfo,
        ) !GPURenderPass {
            var fz = FZ.init(@src(), "SDL.GPURenderPass.begin");
            defer fz.end();

            return .{
                .handle = c.SDL_BeginGPURenderPass(
                    cmd.handle,
                    @ptrCast(color_target_infos),
                    @intCast(color_target_infos.len),
                    &depth_stencil_target_info,
                ) orelse {
                    err("BeginGPURenderPass", "", .{});
                    return error.SDLError;
                },
            };
        }

        /// [SDL_EndGPURenderPass](https://wiki.libsdl.org/SDL3/SDL_EndGPURenderPass):
        /// Ends the given render pass.
        ///
        /// All bound graphics state on the render pass command buffer is unset. The render pass handle is now invalid.
        pub fn end(rpass: *const GPURenderPass) void {
            var fz = FZ.init(@src(), "SDL.GPURenderPass.end");
            defer fz.end();

            c.SDL_EndGPURenderPass(rpass.handle);
        }

        // -- Binding -- //

        pub const BufferBindingPurpose = enum {
            /// [SDL_BindGPUVertexBuffers](https://wiki.libsdl.org/SDL3/SDL_BindGPUVertexBuffers):
            /// Binds vertex buffer[-s] on a command buffer for use with subsequent draw calls.
            Vertex,
            /// [SDL_BindGPUIndexBuffer](https://wiki.libsdl.org/SDL3/SDL_BindGPUIndexBuffer):
            /// Binds an index buffer on a command buffer for use with subsequent draw calls.
            Index,
            /// [SDL_BindGPUFragmentStorageBuffers](https://wiki.libsdl.org/SDL3/SDL_BindGPUFragmentStorageBuffers):
            /// Binds storage buffers for use on the fragment shader.
            ///
            /// These buffers must have been created with `SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ`.
            ///
            /// Be sure your shader is set up according to the requirements documented in SDL_CreateGPUShader().
            FragmentStorage,
        };

        /// [SDL_BindGPUGraphicsPipeline](https://wiki.libsdl.org/SDL3/SDL_BindGPUGraphicsPipeline):
        /// Binds a graphics pipeline on a render pass to be used in rendering.
        ///
        /// A graphics pipeline must be bound before making any draw calls.
        pub fn bindGraphicsPipeline(rpass: *const GPURenderPass, pipeline: *c.SDL_GPUGraphicsPipeline) void {
            var fz = FZ.init(@src(), "SDL.GPURenderPass.bindGraphicsPipeline");
            defer fz.end();

            c.SDL_BindGPUGraphicsPipeline(rpass.handle, pipeline);
        }

        /// Dispatches a buffer binding call to the proper place for the purpose.
        /// See `BufferBindingPurpose` for documentation on the functions called.
        pub fn bindBuffer(
            rpass: *const GPURenderPass,
            comptime T: type,
            purpose: BufferBindingPurpose,
            slot: u32,
            buffer: *const GPUBuffer,
            offset: u32,
        ) !void {
            var fz = FZ.init(@src(), "SDL.GPURenderPass.bindBuffer");
            defer fz.end();

            const binding = c.SDL_GPUBufferBinding{ .buffer = buffer.handle, .offset = offset };
            switch (purpose) {
                .Vertex => c.SDL_BindGPUVertexBuffers(rpass.handle, slot, &binding, 1),
                .Index => {
                    if (slot != 0) log.warn("Non-zero slot passed to index buffer binding, ignoring...", .{});
                    c.SDL_BindGPUIndexBuffer(rpass.handle, &binding, switch (@sizeOf(T)) {
                        4 => c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
                        2 => c.SDL_GPU_INDEXELEMENTSIZE_16BIT,
                        else => unreachable,
                    });
                },
                .FragmentStorage => {
                    if (@sizeOf(T) != 16) {
                        log.err(
                            "Cannot bind a non-16 byte aligned SSBO! '{s}' is {}-byte aligned.",
                            .{ @typeName(T), @sizeOf(T) },
                        );
                        return error.InvalidSTD140Alignment;
                    }
                    if (offset != 0) log.warn("Non-zero offset passed to storage buffer binding, ignoring...", .{});
                    c.SDL_BindGPUFragmentStorageBuffers(rpass.handle, slot, &buffer.handle, 1);
                },
            }
        }

        // -- Drawing -- //

        /// [SDL_DrawGPUIndexedPrimitives](https://wiki.libsdl.org/SDL3/SDL_DrawGPUIndexedPrimitives):
        /// Draws data using bound graphics state with an index buffer and instancing enabled.
        ///
        /// You must not call this function before binding a graphics pipeline.
        ///
        /// Note that the `first_vertex` and `first_instance` parameters are NOT compatible with built-in
        /// vertex/instance ID variables in shaders (for example, `SV_VertexID`); GPU APIs and shader languages do not
        /// define these built-in variables consistently, so if your shader depends on them, the only way to keep
        /// behavior consistent and portable is to always pass `0` for the correlating parameter in the draw calls.
        pub fn drawIndexedPrimitives(
            rpass: *const GPURenderPass,
            num_indices: u32,
            num_instances: u32,
            first_index: u32,
            vertex_offset: i32,
            first_instance: u32,
        ) void {
            var fz = FZ.init(@src(), "SDL.GPURenderPass.drawIndexedPrimitives");
            defer fz.end();

            c.SDL_DrawGPUIndexedPrimitives(
                rpass.handle,
                num_indices,
                num_instances,
                first_index,
                vertex_offset,
                first_instance,
            );
        }
    };

    pub const GPUCopyPass = struct {
        handle: *c.SDL_GPUCopyPass,

        // -- Lifecycle -- //

        /// [SDL_BeginGPUCopyPass](https://wiki.libsdl.org/SDL3/SDL_BeginGPUCopyPass):
        /// Begins a copy pass on a command buffer.
        ///
        /// All operations related to copying to or from buffers or textures take place inside a copy pass. You must not
        /// begin another copy pass, or a render pass or compute pass before ending the copy pass.
        pub fn begin(cmd: *const GPUCommandBuffer) !GPUCopyPass {
            var fz = FZ.init(@src(), "SDL.GPUCopyPass.begin");
            defer fz.end();

            return .{
                .handle = c.SDL_BeginGPUCopyPass(cmd.handle) orelse {
                    err("BeginGPUCopyPass", "", .{});
                    return error.SDLError;
                },
            };
        }

        /// [SDL_EndGPUCopyPass](https://wiki.libsdl.org/SDL3/SDL_EndGPUCopyPass):
        /// Ends the current copy pass.
        pub fn end(cpass: *const GPUCopyPass) void {
            var fz = FZ.init(@src(), "SDL.GPUCopyPass.end");
            defer fz.end();

            c.SDL_EndGPUCopyPass(cpass.handle);
        }

        // -- Usage -- //

        /// [SDL_UploadToGPUBuffer](https://wiki.libsdl.org/SDL3/SDL_UploadToGPUBuffer):
        /// Uploads data from a transfer buffer to a buffer [except the usage of transfer buffers are elided].
        ///
        /// The upload occurs on the GPU timeline. You may assume that the upload has finished in subsequent commands.
        ///
        /// TODO: Offsets are hidden from the user for now, a future note may be to batch uploads into a single transfer
        /// buffer.
        pub fn uploadBuffer(
            cpass: *const GPUCopyPass,
            tbuf: *const GPUTransferBuffer(.Upload),
            device: *const GPUDevice,
            to: *const GPUBuffer,
            comptime T: type,
            data: []const T,
            cycle_tbuf: bool,
            cycle_buf: bool,
        ) !void {
            var fz = FZ.init(@src(), "SDL.GPUCopyPass.uploadBuffer");
            defer fz.end();

            // Check pre-conditions for upload.
            const data_size = data.len * @sizeOf(T);
            if (DEBUG and tbuf.size < data_size) {
                log.err("Transfer buffer size ({} bytes) is less than the size of the data ({} bytes)!", .{ tbuf.size, data_size });
                return error.TransferBufferSizeTooSmall;
            }

            // Transfer the data into the transfer buffer.
            fz.push(@src(), "memcpy");
            @memcpy(try tbuf.map(T, device, cycle_tbuf), data);
            tbuf.unmap(device);

            // Upload the transfer buffer to the buffer.
            fz.replace(@src(), "upload");
            c.SDL_UploadToGPUBuffer(
                cpass.handle,
                &.{ .transfer_buffer = tbuf.handle, .offset = 0 },
                &.{ .buffer = to.handle, .offset = 0, .size = @intCast(data_size) },
                cycle_buf,
            );
        }

        /// [SDL_UploadToGPUTexture](https://wiki.libsdl.org/SDL3/SDL_UploadToGPUTexture):
        /// Uploads data from a transfer buffer to a texture [except the usage of transfer buffers are elided].
        ///
        /// The upload occurs on the GPU timeline. You may assume that the upload has finished in subsequent commands.
        ///
        /// You must align the data in the transfer buffer to a multiple of the texel size of the texture format.
        pub fn uploadImageToTexture(
            cpass: *const GPUCopyPass,
            tbuf: *const GPUTransferBuffer(.Upload),
            device: *const GPUDevice,
            texture: *const GPUTexture,
            image: *const @import("img").Image,
            cycle_tbuf: bool,
            cycle_tex: bool,
        ) !void {
            var fz = FZ.init(@src(), "SDL.GPUCopyPass.uploadImageToTexture");
            defer fz.end();

            // Check pre-conditions for upload.
            const data_size = image.imageByteSize();
            if (DEBUG and tbuf.size < data_size) {
                log.err("Transfer buffer size ({} bytes) is less than the size of the data ({} bytes)!", .{ tbuf.size, data_size });
                return error.TransferBufferSizeTooSmall;
            }

            // Transfer the data into the transfer buffer.
            fz.push(@src(), "memcpy");
            @memcpy(try tbuf.map(u8, device, cycle_tbuf), image.rawBytes());
            tbuf.unmap(device);
            fz.pop();

            // Upload the transfer buffer to the buffer.
            fz.replace(@src(), "upload");
            c.SDL_UploadToGPUTexture(
                cpass.handle,
                &.{ .transfer_buffer = tbuf.handle, .offset = 0 },
                &.{ .texture = texture.handle, .w = @intCast(image.width), .h = @intCast(image.height), .d = 1 },
                cycle_tex,
            );
        }
    };

    // Buffers

    pub const GPUBuffer = struct {
        handle: *c.SDL_GPUBuffer,

        // -- Lifecycle -- //

        /// [SDL_CreateGPUBuffer](https://wiki.libsdl.org/SDL3/SDL_CreateGPUBuffer):
        /// Creates a buffer object to be used in graphics or compute workflows.
        ///
        /// The contents of this buffer are undefined until data is written to the buffer.
        ///
        /// Note that certain combinations of usage flags are invalid. For example, a buffer cannot have both the
        /// `VERTEX` and `INDEX` flags.
        ///
        /// If you use a `STORAGE` flag, the data in the buffer must respect `std140` layout conventions. In practical
        /// terms this means you must ensure that `vec3` and `vec4` fields are `16`-byte aligned.
        ///
        /// For better understanding of underlying concepts and memory management with SDL GPU API, you may refer this
        /// blog post: https://moonside.games/posts/sdl-gpu-concepts-cycling/.
        ///
        /// There are optional properties that can be provided through props. These are the supported properties:
        ///
        ///     `SDL_PROP_GPU_BUFFER_CREATE_NAME_STRING`: a name that can be displayed in debugging tools.
        pub fn create(allocator: std.mem.Allocator, device: *const GPUDevice, name: []const u8, usage: c.SDL_GPUBufferUsageFlags, size: u32) !GPUBuffer {
            var fz = FZ.init(@src(), "SDL.GPUBuffer.create");
            defer fz.end();

            // TODO: See previous usages.
            try setGlobalStringProperty(allocator, c.SDL_PROP_GPU_BUFFER_CREATE_NAME_STRING, name);
            return .{
                .handle = c.SDL_CreateGPUBuffer(device.handle, &.{
                    .usage = usage,
                    .size = size,
                    .props = c.SDL_GetGlobalProperties(),
                }) orelse {
                    err("CreateGPUBuffer", "name = {s}, usage = {b}, size = {}", .{ name, usage, size });
                    return error.SDLError;
                },
            };
        }

        /// Creates a `GPUBuffer` and uploads data to it.
        /// Primarily intended for static data such as geometry.
        pub fn createAndUploadData(
            cpass: *const GPUCopyPass,
            allocator: std.mem.Allocator,
            device: *const SDL.GPUDevice,
            tbuf: *const SDL.GPUTransferBuffer(.Upload),
            comptime T: type,
            data: []const T,
            name: []const u8,
            usage: c.SDL_GPUBufferUsageFlags,
        ) !SDL.GPUBuffer {
            var fz = FZ.init(@src(), "SDL.GPUBuffer.createAndUploadData");
            defer fz.end();

            fz.push(@src(), "create");
            const buffer: SDL.GPUBuffer = try SDL.GPUBuffer.create(
                allocator,
                device,
                name,
                usage,
                @intCast(@sizeOf(T) * data.len),
            );
            fz.replace(@src(), "upload");
            try cpass.uploadBuffer(tbuf, device, &buffer, T, data, true, false);

            return buffer;
        }

        ///[SDL_ReleaseGPUBuffer](https://wiki.libsdl.org/SDL3/SDL_ReleaseGPUBuffer):
        /// Frees the given buffer as soon as it is safe to do so.
        ///
        /// You must not reference the buffer after calling this function.
        pub fn release(buffer: *const GPUBuffer, device: *const GPUDevice) void {
            var fz = FZ.init(@src(), "SDL.GPUBuffer.release");
            defer fz.end();

            c.SDL_ReleaseGPUBuffer(device.handle, buffer.handle);
        }
    };

    pub fn GPUTransferBuffer(comptime purpose: enum { Upload, Download }) type {
        return struct {
            size: usize,
            handle: *c.SDL_GPUTransferBuffer,

            // -- Lifecycle -- //

            /// [SDL_CreateGPUTransferBuffer](https://wiki.libsdl.org/SDL3/SDL_CreateGPUTransferBuffer):
            /// Creates a transfer buffer to be used when uploading to or downloading from graphics resources.
            ///
            /// Download buffers can be particularly expensive to create, so it is good practice to reuse them if data
            /// will be downloaded regularly.
            ///
            /// There are optional properties that can be provided through props. These are the supported properties:
            ///
            ///     `SDL_PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING`: a name that can be displayed in debugging tools.
            pub fn create(allocator: std.mem.Allocator, device: *const GPUDevice, size: usize, name: []const u8) !@This() {
                var fz = FZ.init(@src(), "SDL.GPUTransferBuffer.create");
                defer fz.end();

                // TODO: See previous usages.
                try setGlobalStringProperty(allocator, c.SDL_PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING, name);
                return .{
                    .size = size,
                    .handle = c.SDL_CreateGPUTransferBuffer(device.handle, &.{
                        .usage = switch (purpose) {
                            .Upload => c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                            .Download => c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
                        },
                        .size = @intCast(size),
                        .props = c.SDL_GetGlobalProperties(),
                    }) orelse {
                        SDL.err("CreateGPUTransferBuffer", "", .{});
                        return error.SDLError;
                    },
                };
            }

            /// [SDL_ReleaseGPUTransferBuffer](https://wiki.libsdl.org/SDL3/SDL_ReleaseGPUTransferBuffer):
            /// Frees the given transfer buffer as soon as it is safe to do so.
            ///
            /// You must not reference the transfer buffer after calling this function.
            pub fn release(tbuf: *const @This(), device: *const GPUDevice) void {
                var fz = FZ.init(@src(), "SDL.GPUTransferBuffer.release");
                defer fz.end();

                c.SDL_ReleaseGPUTransferBuffer(device.handle, tbuf.handle);
            }

            // -- Usage -- //

            /// [SDL_MapGPUTransferBuffer](https://wiki.libsdl.org/SDL3/SDL_MapGPUTransferBuffer):
            /// Maps a transfer buffer into application address space.
            ///
            /// You must unmap the transfer buffer before encoding upload commands. The memory is owned by the graphics
            /// driver - do NOT call `SDL_free()` on the returned pointer.
            pub fn map(tbuf: *const @This(), comptime T: type, device: *const GPUDevice, cycle: bool) ![*]T {
                var fz = FZ.init(@src(), "SDL.GPUTransferBuffer.map");
                defer fz.end();

                return @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(
                    device.handle,
                    tbuf.handle,
                    cycle,
                ) orelse {
                    SDL.err("MapGPUTransferBuffer", "T = {s}, cycle = {}", .{ @typeName(T), cycle });
                    return error.SDLError;
                }));
            }

            /// [SDL_UnmapGPUTransferBuffer](https://wiki.libsdl.org/SDL3/SDL_UnmapGPUTransferBuffer):
            /// Unmaps a previously mapped transfer buffer.
            pub fn unmap(tbuf: *const @This(), device: *const GPUDevice) void {
                var fz = FZ.init(@src(), "SDL.GPUTransferBuffer.unmap");
                defer fz.end();

                c.SDL_UnmapGPUTransferBuffer(device.handle, tbuf.handle);
            }

            // -- Getters -- //

            pub fn isUpload() bool {
                return purpose == .Upload;
            }
        };
    }
};

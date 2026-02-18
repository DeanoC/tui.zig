//! Application core for TUI.zig with threaded input handling
//!
//! Provides the main application runner with event loop, rendering,
//! and widget management. Input is handled on a separate thread to
//! prevent blocking the main render loop.

const std = @import("std");
const builtin = @import("builtin");

const terminal = @import("core/terminal.zig");
const screen_mod = @import("core/screen.zig");
const renderer_mod = @import("core/renderer.zig");
const platform = @import("platform/platform.zig");
const events = @import("event/events.zig");
const input = @import("event/input.zig");
const theme_mod = @import("style/theme.zig");
const widget = @import("widgets/widget.zig");
const animation = @import("animation/animation.zig");

pub const Screen = screen_mod.Screen;
pub const Renderer = renderer_mod.Renderer;
pub const Terminal = terminal.Terminal;
pub const Event = events.Event;
pub const Theme = theme_mod.Theme;
pub const RenderContext = widget.RenderContext;

/// Application configuration
pub const AppConfig = struct {
    /// Initial theme
    theme: Theme = Theme.default_theme,

    /// Enable alternate screen buffer
    alternate_screen: bool = true,

    /// Hide cursor
    hide_cursor: bool = true,

    /// Enable mouse input
    enable_mouse: bool = true,

    /// Enable bracketed paste
    enable_paste: bool = true,

    /// Enable focus events
    enable_focus: bool = true,

    /// Target frames per second
    target_fps: u16 = 60,

    /// Tick rate for animation (ms)
    tick_rate_ms: u16 = 16,

    /// Input poll timeout (ms)
    poll_timeout_ms: u16 = 10,
};

/// Application state
pub const AppState = enum {
    uninitialized,
    running,
    paused,
    stopping,
    stopped,
};

/// Input thread context - shared between main thread and input thread
const InputThreadContext = struct {
    allocator: std.mem.Allocator,
    event_queue: *events.EventQueue,
    input_reader: *input.InputReader,
    state: *AppState,
    should_quit: *bool,
    mutex: *std.Thread.Mutex,
    cond: *std.Thread.Condition,
    has_event: *bool,
};

const windows_KEY_EVENT: u16 = 0x0001;
const windows_LEFT_ALT_PRESSED: u32 = 0x0002;
const windows_RIGHT_ALT_PRESSED: u32 = 0x0001;
const windows_LEFT_CTRL_PRESSED: u32 = 0x0008;
const windows_RIGHT_CTRL_PRESSED: u32 = 0x0004;
const windows_SHIFT_PRESSED: u32 = 0x0010;

const WindowsKeyEventRecord = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    dwControlKeyState: u32,
};

const WindowsInputRecord = extern struct {
    EventType: u16,
    _padding: u16,
    Event: extern union {
        KeyEvent: WindowsKeyEventRecord,
        _pad: [16]u8,
    },
};

/// Main application struct
pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,

    /// Terminal handler
    term: ?Terminal = null,

    /// Screen buffer
    screen: ?Screen = null,

    /// Renderer
    renderer: ?Renderer = null,

    /// Current theme
    theme: Theme,

    /// Application state
    state: AppState = .uninitialized,

    /// Root widget (type-erased)
    root: ?*anyopaque = null,
    root_render_fn: ?*const fn (*anyopaque, *RenderContext) void = null,
    root_event_fn: ?*const fn (*anyopaque, Event) widget.EventResult = null,

    /// Input reader (used by input thread)
    input_reader: input.InputReader,

    /// Event queue (shared between threads)
    event_queue: events.EventQueue,

    /// Threading primitives
    event_mutex: std.Thread.Mutex = .{},
    event_cond: std.Thread.Condition = .{},
    has_event: bool = false,

    /// Input thread handle
    input_thread: ?std.Thread = null,

    /// Time tracking
    start_time_ns: i128 = 0,
    last_frame_ns: i128 = 0,
    tick_count: u64 = 0,

    /// FPS tracking
    fps_counter: animation.FpsCounter = .{},

    /// Quit requested
    should_quit: bool = false,

    /// Needs redraw
    needs_redraw: bool = true,

    /// Create a new application
    pub fn init(config: AppConfig) !App {
        const allocator = std.heap.page_allocator;

        return App{
            .allocator = allocator,
            .config = config,
            .theme = config.theme,
            .input_reader = input.InputReader.init(allocator),
            .event_queue = events.EventQueue.init(allocator, 256),
            .fps_counter = animation.FpsCounter.init(),
        };
    }

    /// Create with custom allocator
    pub fn initWithAllocator(allocator: std.mem.Allocator, config: AppConfig) !App {
        return App{
            .allocator = allocator,
            .config = config,
            .theme = config.theme,
            .input_reader = input.InputReader.init(allocator),
            .event_queue = events.EventQueue.init(allocator, 256),
            .fps_counter = animation.FpsCounter.init(),
        };
    }

    /// Clean up resources
    pub fn deinit(self: *App) void {
        // Signal input thread to stop
        self.should_quit = true;

        // Wait for input thread to finish
        if (self.input_thread) |thread| {
            thread.join();
            self.input_thread = null;
        }

        if (self.term) |*t| {
            t.deinit();
        }

        if (self.renderer) |*r| {
            r.deinit();
        }

        if (self.screen) |*s| {
            s.deinit();
        }

        self.event_queue.deinit();
        self.state = .stopped;
    }

    /// Set the root widget
    pub fn setRoot(self: *App, root_ptr: anytype) !void {
        const T = @TypeOf(root_ptr.*);

        self.root = @ptrCast(root_ptr);

        if (@hasDecl(T, "render")) {
            self.root_render_fn = @ptrCast(&struct {
                fn render(ptr: *anyopaque, ctx: *RenderContext) void {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    typed.render(ctx);
                }
            }.render);
        }

        if (@hasDecl(T, "handleEvent")) {
            self.root_event_fn = @ptrCast(&struct {
                fn handleEvent(ptr: *anyopaque, event: Event) widget.EventResult {
                    const typed: *T = @ptrCast(@alignCast(ptr));
                    return typed.handleEvent(event);
                }
            }.handleEvent);
        }
    }

    /// Set the theme
    pub fn setTheme(self: *App, theme: Theme) void {
        self.theme = theme;
        self.needs_redraw = true;
    }

    /// Request application quit
    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    /// Request redraw
    pub fn requestRedraw(self: *App) void {
        self.needs_redraw = true;
    }

    /// Run the application
    pub fn run(self: *App) !void {
        try self.setup();
        defer self.teardown();

        self.state = .running;
        self.start_time_ns = std.time.nanoTimestamp();
        self.last_frame_ns = self.start_time_ns;

        // Start input thread
        try self.startInputThread();

        // Main loop
        while (self.state == .running and !self.should_quit) {
            try self.runFrame();
        }
    }

    /// Set up the application
    fn setup(self: *App) !void {
        // Initialize terminal
        self.term = try Terminal.init(.{
            .alternate_screen = self.config.alternate_screen,
            .hide_cursor = self.config.hide_cursor,
            .enable_mouse = self.config.enable_mouse,
            .enable_paste = self.config.enable_paste,
            .enable_focus = self.config.enable_focus,
        });

        // Get terminal size
        const size = try self.term.?.getSize();

        // Initialize screen buffer
        self.screen = try Screen.init(self.allocator, size.cols, size.rows);

        // Initialize renderer
        self.renderer = Renderer.init(self.allocator);

        self.state = .running;
    }

    /// Tear down the application
    fn teardown(self: *App) void {
        self.state = .stopping;
    }

    /// Start the input thread
    fn startInputThread(self: *App) !void {
        const ctx = InputThreadContext{
            .allocator = self.allocator,
            .event_queue = &self.event_queue,
            .input_reader = &self.input_reader,
            .state = &self.state,
            .should_quit = &self.should_quit,
            .mutex = &self.event_mutex,
            .cond = &self.event_cond,
            .has_event = &self.has_event,
        };

        self.input_thread = try std.Thread.spawn(.{}, inputThreadFn, .{ctx});
    }

    /// Input thread function - runs in background reading input
    fn inputThreadFn(ctx: InputThreadContext) void {
        if (builtin.os.tag == .windows) {
            inputThreadWindows(ctx);
            return;
        }

        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buf: [32]u8 = undefined;

        while (ctx.state.* == .running and !ctx.should_quit.*) {
            const bytes_read = stdin.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1_000_000);
                    continue;
                }
                std.log.err("Input read error: {s}", .{@errorName(err)});
                continue;
            };

            if (bytes_read == 0) continue;

            if (ctx.input_reader.parse(buf[0..bytes_read]) catch null) |event| {
                if (!pushInputEvent(ctx, event)) return;
            }
        }
    }

    fn inputThreadWindows(ctx: InputThreadContext) void {
        const kernel32 = struct {
            extern "kernel32" fn GetNumberOfConsoleInputEvents(
                hConsoleInput: std.os.windows.HANDLE,
                lpcNumberOfEvents: *u32,
            ) callconv(.winapi) std.os.windows.BOOL;
            extern "kernel32" fn ReadConsoleInputW(
                hConsoleInput: std.os.windows.HANDLE,
                lpBuffer: [*]WindowsInputRecord,
                nLength: u32,
                lpNumberOfEventsRead: *u32,
            ) callconv(.winapi) std.os.windows.BOOL;
        };

        const stdin_handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return;

        while (ctx.state.* == .running and !ctx.should_quit.*) {
            var pending: u32 = 0;
            if (kernel32.GetNumberOfConsoleInputEvents(stdin_handle, &pending) == 0 or pending == 0) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }

            var record: WindowsInputRecord = undefined;
            var read_count: u32 = 0;
            if (kernel32.ReadConsoleInputW(stdin_handle, @ptrCast(&record), 1, &read_count) == 0 or read_count == 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            if (record.EventType != windows_KEY_EVENT) continue;
            if (record.Event.KeyEvent.bKeyDown == 0) continue;

            if (decodeWindowsKeyEvent(record.Event.KeyEvent)) |event| {
                if (!pushInputEvent(ctx, event)) return;
            }
        }
    }

    fn pushInputEvent(ctx: InputThreadContext, event: Event) bool {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        ctx.event_queue.push(event) catch |err| {
            std.log.err("Failed to push event: {s}", .{@errorName(err)});
            return false;
        };

        ctx.has_event.* = true;
        ctx.cond.signal();
        return true;
    }

    fn decodeWindowsKeyEvent(raw: WindowsKeyEventRecord) ?Event {
        var mods = events.Modifiers{};
        mods.shift = (raw.dwControlKeyState & windows_SHIFT_PRESSED) != 0;
        mods.ctrl = (raw.dwControlKeyState & (windows_LEFT_CTRL_PRESSED | windows_RIGHT_CTRL_PRESSED)) != 0;
        mods.alt = (raw.dwControlKeyState & (windows_LEFT_ALT_PRESSED | windows_RIGHT_ALT_PRESSED)) != 0;

        const unicode_char = raw.uChar.UnicodeChar;
        if (unicode_char != 0) {
            const key = switch (unicode_char) {
                0x08 => input.Key.backspace,
                0x09 => input.Key.tab,
                0x0A, 0x0D => input.Key.enter,
                0x1B => input.Key.escape,
                else => blk: {
                    if (unicode_char < 27 and unicode_char > 0) {
                        mods.ctrl = true;
                        break :blk input.Key{ .char = @as(u21, unicode_char) + 'a' - 1 };
                    }
                    break :blk input.Key{ .char = unicode_char };
                },
            };
            return Event{ .key = .{ .key = key, .modifiers = mods } };
        }

        const key = switch (raw.wVirtualKeyCode) {
            0x08 => input.Key.backspace,
            0x09 => input.Key.tab,
            0x0D => input.Key.enter,
            0x1B => input.Key.escape,
            0x21 => input.Key.page_up,
            0x22 => input.Key.page_down,
            0x23 => input.Key.end,
            0x24 => input.Key.home,
            0x25 => input.Key.left,
            0x26 => input.Key.up,
            0x27 => input.Key.right,
            0x28 => input.Key.down,
            0x2D => input.Key.insert,
            0x2E => input.Key.delete,
            0x70...0x7B => input.Key{ .f = @intCast(raw.wVirtualKeyCode - 0x70 + 1) },
            else => return null,
        };
        return Event{ .key = .{ .key = key, .modifiers = mods } };
    }
    /// Run a single frame
    fn runFrame(self: *App) !void {
        const current_time = std.time.nanoTimestamp();
        const delta_ns = current_time - self.last_frame_ns;
        const delta_ms: u32 = @intCast(@divTrunc(delta_ns, 1_000_000));

        // Process events (non-blocking, just drain the queue)
        self.processEvents();

        // Update animations and timers
        self.tick_count += 1;

        // Render if needed
        if (self.needs_redraw) {
            try self.render();
            self.needs_redraw = false;
        }

        // Update FPS counter
        self.fps_counter.update(delta_ms);

        // Frame timing
        self.last_frame_ns = current_time;

        // Sleep to maintain target FPS
        const frame_time_ns = @divTrunc(@as(i128, 1_000_000_000), @as(i128, self.config.target_fps));
        const elapsed_ns = std.time.nanoTimestamp() - current_time;

        if (elapsed_ns < frame_time_ns) {
            const sleep_ns: u64 = @intCast(frame_time_ns - elapsed_ns);
            std.Thread.sleep(sleep_ns);
        }
    }

    /// Process input from terminal (deprecated - now handled by input thread)
    /// Kept for compatibility but does nothing since input is now threaded
    fn processInput(self: *App) !void {
        _ = self;
        // Input is now handled by inputThreadFn
        // This function is kept for API compatibility
    }

    /// Process queued events
    fn processEvents(self: *App) void {
        // Drain the event queue
        while (true) {
            self.event_mutex.lock();
            const event = self.event_queue.pop();
            self.event_mutex.unlock();

            const evt = event orelse break;

            // Check for quit key (Ctrl+C or Ctrl+Q)
            if (evt == .key) {
                const key_event = evt.key;
                if (key_event.key == .char) {
                    const c = key_event.key.char;
                    // Some terminals deliver Ctrl+C as ETX (0x03), others as Ctrl+'c'.
                    if (c == 0x03) {
                        self.should_quit = true;
                        return;
                    }
                    if (key_event.modifiers.ctrl) {
                        if (c == 'c' or c == 'q' or c == 'C' or c == 'Q') {
                            self.should_quit = true;
                            return;
                        }
                    }
                }
            }

            // Handle resize
            if (evt == .resize) {
                self.handleResize(evt.resize) catch {};
            }

            // Pass to root widget
            if (self.root != null and self.root_event_fn != null) {
                const result = self.root_event_fn.?(self.root.?, evt);
                if (result != .ignored) {
                    self.needs_redraw = true;
                }
            }
        }
    }

    /// Handle terminal resize
    fn handleResize(self: *App, resize: events.ResizeEvent) !void {
        if (self.screen) |*scr| {
            try scr.resize(resize.cols, resize.rows);
        }

        if (self.renderer) |*rend| {
            rend.invalidate();
        }

        self.needs_redraw = true;
    }

    /// Render the UI
    fn render(self: *App) !void {
        if (self.screen == null or self.renderer == null) return;

        var scr = &self.screen.?;

        // Clear screen
        scr.clear();

        // Create render context
        var ctx = RenderContext{
            .screen = scr,
            .theme = &self.theme,
            .bounds = .{
                .x = 0,
                .y = 0,
                .width = scr.width,
                .height = scr.height,
            },
            .clip = .{
                .x = 0,
                .y = 0,
                .width = scr.width,
                .height = scr.height,
            },
            .focused_id = null,
            .time_ns = @intCast(std.time.nanoTimestamp() - self.start_time_ns),
        };

        // Render root widget
        if (self.root != null and self.root_render_fn != null) {
            self.root_render_fn.?(self.root.?, &ctx);
        }

        // Render to terminal
        try self.renderer.?.render(scr);
    }

    /// Get current FPS
    pub fn getFps(self: *App) f32 {
        return self.fps_counter.getFps();
    }

    /// Get elapsed time since start
    pub fn getElapsedTime(self: *App) u64 {
        const ns = std.time.nanoTimestamp() - self.start_time_ns;
        return @intCast(@divTrunc(ns, 1_000_000));
    }

    /// Get tick count
    pub fn getTickCount(self: *App) u64 {
        return self.tick_count;
    }

    /// Get screen dimensions
    pub fn getScreenSize(self: *App) struct { width: u16, height: u16 } {
        if (self.screen) |scr| {
            return .{ .width = scr.width, .height = scr.height };
        }
        return .{ .width = 80, .height = 24 };
    }
};

/// Simple runner for quick applications
pub fn run(comptime RootWidget: type, initial_state: RootWidget) !void {
    var state = initial_state;
    var app = try App.init(.{});
    defer app.deinit();

    try app.setRoot(&state);
    try app.run();
}

test "app creation" {
    var app = try App.init(.{});
    defer app.deinit();

    try std.testing.expect(app.state == .uninitialized);
    try std.testing.expect(app.fps_counter.total_time == 960);
    try std.testing.expect(app.fps_counter.index == 0);
}

test "processed consumed event requests redraw" {
    const DummyRoot = struct {
        fn render(_: *@This(), _: *RenderContext) void {}
        fn handleEvent(_: *@This(), _: Event) widget.EventResult {
            return .consumed;
        }
    };

    var app = try App.init(.{});
    defer app.deinit();

    var root = DummyRoot{};
    try app.setRoot(&root);

    app.needs_redraw = false;
    try app.event_queue.push(Event{
        .key = .{
            .key = .{ .char = 'a' },
            .modifiers = .{},
        },
    });

    app.processEvents();
    try std.testing.expect(app.needs_redraw);
}

test "ctrl-c ETX char quits app" {
    var app = try App.init(.{});
    defer app.deinit();

    app.should_quit = false;
    try app.event_queue.push(Event{
        .key = .{
            .key = .{ .char = 0x03 },
            .modifiers = .{},
        },
    });

    app.processEvents();
    try std.testing.expect(app.should_quit);
}

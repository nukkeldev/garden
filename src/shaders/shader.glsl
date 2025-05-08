@header const m = @import("../../math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding = 0) uniform vs_params {
    mat4 mvp;
};

in vec3 position;
in vec4 color0;

out vec4 color;

void main() {
    gl_Position = mvp * vec4(position.xyz, 1);
    color = color0;
}
@end

@fs fs
in vec4 color;
out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@program shader vs fs

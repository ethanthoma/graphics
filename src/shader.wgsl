struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec3f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
};

struct Uniforms {
    projection: mat4x4f,
    view: mat4x4f,
    model: mat4x4f,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;


fn rotateY(angle: f32) -> mat4x4f {
    let c = cos(angle);
    let s = sin(angle);
    return mat4x4f(
        vec4f(c, 0.0, -s, 0.0),
        vec4f(0.0, 1.0, 0.0, 0.0),
        vec4f(s, 0.0, c, 0.0),
        vec4f(0.0, 0.0, 0.0, 1.0)
    );
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    var world_position = uniforms.model * vec4f(in.position, 1.0);
    var view_position = uniforms.view * world_position;
    out.position = uniforms.projection * view_position;

    out.color = in.color;

	return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
	let linear_color = pow(in.color, vec3f(2.2));
	return vec4f(linear_color, 1.0);
}

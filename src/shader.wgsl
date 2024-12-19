struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec3f,
};

struct InstanceInput {
    @location(2) model_matrix_0: vec4f,
    @location(3) model_matrix_1: vec4f,
    @location(4) model_matrix_2: vec4f,
    @location(5) model_matrix_3: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
    @location(1) block_position: vec3f,
};

struct Camera {
    projection: mat4x4f,
    view: mat4x4f,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var texture: texture_2d<f32>;

@vertex
fn vs_main(
    in: VertexInput,
    instance: InstanceInput,
) -> VertexOutput {
    var out: VertexOutput;

    let model = mat4x4f(
        instance.model_matrix_0,
        instance.model_matrix_1,
        instance.model_matrix_2,
        instance.model_matrix_3
    );

    var world_position = model * vec4f(in.position, 1.0);
    var view_position = camera.view * world_position;
    out.position = camera.projection * view_position;

    out.color = in.color;

    out.block_position = in.position;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let tex_size = textureDimensions(texture); // 256 x 256
    let pos = modf(in.block_position).fract;

    var tex_coords: vec2f;
    if pos.x == 0.0 || pos.x == 1.0 {
        tex_coords = pos.yz;
    } else if pos.y == 0.0 || pos.y == 1.0 {
        tex_coords = pos.xz;
    } else {
        tex_coords = pos.xy;
    }

    let mapped_coords = vec2i(tex_coords * vec2f(tex_size - 1u));

    let color = textureLoad(texture, mapped_coords, 0).rgb;
    let linear_color = pow(color, vec3f(2.2));
    return vec4f(linear_color, in.color.g);
}

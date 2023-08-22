struct Vertex {
  @location(0) pos: vec2<f32>,
  @location(1) normal: vec2<f32>,
  @location(2) color: vec4<f32>,
};

struct VertexOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) color: vec4<f32>,
}

@vertex fn vertex_main(vert: Vertex) -> VertexOut {
    var out: VertexOut;

    out.pos = vec4<f32>(vert.pos + vert.normal * 0.5, 0.0, 1.0);
    out.color = vert.color;

    return out;
}

@fragment fn frag_main(vert: VertexOut) -> @location(0) vec4<f32> {
    return vert.color;
}
